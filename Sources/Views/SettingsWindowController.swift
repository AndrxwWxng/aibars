import SwiftUI
import AppKit

public enum SettingsWindowController {
    @MainActor public static func show(state: AppState) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "aibars Settings"
        window.contentView = NSHostingView(rootView: SettingsView().environmentObject(state))
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
