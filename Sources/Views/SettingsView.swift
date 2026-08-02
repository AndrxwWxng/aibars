import SwiftUI

public struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var showAuthSheet: AnyUsageProvider?

    public var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gearshape") }
            providersTab.tabItem { Label("Services", systemImage: "list.bullet.rectangle") }
            aboutTab.tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520, height: 480)
        .sheet(item: $showAuthSheet) { provider in
            AuthSheet(provider: provider)
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
            }
        }
        .formStyle(.grouped)
    }

    private var providersTab: some View {
        Form {
            ForEach(state.providers) { provider in
                Section {
                    HStack {
                        Image(systemName: provider.iconName)
                            .foregroundStyle(provider.accentColor)
                            .frame(width: 20)
                        Text(provider.displayName).font(.headline)
                        Spacer()
                        if provider.isAuthenticated {
                            Button("Sign out") {
                                Task { try? await provider.signOut() }
                            }
                        } else {
                            Button("Sign in…") {
                                showAuthSheet = provider
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    Toggle("Enabled", isOn: Binding(
                        get: { provider.isEnabled },
                        set: { provider.setEnabled($0) }
                    ))
                }
            }
        }
        .formStyle(.grouped)
    }

    private var aboutTab: some View {
        VStack(spacing: 12) {
            Image(systemName: "chart.bar.xaxis")
                .font(.system(size: 48))
                .foregroundStyle(.tint)
            Text("aibars").font(.title2).bold()
            Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")")
                .foregroundStyle(.secondary)
            Text("Open-source AI subscription usage monitor.\nMIT License.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)
            Link("View on GitHub", destination: URL(string: "https://github.com/aibars/aibars")!)
                .padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }
}

public struct AuthSheet: View {
    @ObservedObject var provider: AnyUsageProvider
    @Environment(\.dismiss) var dismiss
    @State private var pastedToken: String = ""
    @State private var status: String?
    @State private var isWorking = false

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: provider.iconName)
                    .foregroundStyle(provider.accentColor)
                Text("Sign in to \(provider.displayName)")
                    .font(.headline)
                Spacer()
            }

            Text(instructions)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                Text("Session token")
                    .font(.subheadline)
                SecureField("Paste your session token…", text: $pastedToken)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await save() } }
            }

            if let status {
                Text(status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
    }

    private var instructions: String {
        switch provider.id {
        case "claude":
            return "In Claude.ai, open DevTools → Application → Cookies → claude.ai. Copy the value of `sessionKey`."
        case "chatgpt":
            return "In chatgpt.com, open DevTools → Application → Cookies → chatgpt.com. Copy `__Secure-next-auth.session-token`."
        case "cursor":
            return "In cursor.com, open DevTools → Application → Cookies → cursor.com. Copy `WorkosCursorSessionToken`."
        case "copilot":
            return "Create a GitHub personal access token (Settings → Developer settings → PAT, classic) with `read:user` and `copilot` scopes. Paste it below."
        case "minimax":
            return "Paste an API token with read access to your usage endpoint."
        default:
            return "Open the service in your browser, copy the relevant session cookie, and paste it below."
        }
    }

    private func save() async {
        isWorking = true
        defer { isWorking = false }
        do {
            try provider.saveTokenManually(pastedToken)
            status = "Saved. Verifying…"
            _ = try await provider.fetchUsage()
            status = "Authenticated."
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
                status = "Found session in browser."
                _ = try await provider.fetchUsage()
                try? await Task.sleep(nanoseconds: 500_000_000)
                dismiss()
            } else {
                status = "No matching cookie found in installed browsers. Paste your token below."
            }
        } catch {
            status = "Browser extract failed: \(error.localizedDescription). Paste your token below."
        }
    }
}
