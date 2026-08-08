import SwiftUI
import AppKit

public enum SettingsWindowController {
    private static var window: NSWindow?

    @MainActor public static func show(state: AppState) {
        if let existing = window {
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
        window.contentView = NSHostingView(
            rootView: SettingsView()
                .environmentObject(state)
                .environmentObject(AppearanceSettings.shared)
        )
        window.center()
        window.isReleasedWhenClosed = false
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public static func close() {
        window?.close()
        window = nil
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
