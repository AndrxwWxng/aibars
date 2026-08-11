import SwiftUI
import AppKit

public enum SettingsWindowController {
    private static var window: NSWindow?
    /// The pane the window's current content view was built on. `SettingsView`
    /// takes its pane as a `State` initial value, so this is the only record of
    /// what is on screen — and the thing a second `show(state:pane:)` has to
    /// compare against to decide whether the window needs rebuilding.
    private static var shownPane: SettingsView.Pane?

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
            if shownPane != pane {
                existing.contentView = hostingView(state: state, pane: pane)
                shownPane = pane
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
        shownPane = pane
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
            rootView: SettingsView(initialPane: pane)
                .environmentObject(state)
                .environmentObject(AppearanceSettings.shared)
        )
    }

    public static func close() {
        window?.close()
        window = nil
        shownPane = nil
    }
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
