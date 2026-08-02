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

struct MenuBarLabel: View {
    @ObservedObject var state: AppState

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "chart.bar.xaxis")
                .symbolRenderingMode(.hierarchical)
            switch state.showInMenuBar {
            case .iconOnly:
                EmptyView()
            case .iconAndPercent:
                Text("\(Int(state.topUsagePercent * 100))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .monospacedDigit()
            case .iconAndName:
                if let top = topProviderName() {
                    Text(top).font(.system(size: 11, weight: .medium))
                }
            }
        }
    }

    private func topProviderName() -> String? {
        let sorted = state.snapshots
            .compactMapValues { try? $0.get() }
            .map { ($0.key, $0.value.primary.percent) }
            .sorted { $0.1 > $1.1 }
        guard let (id, _) = sorted.first else { return nil }
        return state.provider(for: id)?.displayName
    }
}
