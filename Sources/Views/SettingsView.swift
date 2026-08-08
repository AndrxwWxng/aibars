import SwiftUI

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// The settings window's type, by role.
///
/// Three sizes and three weights for the whole window, named by role rather
/// than written out at each call site: the browser row and the service row read
/// as the same kind of thing and were 12pt and 13pt in adjacent sections of one
/// form, which shows up only as a wobble in the line the eye lands on first.
private extension Font {
    /// A dialog's headline — the one place the heavier weight is used.
    static var paneHeadline: Font {
        .system(size: Tokens.Ramp.title, weight: Tokens.Ramp.titleWeight)
    }
    /// A row's subject: a service, a browser, the app's own name.
    static var paneTitle: Font {
        .system(size: Tokens.Ramp.title, weight: Tokens.Ramp.emphasisWeight)
    }
    /// The label over a field.
    static var paneLabel: Font {
        .system(size: Tokens.Ramp.body, weight: Tokens.Ramp.emphasisWeight)
    }
    /// Prose, and whatever is typed into a field.
    static var paneBody: Font { .system(size: Tokens.Ramp.body) }
    /// The line under a title, a section footer, a status.
    static var paneCaption: Font { .system(size: Tokens.Ramp.caption) }
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

/// One line of prose under a section. Every footer in the window is this one
/// treatment, so a pane cannot quietly acquire a louder one.
private struct PaneFooter: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.paneCaption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

public struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var pane: Pane = .services
    @State private var isAdopting = false
    @State private var adoptionStatus: String?

    public init() {}

    /// Opens on a specific pane, for previews and snapshots — which otherwise
    /// can only ever see the default one.
    init(initialPane: Pane) {
        _pane = State(initialValue: initialPane)
    }

