import AppKit

/// Opening and closing the panel from somewhere that is not the pointer.
///
/// `MenuBarExtra` cannot be opened by public SwiftUI API on macOS 13 — and the
/// `isInserted:` overload is not the missing piece, whatever its name suggests:
/// that binding takes the status item *out of the menu bar* and puts it back,
/// which closes nothing, opens nothing, and re-sorts the item's position among
/// everyone else's on the way back in. There is no `openMenuBarExtra` action on
/// 13 or on 14.
///
/// What there is, is the button. `.menuBarExtraStyle(.window)` builds an
/// `NSStatusItem` whose button carries SwiftUI's own action, and sending that
/// button a click is the same event the pointer sends. Every step is public API
/// on an object in this process: `NSApp.windows`, `NSStatusBarButton` — a public
/// `NSButton` subclass — and `NSControl.performClick(_:)`. Nothing is swizzled
/// and no private selector is sent. It is the same reach `MenuBarAppearance`
/// already made for the same window, and the window lookup lives here now so
/// there is one copy of it rather than two.
@MainActor
public enum MenuBarPanel {

    /// The status item's own windows, one per screen carrying a bar.
    ///
    /// Matched on the class name because `NSStatusBarWindow` is not a type this
    /// app can name. `NSApp.windows` is the process's own list, so anything this
    /// finds belongs to us.
    public static var statusBarWindows: [NSWindow] {
        (NSApp?.windows ?? []).filter {
            String(describing: type(of: $0)).contains("NSStatusBarWindow")
        }
    }

    /// The button to click. The app installs exactly one status item, so the
    /// first one found is it; the search is recursive rather than a cast on
    /// `contentView` because where AppKit places the button inside that window is
    /// not documented and has moved between releases, while the class of the
    /// thing being looked for has not.
    public static var button: NSStatusBarButton? {
        for window in statusBarWindows {
            if let button = firstButton(in: window.contentView) { return button }
        }
        return nil
    }

    private static func firstButton(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = firstButton(in: subview) { return button }
        }
        return nil
    }

    /// Opens the panel, or closes it if it is already open.
    ///
    /// A toggle rather than an open, because that is what the click it stands in
    /// for does — and because a shortcut that can only open leaves the user
    /// reaching for the mouse to put the panel away, which is the thing they
    /// pressed a key to avoid.
    ///
    /// Activation comes first because the app is `LSUIElement` and is therefore
    /// never the active application when a global shortcut arrives: a panel shown
    /// while another app is frontmost does not become key, and Escape, ⌘ and the
    /// arrow keys go to the app underneath it.
    ///
    /// What was actually measured, because the two halves of this method did not
    /// come back the same. Driving `toggle()` from a launched `.app` on macOS
    /// 26.5.2: the button is found, `performClick` puts a
    /// `MenuBarExtraWindow<AnyView>` on screen and the status button's state goes
    /// `.on`; a second call takes it down again. The open path works and the
    /// toggle is real, not assumed. The activation did **not** take —
    /// `NSApp.isActive` stayed false and `keyWindow` stayed nil — because macOS
    /// only grants an application the right to bring itself forward off the back
    /// of a user event it has received, and a call made two seconds after launch
    /// with no input behind it has no such right. A real hot key press is that
    /// user event, delivered to this process by the WindowServer, which is the
    /// case that cannot be reproduced from a test harness without the
    /// Accessibility grant this whole feature is designed not to need.
    ///
    /// So the `activate` call stays: it is correct and free where the right
    /// exists, and it is the only thing that can confer key status. What is
    /// deliberately *not* here is a `makeKeyAndOrderFront` on the panel window as
    /// a fallback — that was measured too, and it does nothing: the window
    /// answers `canBecomeKey == true` and still does not become key, because no
    /// window of an inactive application can. A line that changes nothing is
    /// worse than an absent one, because the next reader trusts it.
    ///
    /// Returns false when there was nothing to click, which is the one failure
    /// this can actually observe: a future SwiftUI that stops backing
    /// `MenuBarExtra` with an `NSStatusItem` would land here rather than
    /// anywhere further down.
    @discardableResult
    public static func toggle() -> Bool {
        guard let button else { return false }
        NSApp?.activate(ignoringOtherApps: true)
        button.performClick(nil)
        return true
    }

    /// Whether the panel is on screen, as the status button reports it.
    ///
    /// SwiftUI drives the button's state from the window it owns, so `.on` is the
    /// panel being shown. Read a run loop turn after a click rather than
    /// immediately — the same deferral, and for the same reason, as the one the
    /// app delegate takes before attaching to the status item's window: the state
    /// is set as SwiftUI puts the window up, which has not happened yet at the
    /// moment `performClick` returns.
    public static var isOpen: Bool { button?.state == .on }
}
