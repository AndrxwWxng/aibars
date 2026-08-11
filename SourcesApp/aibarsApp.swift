import SwiftUI
import aibarsCore

@main
struct aibarsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared
    @StateObject private var appearance = AppearanceSettings.shared
    @State private var showSettings = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(state: state, showSettings: $showSettings, appearance: appearance)
                .environmentObject(state)
                .environmentObject(appearance)
        } label: {
            MenuBarLabel(state: state, appearance: appearance)
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
        MainActor.assumeIsolated {
            AppState.shared.start()
            // What macOS says, not what we last asked for: a login item can be
            // removed in System Settings while the app isn't running, and the
            // toggle in Settings has to open showing that.
            LoginItem.shared.refresh()
            // A no-op unless the user has already turned alerts on, so a first
            // launch raises no permission prompt. Asking for notifications
            // before anyone has asked for notifications is the nag this app is
            // written to avoid.
            Task { await AlertCenter.shared.primeIfNeeded() }
        }
    }
}

/// What sits in the menu bar itself: a four-bar meter, one bar per service,
/// tallest usage first. It stays monochrome until something crosses the
/// warning threshold, at which point it picks up the usage tint.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @ObservedObject var appearance: AppearanceSettings
    /// Observed only so a light/dark switch redraws the glyph, which bakes its
    /// neutral colour in whenever it is carrying usage tints.
    @ObservedObject private var systemAppearance = SystemAppearanceObserver.shared

    /// Highest or average across services, whichever the user picked.
    private var percent: Double { appearance.menuBarPercent(in: state) }

    var body: some View {
        HStack(spacing: 5) {
            // A pre-rendered image, not the SwiftUI view: MenuBarExtra draws
            // Shape-based labels as nothing at all.
            if appearance.menuBarLabel.showsGlyph {
                Image(nsImage: MenuBarIcon.image(
                    levels: state.usageLevels,
                    tint: appearance.menuBarTint(for: percent),
                    colourPerBar: appearance.coloursEveryMenuBarBar,
                    height: appearance.menuBarGlyphHeight,
                    barCount: appearance.menuBarBarCount
                ))
            }

            switch appearance.menuBarLabel {
            case .iconOnly:
                EmptyView()
            case .percentOnly, .iconAndPercent:
                // "0%" would claim every service is untouched when the truth is
                // that none of them reported.
                Text(state.usageLevels.isEmpty ? "–" : "\(Int((percent * 100).rounded()))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
            case .iconAndName:
                if let top = state.topProviderName {
                    Text(top).font(.system(size: 11, weight: .medium))
                }
            }
        }
        .padding(.horizontal, 1)
        // The status item said nothing at all to VoiceOver: a meter image with
        // no label, or a bare "62%" with no service attached to it. The headline
        // is already the one sentence carrying both the number and whose it is.
        .accessibilityLabel(state.headlineSummary)
    }
}
