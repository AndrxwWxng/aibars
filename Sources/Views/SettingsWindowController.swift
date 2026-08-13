import SwiftUI
import AppKit

public enum SettingsWindowController {
    /// The one settings window there is. Readable from the module so a test can
    /// name it and prove there is only ever one; writable only here.
    private(set) static var window: NSWindow?
    /// The pane that is on screen — not the pane the content view was built on.
    ///
    /// `SettingsView` takes its pane as a `State` initial value, so out here
    /// this is the only record of what the user is looking at, and it has to be
    /// told: the view calls back through `onPaneChange` (see `hostingView`) on
    /// every navigation. It used to be written only where the view was built,
    /// which meant one sidebar click put the record a pane behind reality — and
    /// then the guard in `show(state:pane:)` compared a request against a pane
    /// nobody was on and skipped the rebuild, so the panel's chart button
    /// silently did nothing for the rest of the session.
    private(set) static var shownPane: SettingsView.Pane?

    /// Opens the window on whichever pane it was last left on, or Services the
    /// first time. The app's own gear item comes through here, and it should
    /// return the user to where they were.
    @MainActor public static func show(state: AppState) {
        show(state: state, pane: shownPane ?? .services)
    }

    /// Opens the window straight onto `pane`.
    ///
    /// Internal rather than public because `SettingsView.Pane` is: the app
    /// target only ever asks for the plain `show(state:)`, and every caller that
    /// names a pane lives in this module.
    @MainActor static func show(state: AppState, pane: SettingsView.Pane) {
        if let existing = window {
            // The pane is a `State` initial value inside `SettingsView`, so
            // handing the same hosting view a new root won't move it — the
            // state survives the update, which is the whole point of state.
            // Rebuilding the content view is therefore the only way an already
            // open window can honour a request for a particular pane, and a
            // history button that silently did nothing because Settings
            // happened to be open behind the panel is worse than a reset form.
            //
            // The comparison is against `shownPane`, which the view keeps
            // current, so the two cases it separates are the real ones: the
            // window is already showing what was asked for and only needs
            // raising, or it is showing something else and has to be rebuilt.
            if shownPane != pane {
                existing.contentView = hostingView(state: state, pane: pane)
                notePane(pane)
            }
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1060, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "aibars Settings"
        // The sidebar runs the full height of the window, under the titlebar,
        // the way every native settings window does. Without this the titlebar
        // is a third shade of grey stacked on the sidebar and the content —
        // three bands across the top corner, which is what made it look wrong.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true

        // Derived, not restated. A literal here drifted from the view's own
        // minimum and let the window be dragged narrower than SwiftUI could
        // honour, which squeezed the Appearance form — the bug the derivation
        // exists to prevent.
        window.minSize = SettingsView.minimumContentSize
        window.contentView = hostingView(state: state, pane: pane)
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        notePane(pane)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// One place the window's content is built, because it is built twice: once
    /// when the window opens, and again when an open window is asked for a
    /// different pane. Two copies of this drift in exactly one way — an
    /// environment object present on the first and missing on the second, which
    /// crashes only on the second path.
    @MainActor private static func hostingView(
        state: AppState,
        pane: SettingsView.Pane
    ) -> NSView {
        NSHostingView(
            // A closure rather than the view reaching for this type directly:
            // `SettingsView` is built by previews and by tests with no window
            // controller anywhere near it, which is the same reason
            // `initialPane` exists.
            rootView: SettingsView(initialPane: pane, onPaneChange: notePane)
                .environmentObject(state)
                .environmentObject(AppearanceSettings.shared)
        )
    }

    /// The only writer of `shownPane`, and the whole of the contract between the
    /// view and this type: the view says which pane it is on and this remembers.
    ///
    /// `show(state:pane:)` calls it too, the moment it builds a view on a pane,
    /// because the record has to be right immediately — the view's own report
    /// arrives an update pass later, and two requests in one turn would both
    /// rebuild in the gap.
    ///
    /// Named rather than written inline because it is the hinge the rebuild
    /// decision turns on, and a test proving the record follows the view has to
    /// be able to make the call a sidebar click makes.
    @MainActor static func notePane(_ pane: SettingsView.Pane) {
        shownPane = pane
    }

    // `close()` was here — public, and `window?.close(); window = nil;
    // shownPane = nil` — with no callers in the app, the module or the tests.
    // Deleted rather than wired up to something: `show(state:pane:)` sets
    // `isReleasedWhenClosed` false precisely so the red button leaves the window
    // standing, with its size, its position and its pane, for the next press of
    // the gear, and dropping the reference throws all three away on a close the
    // user meant as "not now". The one thing it did that mattered — clearing
    // `shownPane` so the next open could not compare against a stale record — is
    // no longer anybody's teardown to do, because the view reports every
    // navigation.
}

/// An AppKit material, for the one place SwiftUI's `Material` doesn't match the
/// system: a settings sidebar, which uses its own vibrancy and sits behind the
/// titlebar.
struct VisualEffectBackground: NSViewRepresentable {
    let material: NSVisualEffectView.Material
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
