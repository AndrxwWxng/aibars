import AppKit
import SwiftUI

/// Getting keystrokes into a `MenuBarExtra` panel, and the only part of the
/// feature that cannot be tested headlessly.
///
/// It is deliberately the smallest thing that works: one `NSEvent` local monitor,
/// scoped by window identity, and one attempt to make the panel's own window key.
/// Everything a keystroke then *means* is in `PanelKeyboard`, which is pure.
///
/// **Why a local monitor and not `@FocusState`.** `.focusable()` needs a first
/// responder, a first responder needs a key window, and the key window is exactly
/// what a status-item panel does not reliably have — that is the whole of the
/// long-standing "you cannot type into a `TextField` in a `MenuBarExtra`" report.
/// `FocusState` does not supply the missing precondition, it consumes it. And on
/// macOS 13 `.focusable()` draws the system focus ring, whose only suppressor,
/// `focusEffectDisabled()`, is macOS 14 — so that route ships the one piece of
/// system chrome this panel bans, on the app's minimum OS. A hosting-view subclass
/// overriding `keyDown(with:)` has the same missing precondition and costs a
/// custom view on top.
///
/// `NSEvent.addLocalMonitorForEvents(matching:handler:)` installs on
/// `NSApplication`, not on a responder. It sees every event this process
/// dispatches before `sendEvent(_:)` routes it to a window, and returning nil
/// consumes the event outright — no beep, and no key-equivalent pass afterwards.
/// There is no focus to lose because there is no focus involved.
///
/// Never a global monitor: that is a keylogger's API, it needs the accessibility
/// permission this app has never asked for, and it would see every keystroke the
/// user types in every other application.
@MainActor
public final class PanelKeyMonitor {
    /// Returns true when the command was consumed.
    public var onCommand: ((PanelKeyCommand) -> Bool)?
    public var onResignKey: (() -> Void)?
    public private(set) var window: NSWindow?

    private var token: Any?
    private var resignObserver: NSObjectProtocol?
    /// Spent at most once per attached window. See `claimKeyboard`.
    private var hasForcedActivation = false

    /// Non-isolated so a `@State` default value can build one: `@State private var
    /// monitor = PanelKeyMonitor()` is evaluated wherever the view struct is, and
    /// requiring the main actor there would constrain who may build the panel.
    public nonisolated init() {}

    // MARK: - Attaching