    /// The floor for the window, decided in one place.
    ///
    /// The sidebar is a fixed width, the Appearance form declares a minimum and
    /// its preview column is capped, so those three plus the divider *are* the
    /// minimum. Written as a literal instead it disagreed with them by 50-80pt,
    /// and the column that gave way was the form — the only one of the three
    /// without a fixed frame. `SettingsWindowController.minSize` has to read
    /// this number too, or AppKit lets the user drag the window narrower than
    /// SwiftUI can lay out and the preview column is cut off at the right edge.
    public static let minimumContentSize = CGSize(
        width: Tokens.Control.settingsMinWidth,
        height: Tokens.Control.settingsMinHeight
    )

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
        // No ideal size: the window controller opens at a size of its own, and
        // an ideal three points above the minimum only ever described the same
        // window twice.
        .frame(
            minWidth: Self.minimumContentSize.width,
            maxWidth: .infinity,
            minHeight: Self.minimumContentSize.height,
            maxHeight: .infinity
        )
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.tight) {
            ForEach(Pane.allCases) { item in
                SelectableChip(
                    title: item.title,
                    symbol: item.symbol,
                    isSelected: pane == item
                ) {
                    pane = item
                }
            }
            Spacer()
        }
        .padding(.horizontal, Tokens.Space.medium)
        // Clears the titlebar, which the sidebar now runs underneath.
        .padding(.top, Tokens.Control.titlebarInset)
        .frame(width: Tokens.Control.sidebarWidth)
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

    // MARK: - General

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
                        .font(.paneCaption)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                PaneFooter(text: "See the Appearance tab.")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Services

    private var lockedTotal: Int {
        state.lockedAccounts.values.reduce(0, +)
    }

    private var providersTab: some View {
        Form {
            Section {
                browserRow
            } footer: {
                if lockedTotal > 0 {
                    // These are found, not missing. Saying so is the difference
                    // between an actionable prompt and the app looking broken.
                    PaneFooter(text: "\(lockedTotal) more account\(lockedTotal == 1 ? " is" : "s are") signed in elsewhere — reading them needs one Keychain approval, which only happens when you ask.")
                }
            }

            // One section for all of them, one line each. A section per service
            // meant reading the words "Show in menu bar" nine times down the
            // pane — more label than content, and it buried the services
            // themselves under their own settings.
            Section {
                ForEach(state.providers) { provider in
                    ServiceRow(
                        provider: provider,
                        snapshot: state.snapshots[provider.id],
                        // A name for one account is only worth the space once
                        // there is another account to tell it apart from.
                        namesAccounts: state.accountCount(ofService: provider.serviceID) > 1,
                        onConfigure: {
                            LoginWindowController.show(provider: provider) { success in
                                if success { Task { await state.refreshAll() } }
                            }
                        },
                        onConnected: { Task { await state.refreshAll() } }
                    )
                }
            } footer: {
                PaneFooter(text: "The switch controls whether a service appears in the dropdown.")
            }
        }
        .formStyle(.grouped)
    }

    private var browserRow: some View {
        HStack(spacing: Tokens.Space.gutter) {
            Image(systemName: "person.badge.key")
                .foregroundStyle(.secondary)
                // The same column a service logo occupies, so both rows in this
                // pane start their text at one x instead of two.
                .frame(width: Tokens.Control.settingsLogo)

            VStack(alignment: .leading, spacing: Tokens.Space.hairline) {
                Text("Use sessions from \(DefaultBrowser.current().name)")
                    .font(.paneTitle)
                Text(adoptionStatus ?? "Connects anything you're already logged into.")
                    .font(.paneCaption)
                    .foregroundStyle(.secondary)
                    // Nine services adopted at once names all nine. It wraps
                    // rather than truncates: the tail of that list is the part
                    // that answers "did it find the account I care about".
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Tokens.Space.gutter)

            adoptionControl
                .controlSize(.small)
                // A floor rather than a fixed width: this shares the column with
                // the service buttons and should line up with them, but "Unlock
                // 12 more" is longer than the column and truncating the count is
                // worse than a button that reaches past it.
                .frame(minWidth: Tokens.Control.actionColumn, alignment: .trailing)
        }
        .padding(.vertical, Tokens.Space.tight)
    }

    @ViewBuilder
    private var adoptionControl: some View {
        if isAdopting {
            ProgressView()
        } else if lockedTotal > 0 {
            // Two buttons rather than one with a computed style: buttonStyle
            // takes a type, so it cannot be chosen at runtime without erasing
            // it, and erasing a button style is a lot of machinery for one
            // emphasis change.
            Button("Unlock \(lockedTotal) more") { Task { await adopt() } }
                .buttonStyle(.borderedProminent)
        } else {
            Button("Check now") { Task { await adopt() } }
        }
    }

    private func adopt() async {
        isAdopting = true
        // The previous run's answer is not this run's answer, and leaving it
        // beside the spinner reads as a result that has already arrived.
        adoptionStatus = nil
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

    // MARK: - About

    /// A literal that cannot fail — but `!` is not allowed to be the reason it
    /// cannot, and a missing link is a quiet corner of an About pane rather than
    /// a crash on the way in.
    private static let repository = URL(string: "https://github.com/aibars/aibars")

    private var aboutTab: some View {
        VStack(spacing: Tokens.Space.large) {
            UsageMeterGlyph(
                levels: [0.9, 0.65, 0.4, 0.2],
                alertColor: .accentColor,
                alertThreshold: 0,
                height: Tokens.Control.aboutGlyph
            )

            VStack(spacing: Tokens.Space.tight) {
                Text("aibars").font(.paneTitle)
                Text("v\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.1")")
                    .font(.paneBody)
                    .foregroundStyle(.secondary)
            }

            Text("Open-source AI subscription usage monitor.\nMIT License.")
                .font(.paneBody)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            if let repository = Self.repository {
                Link("View on GitHub", destination: repository)
                    .font(.paneBody)
            }

            Text("Product names and logos are trademarks of their respective owners.")
                .font(.paneCaption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(Tokens.Space.paneMargin)
    }
}

/// One service in the Services pane: its mark, what state it is in, the switch
/// that hides it, and the one button that changes its connection.
///
/// A view of its own because it has to observe the provider. As rows inlined
/// into `SettingsView.body` these read `isEnabled` and `isAuthenticated` off an
/// object nothing in that view observed — `AppState` republishes when its own
/// arrays change, not when a provider flips a flag — so the switch wrote the new
/// value and then redrew from the old one, and Sign out left a row still
/// offering to sign out.
private struct ServiceRow: View {
    @ObservedObject var provider: AnyUsageProvider
    let snapshot: Result<UsageData, ProviderError>?
    /// True when this service is signed into more than once, which is the only
    /// time naming one account earns a field of its own.
    let namesAccounts: Bool
    let onConfigure: () -> Void
    let onConnected: () -> Void

    /// The name the user is giving this account, held here while they type.
    /// Bound straight through to `AppState.setCustomAccountName` the field was
    /// unusable: that setter trims, so a typed space was written, read back
    /// trimmed, and swallowed on the way to the screen — the field could not be
    /// made to hold two words.
    @State private var accountName: String

    init(
        provider: AnyUsageProvider,
        snapshot: Result<UsageData, ProviderError>?,
        namesAccounts: Bool,
        onConfigure: @escaping () -> Void,
        onConnected: @escaping () -> Void
    ) {
        self.provider = provider
        self.snapshot = snapshot
        self.namesAccounts = namesAccounts
        self.onConfigure = onConfigure
        self.onConnected = onConnected
        _accountName = State(initialValue: AppState.customAccountName(for: provider.id) ?? "")
    }

    /// The leading column every row in this pane shares: the mark, and the
    /// gutter between it and the text. Named because the rename field has to
    /// clear it exactly to line up with the name it renames.
    private static let textIndent = Tokens.Control.settingsLogo + Tokens.Space.gutter

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.medium) {
            HStack(spacing: Tokens.Space.gutter) {
                ProviderLogo(
                    providerID: provider.serviceID,
                    fallbackName: provider.displayName,
                    fallbackColor: provider.accentColor,
                    size: Tokens.Control.settingsLogo
                )
                .opacity(provider.isEnabled ? 1 : Tokens.Dim.disabled)

                VStack(alignment: .leading, spacing: Tokens.Space.hairline) {
                    Text(provider.displayName)
                        .font(.paneTitle)
                        .lineLimit(1)
                    Text(status)
                        .font(.paneCaption)
                        .foregroundStyle(statusColor)
                        // A sixty-character account label wraps once and then
                        // gives up its middle: an email's domain says which
                        // account this is, and its tail is where the domain is.
                        .lineLimit(2)
                        .truncationMode(.middle)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Tokens.Space.gutter)

                // Labelled for VoiceOver and then hidden: nine unlabelled
                // switches down one pane announce nothing but "on" and "off".
                // The label says what the switch controls, the tooltip says what
                // clicking it would do — those are not the same sentence.
                Toggle("Show \(provider.displayName) in the dropdown", isOn: Binding(
                    get: { provider.isEnabled },
                    set: { provider.setEnabled($0) }
                ))
                .labelsHidden()
                .help(provider.isEnabled ? "Hide from the dropdown" : "Show in the dropdown")

                signInControl
                    .controlSize(.small)
                    // One width for every state, or the column of them steps in
                    // and out as services connect.
                    .frame(width: Tokens.Control.actionColumn)
            }

            if namesAccounts { renameField }
        }
        .padding(.vertical, Tokens.Space.tight)
    }

    /// Indented to start where the name it renames starts, so it reads as
    /// belonging to the row above rather than to the section.
    private var renameField: some View {
        // A prompt, not a title: inside a grouped `Form` a titled field hands
        // its title to the label column, which is the column this row is
        // deliberately indenting past.
        TextField(text: $accountName, prompt: Text("Name this account")) {
            Text("Account name")
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .font(.paneBody)
        .padding(.leading, Self.textIndent)
        .onChange(of: accountName) { name in
            AppState.setCustomAccountName(name, for: provider.id)
        }
    }

    @ViewBuilder
    private var signInControl: some View {
        if provider.isAuthenticated {
            Button("Sign out") {
                Task { try? await provider.signOut() }
            }
        } else {
            // Every method — browser session, pasted key, endpoint plus key —
            // goes through the same window, so the button says the same thing
            // regardless of which one this service uses.
            Button("Connect…", action: onConfigure)
                .buttonStyle(.borderedProminent)
        }
    }

    /// Green is reserved for "working", so it is the one answer this cannot give
    /// early: a service that has been connected for two seconds and reported
    /// nothing yet is idle, not healthy, and a service that is connected and not
    /// answering wants the user rather than a tick.
    private var statusColor: Color {
        guard provider.isAuthenticated else { return Tokens.Ink.idle }
        switch snapshot {
        case .success: return Tokens.Ink.ok
        case .failure: return Tokens.Ink.attention
        case .none:    return Tokens.Ink.idle
        }
    }

    /// What the row says under the name. "Connected" alone leaves the obvious
    /// next question — connected to what plan, and is it actually working.
    private var status: String {
        guard provider.isAuthenticated else {
            return provider.webLogin == nil ? "Needs a token" : "Not connected"
        }
        switch snapshot {
        case .success(let data):
            // Prefer the account over the plan: with more than one subscription
            // in the list, "which account" is the question "Connected" leaves.
            let plan = data.planName.map { PlanName.pretty($0, service: provider.displayName) }
            return [account, plan]
                .compactMap { $0 }
                .joined(separator: " · ")
                .ifEmpty("Connected")
        case .failure(let error):
            return "Connected · \(failureNote(error))"
        case .none:
            return account.map { "Connected · \($0)" } ?? "Connected"
        }
    }

    /// Which account this row is: what the user called it, else what the service
    /// says, else the browser profile the session came from. Three rows reading
    /// "Gemini · Connected" are three rows nobody can tell apart — and the
    /// rename fields under them inherit the problem.
    private var account: String? {
        if let named = AppState.customAccountName(for: provider.id) { return named }
        if case .success(let data) = snapshot,
           let label = data.accountLabel, !label.isEmpty {
            return label
        }
        return provider.browserOrigin
    }

    /// Why it isn't answering, where the answer is short enough to sit under a
    /// name. A refused Keychain fails every service at once, and nine rows
    /// reading "not responding" send the user looking for nine faults.
    private func failureNote(_ error: ProviderError) -> String {
        if SessionStore.shared.isAccessDenied { return "Keychain access denied" }
        return error.isAuth ? "sign-in expired" : "not responding"
    }
}

/// Manual credential entry, for providers with no hosted login page to host.
///
/// The same anatomy as `ConnectDialog` and now the same measurements: one width,
/// one inset, one logo size, one headline. They were 460/20/26/headline and
/// 440/16/34/14pt-semibold for the same dialog, and the only thing that decided
/// which you got was whether the provider had a login page.
