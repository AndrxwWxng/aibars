import SwiftUI
import AppKit

public struct MenuBarContentView: View {
    @ObservedObject public var state: AppState
    @Binding public var showSettings: Bool

    public init(state: AppState, showSettings: Binding<Bool>) {
        self._state = ObservedObject(wrappedValue: state)
        self._showSettings = showSettings
    }

    private var ranked: [AnyUsageProvider] { state.rankedProviders }
    private var connected: [AnyUsageProvider] { ranked.filter(\.isAuthenticated) }
    private var disconnected: [AnyUsageProvider] { ranked.filter { !$0.isAuthenticated } }

    public var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)

            if ranked.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(connected) { provider in
                            row(for: provider)
                        }

                        if !disconnected.isEmpty {
                            SectionLabel(
                                title: connected.isEmpty ? "Available" : "Not connected",
                                count: disconnected.count
                            )
                            .padding(.top, connected.isEmpty ? 2 : 8)
                            ForEach(disconnected) { provider in
                                row(for: provider)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
                .frame(maxHeight: 420)
                .scrollBounceBehaviorIfAvailable()
            }

            Divider().opacity(0.5)
            footer
        }
        .frame(width: 356)
    }

    private func row(for provider: AnyUsageProvider) -> some View {
        ProviderRow(
            provider: provider,
            result: state.snapshots[provider.id],
            onSignIn: { signIn(provider) },
            onOpenDashboard: { open(provider.dashboardURL) },
            onRefresh: { Task { await state.refresh(provider.id) } }
        )
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            UsageMeterGlyph(
                levels: state.usageLevels,
                alertColor: UsageTint.menuBarTint(for: state.topUsagePercent),
                height: 16
            )
            .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 1) {
                Text("AI Usage")
                    .font(.system(size: 13, weight: .semibold))
                Text(state.headlineSummary)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 6)

            if state.isRefreshing {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                    .frame(width: 24, height: 24)
            } else {
                HoverIconButton(systemName: "arrow.clockwise", help: "Refresh all (⌘R)") {
                    Task { await state.refreshAll(userInitiated: true) }
                }
                .keyboardShortcut("r")
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 9)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 2) {
            FooterButton(title: "Settings", systemName: "gearshape") {
                showSettings = true
            }
            .keyboardShortcut(",")

            Spacer()

            Text(updatedText)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)

            Spacer()

            FooterButton(title: "Quit", systemName: "power") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
    }

    private var updatedText: String {
        guard let last = state.lastRefresh else { return "not refreshed" }
        let elapsed = Int(Date().timeIntervalSince(last))
        if elapsed < 10 { return "updated just now" }
        if elapsed < 60 { return "updated \(elapsed)s ago" }
        if elapsed < 3600 { return "updated \(elapsed / 60)m ago" }
        return "updated \(elapsed / 3600)h ago"
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "square.dashed")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text("No services enabled")
                .font(.system(size: 12, weight: .medium))
            Text("Turn one on in Settings → Services.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28)
    }

    // MARK: - Actions

    private func signIn(_ provider: AnyUsageProvider) {
        // Providers with a login page hand off to the browser; the rest still
        // need the token form in Settings.
        if provider.webLogin != nil {
            LoginWindowController.show(provider: provider) { success in
                if success { Task { await state.refresh(provider.id) } }
            }
        } else {
            showSettings = true
        }
    }

    private func open(_ url: URL?) {
        guard let url else { return }
        NSWorkspace.shared.open(url)
    }
}

/// A quiet group divider for the dropdown list.
struct SectionLabel: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .tracking(0.5)
            Text("\(count)")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 4)
                .padding(.vertical, 0.5)
                .background(Capsule().fill(Color.primary.opacity(0.07)))
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: 1)
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 2)
    }
}

/// A borderless icon button that reveals a rounded hover background, matching
/// the affordances in system menu bar panels.
struct HoverIconButton: View {
    let systemName: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 24, height: 24)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(isHovered ? 0.09 : 0))
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(help)
    }
}

struct FooterButton: View {
    let title: String
    let systemName: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemName)
                    .font(.system(size: 11, weight: .medium))
                Text(title)
                    .font(.system(size: 12))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.08 : 0))
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

private extension View {
    /// `scrollBounceBehavior` is macOS 14+; the app targets 13.
    @ViewBuilder
    func scrollBounceBehaviorIfAvailable() -> some View {
        if #available(macOS 14.0, *) {
            self.scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }
}