    /// Scope the monitor to one window, and ask that window for the keyboard.
    ///
    /// Idempotent on the same window, because `MenuBarExtra` may rebuild its
    /// content view — and therefore fire the probe — more than once per opening.
    public func attach(to window: NSWindow) {
        guard window !== self.window else { return }
        detach()
        self.window = window
        claimKeyboard(window)

        token = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            // AppKit calls a local monitor on the main thread, and the handler
            // has to answer with the event or with nil synchronously — there is
            // nowhere to hop to and wait. So the isolation is asserted rather
            // than dispatched, which is the same shape `SystemAppearanceObserver`
            // uses for its three notification handlers.
            MainActor.assumeIsolated { [weak self] in
                self?.handle(event) ?? event
            }
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onResignKey?() }
        }
    }

    /// Take the monitor and the observer down.
    ///
    /// A monitor left installed is inert, because of the window guard in
    /// `handle` — but it is still a retained closure running on every keystroke
    /// the user types anywhere in this process, for the rest of the launch.
    ///
    /// The two callbacks are deliberately left in place. The probe reports its
    /// window during layout and the panel wires the callbacks in `onAppear`, so
    /// `attach` runs first on every opening; clearing them here would mean a
    /// re-opened panel whose content view was not rebuilt — and therefore never
    /// fires `onAppear` again — had a monitor with nobody on the other end.
    public func detach() {
        if let token { NSEvent.removeMonitor(token) }
        token = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        window = nil
        hasForcedActivation = false
    }

    // MARK: - The one precondition

    /// How long the window server is given to answer a `makeKey()`.
    ///
    /// A delay rather than the next line, and that is a correction rather than
    /// caution: becoming key is a round trip to the window server, so
    /// `isKeyWindow` is still false immediately after `makeKey()` returns even
    /// when the window is already on screen — measured on a probe rig built for
    /// this, which read `visible=true key=false` on the statement after the call.
    /// A version that escalated on that reading would escalate every time.
    private static let keyGrace: TimeInterval = 0.1

    /// Ask the panel's window for the keyboard, and only escalate if it did not
    /// get it.
    ///
    /// The window is a `MenuBarExtraWindow`, carrying `nonactivatingPanel` and
    /// answering true to `canBecomeKey` — both read off a probe rig rather than
    /// assumed. `nonactivatingPanel` is documented as "the panel can receive
    /// keyboard events without activating the owning application", so on a system
    /// where step one lands this costs the user nothing at all: their frontmost
    /// application stays frontmost and stays active, and keystrokes come here only
    /// while the panel is up.
    ///
    /// The escalation is second, once, and conditional, because it does not come
    /// free: activating an accessory app puts its own menu bar over the frontmost
    /// app's for as long as the panel is open. It is never reached on a system
    /// where the window simply became key — which is the case the rig could not
    /// settle either way, because a status item cannot be clicked without a hand
    /// on the mouse and a synthesised click does not carry the window server's
    /// focus transfer with it.
    private func claimKeyboard(_ window: NSWindow) {
        guard !window.isKeyWindow else { return }
        window.makeKey()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.keyGrace) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.window === window,
                      window.isVisible, !window.isKeyWindow,
                      !self.hasForcedActivation
                else { return }
                self.hasForcedActivation = true
                Self.activate()
                window.makeKey()
            }
        }
    }

    /// `activate()` where it exists, the old spelling below it. Only to keep the
    /// deprecation warning out of the build — on macOS 14 and later the system
    /// ignores `ignoringOtherApps` anyway, so the two calls do the same thing.
    private static func activate() {
        guard let app = NSApp else { return }
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(ignoringOtherApps: true)
        }
    }

    // MARK: - The handler

    private func handle(_ event: NSEvent) -> NSEvent? {
        // The window identity check is what makes an app-wide monitor safe.
        // `SettingsView`'s text fields, the connect dialog's token field and the
        // account-name field all live in other windows, and none of them is ever
        // seen here.
        guard event.window === window else { return event }
        guard let command = PanelKeyCommand.from(
            keyCode: event.keyCode,
            characters: event.characters,
            charactersIgnoringModifiers: event.charactersIgnoringModifiers,
            modifiers: event.modifierFlags
        ) else { return event }
        return onCommand?(command) == true ? nil : event
    }

    // MARK: - Closing

    /// Close the panel the way the user would: by clicking the status item.
    ///
    /// Through the item's own button rather than `orderOut`, so `MenuBarExtra`'s
    /// presentation state stays in step — ordering the window out behind its back
    /// leaves it believing the panel is still up, and the next click on the item
    /// is then swallowed re-closing something that is not there.
    ///
    /// Found by walking for an `NSStatusBarButton` rather than by class name, and
    /// **not** by `contentView as? NSStatusBarButton`: measured on this OS, the
    /// status item's window holds an `NSStatusBarContentView` whose subtree is
    /// `NSView` → `NSStatusBarButton`, so the cast finds nothing at all. Walking is
    /// also what makes the search exact — the button exists in the item's window
    /// and nowhere else, so no window has to be named or excluded.
    public func dismissPanel() {
        guard let button = Self.statusItemButton() else {
            window?.orderOut(nil)
            return
        }
        button.performClick(nil)
    }

    private static func statusItemButton() -> NSStatusBarButton? {
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap(descendants)
        }
        return (NSApp?.windows ?? [])
            .compactMap(\.contentView)
            .flatMap(descendants)
            .compactMap { $0 as? NSStatusBarButton }
            .first
    }
}

/// The panel's own window, found without touching a hierarchy we do not own.
///
/// A view we placed ourselves, reporting the window it was moved into. Public
/// API, no class-name matching, no walking `NSApp.windows` and guessing — which
/// matters because `MenuBarAppearance.statusBarWindows` does exactly that, on the
/// substring `"NSStatusBarWindow"`, and takes `.first` of an unordered list. (The
/// panel is a `MenuBarExtraWindow`, so that accessor does not in fact pick it up
/// today — but the two are one status item's machinery apart, and a probe cannot
/// be wrong about which window it is in.)
public struct PanelWindowProbe: NSViewRepresentable {
    public let onWindow: (NSWindow?) -> Void

    public init(onWindow: @escaping (NSWindow?) -> Void) {
        self.onWindow = onWindow
    }

    public func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onWindow = onWindow
        return view
    }

    public func updateNSView(_ view: ProbeView, context: Context) {
        view.onWindow = onWindow
    }

    /// A bare view whose only job is to notice which window it landed in.
    public final class ProbeView: NSView {
        var onWindow: ((NSWindow?) -> Void)?

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onWindow?(window)
        }
    }
}
