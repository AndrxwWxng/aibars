import SwiftUI

struct public MenuBarContentView: View {
    @ObservedObject var state: AppState
    @Binding var showSettings: Bool
    @State private var hoveredProvider: String?

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(state.providers) { provider in
                        ProviderRow(
                            provider: provider,
                            result: state.snapshots[provider.id],
                            isHovered: hoveredProvider == provider.id,
                            onTap: { handleTap(for: provider) }
                        )
                        .onHover { hovering in
                            hoveredProvider = hovering ? provider.id : (hoveredProvider == provider.id ? nil : hoveredProvider)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .frame(maxHeight: 360)

            Divider()

            footer
        }
        .frame(width: 360)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("AI Usage")
                    .font(.system(size: 13, weight: .semibold))
                if let last = state.lastRefresh {
                    Text("Updated \(last.formatted(.relative(presentation: .numeric)))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Never refreshed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if state.isRefreshing {
                ProgressView().controlSize(.small)
            } else {
                Button {
                    Task { await state.refreshAll() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .help("Refresh now")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Settings…") { showSettings = true }
                .buttonStyle(.borderless)
            Spacer()
            Button("Quit aibars") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
                .keyboardShortcut("q")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func handleTap(for provider: AnyUsageProvider) {
        if !provider.isAuthenticated {
            SettingsWindowController.show(state: state)
        }
    }
}
