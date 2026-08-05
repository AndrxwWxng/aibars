import SwiftUI
import aibarsCore

@main
struct aibarsApp: App {
    @StateObject private var state = AppState()
    @State private var showSettings = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(state: state, showSettings: $showSettings)
                .environmentObject(state)
                .task { state.start() }
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

/// What sits in the menu bar itself: a four-bar meter, one bar per service,
/// tallest usage first. It stays monochrome until something crosses the
/// warning threshold, at which point it picks up the usage tint.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 5) {
            UsageMeterGlyph(
                levels: state.usageLevels,
                alertColor: UsageTint.menuBarTint(for: state.topUsagePercent),
                height: 13
            )

            switch state.showInMenuBar {
            case .iconOnly:
                EmptyView()
            case .iconAndPercent:
                Text("\(Int((state.topUsagePercent * 100).rounded()))%")
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
