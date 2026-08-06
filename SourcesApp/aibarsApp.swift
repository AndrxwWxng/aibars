import SwiftUI
import aibarsCore

@main
struct aibarsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared
    @State private var showSettings = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(state: state, showSettings: $showSettings)
                .environmentObject(state)
        } label: {
            MenuBarLabel(state: state)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: showSettings) { newValue in
            if newValue {
                SettingsWindowController.show(state: state)
                showSettings = false
            }
        }
    }
}

/// Starts the refresh loop when the app launches.
///
/// It used to hang off the dropdown's `.task`, and `MenuBarExtra` only builds
/// its content when the menu is opened — so nothing refreshed until the user
/// clicked the icon, and the icon they were deciding whether to click showed no
/// data. A menu bar app has to be working before anyone looks at it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { AppState.shared.start() }
    }
}

/// What sits in the menu bar itself: a four-bar meter, one bar per service,
/// tallest usage first. It stays monochrome until something crosses the
/// warning threshold, at which point it picks up the usage tint.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 5) {
            // A pre-rendered image, not the SwiftUI view: MenuBarExtra draws
            // Shape-based labels as nothing at all.
            Image(nsImage: MenuBarIcon.image(
                levels: state.usageLevels,
                tint: UsageTint.menuBarTint(for: state.topUsagePercent)
            ))

            switch state.showInMenuBar {
            case .iconOnly:
                EmptyView()
            case .iconAndPercent:
                // "0%" would claim every service is untouched when the truth is
                // that none of them reported.
                Text(state.usageLevels.isEmpty
                     ? "–"
                     : "\(Int((state.topUsagePercent * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
            case .iconAndName:
                if let top = state.topProviderName {
                    Text(top).font(.system(size: 11, weight: .medium))
                }
            }
        }
        .padding(.horizontal, 1)
    }
}
