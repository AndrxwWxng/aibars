import SwiftUI

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

private extension View {
    /// `scrollContentBackground` is macOS 13+, which is the deployment target,
    /// but keep it guarded so the app still builds against older SDKs.
    @ViewBuilder
    func scrollContentBackgroundHidden() -> some View {
        if #available(macOS 13.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

public struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var showAuthSheet: AnyUsageProvider?
    @State private var pane: Pane = .services
    @State private var isAdopting = false
    @State private var adoptionStatus: String?
    /// Bumped on rename so the list redraws; the names live in UserDefaults
    /// rather than in observable state.
    @State private var renameTick = 0

    public init() {}

    /// Opens on a specific pane, for previews and snapshots — which otherwise
    /// can only ever see the default one.
    init(initialPane: Pane) {
        _pane = State(initialValue: initialPane)
    }

    enum Pane: String, CaseIterable, Identifiable {
        case services, appearance, general, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .services: return "Services"
            case .appearance: return "Appearance"
            case .general:  return "General"
            case .about:    return "About"
            }
        }

        var symbol: String {
            switch self {
            case .services: return "square.grid.2x2"
            case .appearance: return "paintbrush"
            case .general:  return "gearshape"
            case .about:    return "info.circle"
            }
        }
    }

    public var body: some View {
        // A plain split rather than NavigationSplitView: that one insists on a
        // collapse toggle in the toolbar, and every control shifts sideways when
        // the sidebar folds. The sidebar here is a fixed part of the window.
        HStack(spacing: 0) {
            sidebar
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                // The form's own scroll background is hidden and the pane paints
                // one colour behind everything, titlebar strip included. Two
                // backgrounds meeting partway down the pane is what produced the
                // dark band across the top.
                .scrollContentBackgroundHidden()
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(width: 800, height: 560)
        .sheet(item: $showAuthSheet) { provider in
            AuthSheet(provider: provider)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Pane.allCases) { item in
                SidebarRow(
                    title: item.title,
                    symbol: item.symbol,
                    isSelected: pane == item
                ) {
                    pane = item
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        // Clears the titlebar, which the sidebar now runs underneath.
        .padding(.top, 38)
        .frame(width: 176)
        .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .services: providersTab
        case .appearance: AppearancePane()
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
            Section {
                // The menu bar mark and everything else about how the panel
                // looks lives in Appearance now; two homes for one setting is
                // how they drift apart.
                LabeledContent("Appearance") {
                    Text("Density, colours, the menu bar mark and more")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("See the Appearance tab.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var lockedTotal: Int {
        state.lockedAccounts.values.reduce(0, +)
    }

    /// Accounts beyond the first for any service — what the toggle reveals.
    private var extraAccounts: Int {
        state.providers.count - Set(state.providers.map(\.serviceID)).count
    }

    private var providersTab: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    Image(systemName: "person.badge.key")
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Use sessions from \(DefaultBrowser.current().name)")
                            .font(.system(size: 12, weight: .medium))
                        Text(adoptionStatus ?? "Connects anything you're already logged into.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if isAdopting {
                        ProgressView().controlSize(.small)
                    } else {
                        // Two buttons rather than one with a computed style:
                        // buttonStyle takes a type, so it cannot be chosen at
                        // runtime without erasing it, and erasing a button style
                        // is a lot of machinery for one emphasis change.
                        if lockedTotal > 0 {
                            Button("Unlock \(lockedTotal) more") { Task { await adopt() } }
                                .buttonStyle(.borderedProminent)
                        } else {
                            Button("Check now") { Task { await adopt() } }
                        }
                    }
                }
            } footer: {
                if lockedTotal > 0 {
                    // These are found, not missing. Saying so is the difference
                    // between an actionable prompt and the app looking broken.
                    Text("\(lockedTotal) more account\(lockedTotal == 1 ? " is" : "s are") signed in elsewhere — reading them needs one Keychain approval, which only happens when you ask.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // One section for all of them, one line each. A section per service
            // meant reading the words "Show in menu bar" nine times down the
            // pane — more label than content, and it buried the services
            // themselves under their own settings.
            Section {
                ForEach(state.providers) { provider in
                    HStack(spacing: 10) {
                        ProviderLogo(
                            providerID: provider.serviceID,
                            fallbackName: provider.displayName,
                            fallbackColor: provider.accentColor,
                            size: 26
                        )
                        .opacity(provider.isEnabled ? 1 : 0.4)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.displayName)
                                .font(.system(size: 13, weight: .medium))
                            Text(status(for: provider))
                                .font(.caption)
                                .foregroundStyle(statusColor(for: provider))
                        }

                        Spacer()

                        Toggle("", isOn: Binding(
                            get: { provider.isEnabled },
                            set: { provider.setEnabled($0) }
                        ))
                        .labelsHidden()
                        .help(provider.isEnabled ? "Hide from the dropdown" : "Show in the dropdown")

                        signInControl(for: provider)
                            .controlSize(.small)
                    }
                    .padding(.vertical, 2)

                    // Only worth the space when there is something to tell apart.
                    if state.accountCount(ofService: provider.serviceID) > 1 {
                        TextField(
                            "Name this account",
                            text: Binding(
                                get: { AppState.customAccountName(for: provider.id) ?? "" },
                                set: {
                                    AppState.setCustomAccountName($0, for: provider.id)
                                    renameTick &+= 1
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .font(.caption)
                        .padding(.leading, 36)
                    }
                }
            } footer: {
                Text("The switch controls whether a service appears in the dropdown.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Green is reserved for "working". A connected service that isn't
    /// answering was reading as green, which is the one thing it isn't.
    private func statusColor(for provider: AnyUsageProvider) -> Color {
        guard provider.isAuthenticated else { return .secondary }
        if case .failure = state.snapshots[provider.id] { return .orange }
        return .green
    }

    /// What the row says under the name. "Connected" alone leaves the obvious
    /// next question — connected to what plan, and is it actually working.
    private func status(for provider: AnyUsageProvider) -> String {
        guard provider.isAuthenticated else {
            return provider.webLogin == nil ? "Needs a token" : "Not connected"
        }
        switch state.snapshots[provider.id] {
        case .success(let data):
            // Prefer the account over the plan: with more than one subscription
            // in the list, "which account" is the question "Connected" leaves.
            let plan = data.planName.map { PlanName.pretty($0, service: provider.displayName) }
            return [data.accountLabel, plan]
                .compactMap { $0 }
                .joined(separator: " · ")
                .ifEmpty("Connected")
        case .failure:
            return "Connected · not responding"
        case .none:
            return "Connected"
        }
    }

    private func adopt() async {
        isAdopting = true
        defer { isAdopting = false }
        // Retry refusals only. Rebuilding every extractor re-asked for the
        // browsers already approved, which is why pressing this repeatedly
        // produced a dialog per browser per press.
        CookieExtractors.retryLockedKeys()
        // The user clicked the button, so a keychain prompt is expected here.
        let adopted = await state.adoptBrowserSessions(allowingKeychainPrompt: true)
        if adopted.isEmpty {
            adoptionStatus = lockedTotal > 0
                ? "Keychain access was refused, so those accounts stay locked."
                : "No new sessions found in your browsers."
        } else {
            // Unlocking accounts and then not listing them is the same as not
            // unlocking them. Asking for more accounts is asking to see them.
            let extra = adopted.filter { state.provider(for: $0)?.accountID != nil }
            if !extra.isEmpty {
                AppearanceSettings.shared.showsAllAccounts = true
            }
            let names = adopted.compactMap { state.provider(for: $0)?.displayName }
            let unique = Array(Set(names)).sorted()
            adoptionStatus = extra.isEmpty
                ? "Connected \(unique.joined(separator: ", "))."
                : "Connected \(adopted.count) account\(adopted.count == 1 ? "" : "s") — \(unique.joined(separator: ", ")). Now showing every account."
            await state.refreshAll()
        }
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

/// One row of the settings sidebar. Styled to read as a native source-list
/// item without the collapse behaviour that comes with NavigationSplitView.
struct SidebarRow: View {
    let title: String
    let symbol: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .frame(width: 16)
                Text(title)
                    .font(.system(size: 13))
                Spacer(minLength: 0)
            }
            .foregroundStyle(isSelected ? Color.white : Color.primary)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(background)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }

    private var background: Color {
        if isSelected { return .accentColor }
        return Color.primary.opacity(isHovered ? 0.07 : 0)
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
                    providerID: provider.serviceID,
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

