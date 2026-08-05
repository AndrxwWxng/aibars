import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var showAuthSheet: AnyUsageProvider?
    @State private var pane: Pane = .services

    public init() {}

    enum Pane: String, CaseIterable, Identifiable {
        case services, general, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .services: return "Services"
            case .general:  return "General"
            case .about:    return "About"
            }
        }

        var symbol: String {
            switch self {
            case .services: return "square.grid.2x2"
            case .general:  return "gearshape"
            case .about:    return "info.circle"
            }
        }
    }

    public var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: Binding(
                get: { pane },
                set: { pane = $0 ?? pane }
            )) { item in
                Label(item.title, systemImage: item.symbol)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 168, max: 200)
        } detail: {
            detail
                .navigationTitle(pane.title)
        }
        .frame(width: 660, height: 520)
        .sheet(item: $showAuthSheet) { provider in
            AuthSheet(provider: provider)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .services: providersTab
        case .general:  generalTab
        case .about:    aboutTab
        }
    }

    private var generalTab: some View {
        Form {
            Section("Refresh") {
                Picker("Interval", selection: $state.refreshIntervalSeconds) {
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                    Text("5 minutes").tag(300)
                    Text("15 minutes").tag(900)
                    Text("30 minutes").tag(1800)
                }
                .onChange(of: state.refreshIntervalSeconds) { _ in
                    state.stop(); state.start()
                }
            }
            Section("Menu bar") {
                Picker("Show", selection: $state.showInMenuBar) {
                    ForEach(AppState.MenuBarDisplay.allCases) { display in
                        Text(display.label).tag(display)
                    }
                }
                LabeledContent("Preview") {
                    HStack(spacing: 5) {
                        UsageMeterGlyph(
                            levels: state.usageLevels,
                            alertColor: UsageTint.menuBarTint(for: state.topUsagePercent),
                            height: 13
                        )
                        if state.showInMenuBar == .iconAndPercent {
                            Text("\(Int((state.topUsagePercent * 100).rounded()))%")
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .monospacedDigit()
                        } else if state.showInMenuBar == .iconAndName, let name = state.topProviderName {
                            Text(name).font(.system(size: 11, weight: .medium))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var providersTab: some View {
        Form {
            ForEach(state.providers) { provider in
                Section {
                    HStack(spacing: 10) {
                        ProviderLogo(
                            providerID: provider.id,
                            fallbackName: provider.displayName,
                            fallbackColor: provider.accentColor,
                            size: 28
                        )
                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.displayName).font(.system(size: 13, weight: .semibold))
                            Text(provider.isAuthenticated ? "Connected" : "Not connected")
                                .font(.caption)
                                .foregroundStyle(provider.isAuthenticated ? .green : .secondary)
                        }
                        Spacer()
                        signInControl(for: provider)
                    }
                    Toggle("Show in menu bar", isOn: Binding(
                        get: { provider.isEnabled },
                        set: { provider.setEnabled($0) }
                    ))
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func signInControl(for provider: AnyUsageProvider) -> some View {
        if provider.isAuthenticated {
            Button("Sign out") {
                Task { try? await provider.signOut() }
            }
        } else if provider.webLogin != nil {
            Button("Sign in…") {
                LoginWindowController.show(provider: provider) { success in
                    if success { Task { await state.refreshAll() } }
                }
            }
            .buttonStyle(.borderedProminent)
        } else {
            Button("Configure…") { showAuthSheet = provider }
                .buttonStyle(.borderedProminent)
        }
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            UsageMeterGlyph(levels: [0.9, 0.65, 0.4, 0.2], alertColor: .accentColor, alertThreshold: 0, height: 44)
            Text("aibars").font(.title2).bold()
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")")
                .foregroundStyle(.secondary)
            Text("Open-source AI subscription usage monitor.\nMIT License.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Link("View on GitHub", destination: URL(string: "https://github.com/aibars/aibars")!)
                .padding(.top, 8)
            Text("Product names and logos are trademarks of their respective owners.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

/// Manual credential entry, for providers with no hosted login page to host.
public struct AuthSheet: View {
    @ObservedObject var provider: AnyUsageProvider
    @Environment(\.dismiss) var dismiss
    @State private var pastedToken: String = ""
    @State private var endpoint: String = ""
    @State private var status: String?
    @State private var isWorking = false

    public init(provider: AnyUsageProvider) {
        self.provider = provider
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 9) {
                ProviderLogo(
                    providerID: provider.id,
                    fallbackName: provider.displayName,
                    fallbackColor: provider.accentColor,
                    size: 26
                )
                Text("Connect \(provider.displayName)")
                    .font(.headline)
                Spacer()
            }

            Text(instructions)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if provider.needsEndpointConfiguration {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Usage endpoint").font(.subheadline)
                    TextField("https://api.example.com/usage", text: $endpoint)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Token").font(.subheadline)
                SecureField("Paste your token…", text: $pastedToken)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await save() } }
            }

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Try browser cookies") { Task { await tryBrowser() } }
                    .disabled(isWorking)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { Task { await save() } }
                    .buttonStyle(.borderedProminent)
                    .disabled(pastedToken.isEmpty || isWorking)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { endpoint = provider.configuredEndpoint ?? "" }
    }

    private var instructions: String {
        switch provider.id {
        case "minimax":
            return "Point aibars at any endpoint that returns JSON usage data, and give it a token with read access."
        default:
            return "Paste a token with read access to this service's usage endpoint."
        }
    }

    private func save() async {
        isWorking = true
        defer { isWorking = false }
        if provider.needsEndpointConfiguration {
            let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, URL(string: trimmed) != nil else {
                status = "Enter a valid usage endpoint URL."
                return
            }
            provider.configure(endpoint: trimmed, planName: "API")
        }
        do {
            try provider.saveTokenManually(pastedToken)
            status = "Saved. Verifying…"
            _ = try await provider.fetchUsage()
            status = "Connected."
            try? await Task.sleep(nanoseconds: 500_000_000)
            dismiss()
        } catch {
            status = "Failed: \(error.localizedDescription)"
        }
    }

    private func tryBrowser() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try await provider.authenticate()
            if provider.isAuthenticated {
                status = "Found a session in your browser."
                _ = try await provider.fetchUsage()
                try? await Task.sleep(nanoseconds: 500_000_000)
                dismiss()
            } else {
                status = "No matching cookie in your installed browsers. Paste a token instead."
            }
        } catch {
            status = "Browser lookup failed: \(error.localizedDescription). Paste a token instead."
        }
    }
}
