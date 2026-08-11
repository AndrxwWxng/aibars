import SwiftUI
import AppKit

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

/// The settings window's type, by role.
///
/// Two sizes and two weights for the whole window, named by role rather than
/// written out at each call site: the browser row and the service row read as the
/// same kind of thing and were 12pt and 13pt in adjacent sections of one form,
/// which shows up only as a wobble in the line the eye lands on first. The 12pt
/// went with `Ramp.body` — a row's subject and the prose beside it are both
/// `Ramp.title` now, told apart by weight rather than by a point, which is what
/// 13/11/10 being macOS's own control ramp buys.
///
/// The middle rung is deliberately unspent here. `Ramp.detail` is the panel's
/// secondary reading and the chart's series label; in this window the line under
/// a subject is `Ramp.caption`, because that is where Alerts' log rows and
/// History's day summaries already set theirs, and one pane setting the same line
/// a point larger is that same wobble read down the sidebar instead of across a
/// row.
///
/// None of these is `Tokens.Ramp.figureDesign`, and that is the rule rather than
/// an oversight: SF Mono is for a run that is only digits and separators, and
/// this window has none. Every number here shares its run with a word — "3
/// sessions ready · 1 locked", "Unlock 4", "v0.4" — which is the mixed case, so
/// it is SF Pro with tabular figures. That still buys what the column needs:
/// a count re-read by a background sweep no longer shifts the words beside it.
private extension Font {
    /// A row's subject: a service, a browser, the app's own name.
    static var paneTitle: Font {
        .system(size: Tokens.Ramp.title, weight: Tokens.Ramp.emphasisWeight)
    }
    /// Prose, and whatever is typed into a field.
    static var paneBody: Font { .system(size: Tokens.Ramp.title).monospacedDigit() }
    /// The line under a title, a status, and the profile lines under that. Prose
    /// under a section is not here: it goes through `SectionFooter`, which sets
    /// this same size in the one place the whole window shares.
    static var paneCaption: Font { .system(size: Tokens.Ramp.caption).monospacedDigit() }
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

// `PaneFooter` was here: three lines that were `SectionFooter` under another
// name, in a window whose every other pane already used the shared one. Two
// copies of one voice is how a footer in one pane ends up a shade louder than
// the footer in the next, so the private one is gone rather than kept in step.
// Both footers in this file go through `SectionFooter`, and a new one has to.

public struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @State private var pane: Pane = .services
    /// What each browser holds, refreshed by a silent sweep. Empty until the
    /// first one lands.
    @State private var sources: [CookieExtractors.BrowserSource] = []
    /// The browser whose Keychain dialog is on screen, if any. One at a time by
    /// construction: unlocking is per browser now.
    @State private var unlockingSource: String?
    @State private var isScanning = false
    /// The outcome of the last action on a browser, kept per browser. A shared
    /// line would put Chrome's answer under Firefox's name.
    @State private var sourceNotes: [String: String] = [:]
    @State private var scanNote: String?

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

    /// The panes, in the order the sidebar lists them.
    ///
    /// Declaration order *is* that order — `allCases` is what the sidebar
    /// iterates — so the two new panes are placed rather than appended. History
    /// and Spend both answer "what has this cost me", which is a question about
    /// the services two rows up, and neither is a preference; Alerts, General
    /// and About are, so they stay together at the bottom.
    enum Pane: String, CaseIterable, Identifiable {
        case services, appearance, history, spend, alerts, general, about
        var id: String { rawValue }

        var title: String {
            switch self {
            case .services: return "Services"
            case .appearance: return "Appearance"
            case .history:  return "History"
            case .spend:    return "Spend"
            case .alerts:   return "Alerts"
            case .general:  return "General"
            case .about:    return "About"
            }
        }

        var symbol: String {
            switch self {
            case .services: return "square.grid.2x2"
            case .appearance: return "paintbrush"
            case .history:  return "chart.xyaxis.line"
            case .spend:    return "dollarsign.circle"
            case .alerts:   return "bell"
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
                // Warm graphite, the same ground the panel stands on. No material
                // and no scrim: the panel's scrim is the whole of the
                // application's translucency, and a form is a surface with
                // figures on it — a wallpaper showing through the ground under
                // them is what makes every contrast figure in the design system a
                // hope rather than a statement. No shadow and no top highlight
                // either: this window has three planes and each is a ground.
                .background(Tokens.Surface.base)
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
        // Opaque, and the last material in this window goes with it: the panel's
        // scrim over one material is the whole of the application's translucency,
        // so a sidebar blending the desktop through itself was the second one —
        // and it is the one that made a settings window on a bright wallpaper a
        // different colour from the panel it configures.
        //
        // `well` rather than `base`, because the plane change is now the only
        // thing dividing the sidebar from the pane: a hairline down the middle
        // would be a second vertical rule in a window whose Appearance pane
        // already has one, and chrome recessed under content is the way round
        // every native window has it. No `ignoresSafeArea` needed —
        // `background(_:)` over a `ShapeStyle` already ignores it, which is what
        // carries the colour up behind the transparent titlebar.
        .background(Tokens.Surface.well)
    }

    @ViewBuilder
    private var detail: some View {
        switch pane {
        case .services: providersTab
        case .appearance: AppearancePane()
        case .history:  HistoryPane()
        case .spend:    BudgetPane()
        case .alerts:   AlertsPane()
        case .general:  generalTab
        case .about:    aboutTab
        }
    }

    // MARK: - General

    private var generalTab: some View {
        Form {
            // First, because it is the first thing a Mac user comes to General
            // looking for, and because it is the one setting here that decides
            // whether the app is running at all — an app that has to be launched
            // by hand every morning is a menu bar app you stop having.
            //
            // It carries its own failure line: `SMAppService` refuses to register
            // a copy running out of Downloads or DerivedData, and the section
            // says so in place rather than leaving a switch that unticks itself.
            LaunchAtLoginSection()

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
            // No signpost section to Appearance: it is two rows up in the
            // sidebar, and a row that describes a tab without linking to it is
            // filler that reads like a broken control.
        }
        .formStyle(.grouped)
    }

    // MARK: - Services

    /// Sessions a Keychain approval would actually unlock. An unreadable cookie
    /// in a browser that has no key to ask for is not one of them, and counting
    /// it here would promise something no Unlock button can deliver.
    private var lockedTotal: Int {
        sources
            .filter { $0.requirement == .keychainKey }
            .reduce(0) { $0 + $1.locked }
    }

    private var providersTab: some View {
        Form {
            Section {
                if sources.isEmpty {
                    Text(isScanning
                         ? "Looking through your browsers…"
                         : "No browser on this Mac keeps its cookies somewhere aibars can read.")
                        .font(.paneCaption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    ForEach(sources) { source in
                        BrowserSourceRow(
                            source: source,
                            note: sourceNotes[source.id],
                            isBusy: unlockingSource == source.id,
                            // A Keychain dialog is modal to the user, not to the
                            // app. A second Unlock pressed while the first is
                            // waiting puts two dialogs on screen, neither of which
                            // says which browser it is for — the exact thing this
                            // pane exists to stop.
                            isBlocked: unlockingSource != nil && unlockingSource != source.id,
                            onUnlock: { Task { await unlock(source) } },
                            onGrantAccess: { WebLoginEnvironment.openFullDiskAccessSettings() }
                        )
                    }
                }
            } header: {
                sourcesHeader
            } footer: {
                SectionFooter(scanNote ?? sourcesFooter)
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
                SectionFooter("The switch controls whether a service appears in the dropdown.")
            }
        }
        .formStyle(.grouped)
        // Silent, so opening Settings cannot raise a Keychain dialog on its own.
        .task { await scan() }
    }

    private var sourcesHeader: some View {
        HStack(spacing: Tokens.Space.medium) {
            Text("Where sessions come from")
            Spacer(minLength: Tokens.Space.gutter)
            if isScanning {
                ProgressView()
                    .controlSize(.small)
            } else {
                // One button for the whole list, because looking is free and
                // asks nothing: only the per-browser Unlock touches a Keychain.
                // Off while one is waiting, though — re-reading a browser mid
                // dialog is how a second dialog gets on screen.
                Button("Check again") { Task { await recheck() } }
                    .controlSize(.small)
                    .disabled(unlockingSource != nil)
            }
        }
    }

    /// One line for the section, not one per row: the Keychain rule is the same
    /// for every browser in the list and repeating it nine times is noise.
    private var sourcesFooter: String {
        guard lockedTotal > 0 else {
            return "Every browser is listed separately. aibars reads sessions you're already logged into; it never signs you out of one."
        }
        return "\(lockedTotal) session\(lockedTotal == 1 ? " is" : "s are") sitting behind a browser's own Keychain key. Unlocking one asks about that browser only, and only when you press it."
    }

    /// Reads what each browser holds without asking for anything. Off the main
    /// thread: this copies every browser's cookie database.
    private func scan() async {
        let sweep = queries
        isScanning = true
        defer { isScanning = false }
        sources = await Task.detached(priority: .utility) {
            CookieExtractors.sessionSources(sweep)
        }.value
    }

    /// The user logged into something and wants aibars to look again. Nothing
    /// here allows a prompt, so it cannot put a dialog on screen — the browsers
    /// whose keys are already in hand are simply re-read.
    private func recheck() async {
        scanNote = nil
        sourceNotes.removeAll()
        await scan()
        let adopted = await state.adoptBrowserSessions()
        scanNote = adopted.isEmpty ? "No new sessions found." : connected(adopted)
        if !adopted.isEmpty { await state.refreshAll() }
    }

    /// One browser's Keychain key, one dialog, and nothing asked of the others.
    private func unlock(_ source: CookieExtractors.BrowserSource) async {
        let sweep = queries
        let id = source.id
        // The previous run's answer is not this run's answer, and leaving it
        // beside the spinner reads as a result that has already arrived.
        sourceNotes[id] = nil
        scanNote = nil
        unlockingSource = id
        defer { unlockingSource = nil }

        let readable = await Task.detached(priority: .utility) {
            CookieExtractors.unlock(id, for: sweep)
        }.value
        guard readable > 0 else {
            await scan()
            // A row that still asks for the key is a browser that has no key:
            // refused. One whose ask has gone while its sessions have not is a key
            // that worked on a lock it doesn't fit — Chrome's app-bound cookies do
            // exactly this — and calling that a refusal sends the user hunting for
            // a dialog they already answered.
            let refused = sources.first { $0.id == id }?.requirement == .keychainKey
            sourceNotes[id] = refused
                ? "Keychain access was refused, so \(source.name) stays locked."
                : "\(source.name)'s cookies need more than its Keychain key. aibars still can't read them."
            return
        }
        // The key is cached now, so the sweep that picks the sessions up needs no
        // prompt of its own — which is what keeps the other browsers silent.
        let adopted = await state.adoptBrowserSessions()
        await scan()
        sourceNotes[id] = adopted.isEmpty
            ? "Unlocked \(source.name). Every session in it was already connected."
            : connected(adopted)
        if !adopted.isEmpty { await state.refreshAll() }
    }

    /// What was connected, named. Unlocking accounts and then not listing them is
    /// the same as not unlocking them, and asking for more accounts is asking to
    /// see them — which is why this also lifts the single-account filter.
    private func connected(_ adopted: [String]) -> String {
        let extra = adopted.filter { state.provider(for: $0)?.accountID != nil }
        if !extra.isEmpty {
            AppearanceSettings.shared.showsAllAccounts = true
        }
        let names = adopted.compactMap { state.provider(for: $0)?.displayName }
        let unique = Array(Set(names)).sorted()
        return extra.isEmpty
            ? "Connected \(unique.joined(separator: ", "))."
            : "Connected \(adopted.count) account\(adopted.count == 1 ? "" : "s") — \(unique.joined(separator: ", ")). Now showing every account."
    }

    /// The same queries `AppState.adoptBrowserSessions` sweeps with: one per
    /// service, from whichever provider of it knows its cookie names. Several
    /// accounts of one service share a name and a domain, so asking twice would
    /// only copy each cookie database twice.
    private var queries: [CookieExtractors.Query] {
        var seen: Set<String> = []
        return state.providers.compactMap { provider -> CookieExtractors.Query? in
            guard let config = provider.webLogin,
                  let domain = config.cookieDomain,
                  seen.insert(provider.serviceID).inserted
            else { return nil }
            return CookieExtractors.Query(
                key: provider.serviceID,
                names: config.candidateCookieNames,
                domain: domain
            )
        }
    }

    // MARK: - About

    /// A literal that cannot fail — but `!` is not allowed to be the reason it
    /// cannot, and a missing link is a quiet corner of an About pane rather than
    /// a crash on the way in.
    private static let repository = URL(string: "https://github.com/AndrxwWxng/aibars")

    private var aboutTab: some View {
        VStack(spacing: Tokens.Space.large) {
            // The mark, not the meter. It used to be a `UsageMeterGlyph` given
            // four fixed levels, which is a reporting instrument drawing
            // something it is not reporting; `AppMark` is the same shape with
            // nothing to say, in the one colour the app keeps for itself.
            AppMark(size: Tokens.Control.aboutGlyph, tint: Tokens.Ink.arc)

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
                // Arc, because a text link is one of the four places it is
                // allowed. Not `.accentColor`: that one is the user's and is
                // spent on selection and focus, and a link is neither.
                Link("View on GitHub", destination: repository)
                    .font(.paneBody)
                    .foregroundStyle(Tokens.Ink.arc)
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

/// One browser in the Services pane: what it holds, and the one thing the user
/// can do about it.
///
/// A row per browser rather than one row naming the default browser. The sweep
/// reads every browser installed, each Chromium browser has its own Keychain key
/// and its own profiles, Safari needs Full Disk Access and Firefox needs nothing
/// — so "Use sessions from Firefox" with an "Unlock 4 more" button beside it was
/// naming one browser and prompting for all of them.
private struct BrowserSourceRow: View {
    let source: CookieExtractors.BrowserSource
    /// The result of the last action on this browser, which replaces the summary
    /// while it is worth reading.
    let note: String?
    let isBusy: Bool
    /// True while another browser's Keychain dialog is waiting for an answer.
    let isBlocked: Bool
    let onUnlock: () -> Void
    let onGrantAccess: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Space.gutter) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                // The same column a service logo occupies, so every row in this
                // pane starts its text at one x instead of two.
                .frame(width: Tokens.Control.settingsLogo)

            VStack(alignment: .leading, spacing: Tokens.Space.hairline) {
                Text(source.name)
                    .font(.paneTitle)
                Text(note ?? summary)
                    .font(.paneCaption)
                    .foregroundStyle(detailColor)
                    // A note names every service it just connected. It wraps
                    // rather than truncates: the tail of that list is the part
                    // that answers "did it find the account I care about".
                    .fixedSize(horizontal: false, vertical: true)

                if !profileLines.isEmpty {
                    VStack(alignment: .leading, spacing: Tokens.Space.hairline) {
                        ForEach(profileLines, id: \.self) { line in
                            Text(line)
                        }
                    }
                    .font(.paneCaption)
                    .foregroundStyle(.tertiary)
                    // Wraps like the line above it. A profile's name is the whole
                    // point of the line, and a truncated one names nothing.
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, Tokens.Space.tight)
                }
            }

            Spacer(minLength: Tokens.Space.gutter)

            action
                .controlSize(.small)
                .disabled(isBlocked)
                // A floor rather than a fixed width: this shares the column with
                // the service buttons and should line up with them, but "Grant
                // Access…" is longer than the column and truncating it is worse
                // than a button that reaches past it.
                .frame(minWidth: Tokens.Control.actionColumn, alignment: .trailing)
        }
        .padding(.vertical, Tokens.Space.tight)
    }

    /// Safari has a symbol of its own; nothing else here does, and a wrong logo
    /// is worse than a generic one.
    private var symbol: String {
        source.browser == .safari ? "safari" : "globe"
    }

    /// What this browser holds, in the fewest words that stay true.
    private var summary: String {
        if source.requirement == .fullDiskAccess {
            return "Needs Full Disk Access — macOS keeps Safari's cookies in a folder aibars can't open without it."
        }
        guard source.total > 0 else {
            return "Nothing signed in here that aibars can use."
        }
        var parts: [String] = []
        if source.readable > 0 {
            parts.append("\(source.readable) session\(source.readable == 1 ? "" : "s") ready")
        }
        if source.locked > 0 {
            // A key nobody has asked for is the only kind of locked a button can
            // fix. A cookie the browser wrote empty — or one Chrome sealed with
            // more than its Safe Storage key — is simply unreadable, and blaming
            // the Keychain for it points the user at a dialog that would not help.
            parts.append(source.requirement == .keychainKey
                         ? "\(source.locked) locked behind \(source.name)'s own Keychain key"
                         : "\(source.locked) aibars can't read")
        }
        return parts.joined(separator: " · ") + "."
    }

    /// How many profiles get a line of their own. Someone with twelve Chrome
    /// profiles would otherwise get a twelve-line row that pushes every service
    /// in the pane below the fold to say one thing twelve times.
    private static let namedProfileLimit = 4

    /// Which profile holds what, named only when there is more than one holding
    /// anything. "Profile 2 — 1 locked" is the question the Keychain dialog can't
    /// answer for you, and with a single profile it says nothing the line above
    /// hasn't. Past the limit the tail becomes one line, which still accounts for
    /// every session in it.
    private var profileLines: [String] {
        let holding = source.profiles.filter { $0.readable + $0.locked > 0 }
        guard holding.count > 1 else { return [] }
        guard holding.count > Self.namedProfileLimit else { return holding.map(Self.line(for:)) }
        let named = holding.prefix(Self.namedProfileLimit - 1)
        let rest = holding.dropFirst(named.count)
        let counts = Self.phrase(
            readable: rest.reduce(0) { $0 + $1.readable },
            locked: rest.reduce(0) { $0 + $1.locked }
        )
        return named.map(Self.line(for:)) + ["\(rest.count) more profiles — \(counts)"]
    }

    private static func line(for profile: CookieExtractors.BrowserSource.Profile) -> String {
        "\(profile.name) — \(phrase(readable: profile.readable, locked: profile.locked))"
    }

    /// "2 ready, 1 locked", leaving out whichever is zero — a profile line that
    /// reads "0 locked" invites a click on a button that isn't for it.
    private static func phrase(readable: Int, locked: Int) -> String {
        var parts: [String] = []
        if readable > 0 { parts.append("\(readable) ready") }
        if locked > 0 { parts.append("\(locked) locked") }
        return parts.joined(separator: ", ")
    }

    /// Orange for the rows that want the user and no others. Colouring every row
    /// makes the one that needs attention indistinguishable, and a note is an
    /// answer rather than a state.
    private var detailColor: Color {
        guard note == nil else { return Tokens.Ink.idle }
        return source.requirement == nil ? Tokens.Ink.idle : Tokens.Ink.attention
    }

    @ViewBuilder
    private var action: some View {
        if isBusy {
            ProgressView()
        } else if source.requirement == .keychainKey {
            Button("Unlock \(source.locked)", action: onUnlock)
                .buttonStyle(.borderedProminent)
                .help("Asks the Keychain for \(source.name)'s cookie key. No other browser is touched.")
        } else if source.requirement == .fullDiskAccess {
            Button("Grant Access…", action: onGrantAccess)
                .help("Opens Privacy & Security → Full Disk Access.")
        }
        // A browser with nothing locked has nothing to ask for: its sessions are
        // already connected, and a button that would do nothing is worse than an
        // empty column.
    }
}

/// A service aibars reads off this Mac rather than signs into.
///
/// Named, not derived. `webLogin == nil` is the wrong test: Z.ai and MiniMax
/// have no login page either and still want the connect window, because a
/// pasted key is something the user can actually give. These two have nothing
/// to give — the files are already there or they are not — so the credential
/// question does not apply to them and a Connect button in that column could
/// only ever fail. What the column offers instead is the way to go and look.
///
/// The paths come from the providers themselves rather than being written here
/// a second time: both honour an environment variable that moves the directory,
/// and a settings row pointing at `~/.claude/projects` while the reader is
/// somewhere else is worse than no row.
enum LocalSource: String, CaseIterable {
    case claudeCode = "claudecode"
    case openCode = "opencode"

    /// Where the files are. Asked for on demand — it resolves the environment
    /// and the home directory, which is not work for a view's body.
    var directory: URL {
        switch self {
        case .claudeCode: return ClaudeCodeScanner.defaultRoot()
        case .openCode:   return OpenCodeProvider.dataDirectory()
        }
    }

    /// What the row says it is reading, once there is something to read.
    var reads: String {
        switch self {
        case .claudeCode: return "Reads local files · session transcripts"
        case .openCode:   return "Reads local files · this Mac's sessions"
        }
    }

    /// And what it says when there is nothing there yet. Not "not connected":
    /// there is no connection to make, and sending someone to a sign-in they
    /// cannot complete is the failure this whole type exists to avoid.
    var absent: String {
        switch self {
        case .claudeCode: return "Nothing to read yet — run claude once."
        case .openCode:   return "Nothing to read yet — run an OpenCode session."
        }
    }

    /// Opens the directory in Finder, selecting it in its parent so the window
    /// that appears names the folder rather than showing its contents with no
    /// clue which folder they are.
    @MainActor
    func reveal() {
        let url = directory
        // A directory that does not exist yet cannot be selected, and Finder
        // answers a failed reveal by doing nothing at all. Its parent is the
        // useful second best: `~/.claude` exists long before `projects` does.
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
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

    /// Where this row's credential came from, for the one service that has
    /// three answers and gave none of them. Resolved in `.task` rather than in
    /// `body` because answering it stats a file, and a body runs on every
    /// refresh of every row in the pane.
    @State private var credentialOrigin: String?

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
                    // A floor rather than a fixed width, which is what the
                    // browser rows above already do and for the same reason:
                    // the column is sized for "Configure…" and "Reveal in
                    // Finder" is longer than it. Trailing-aligned, so every
                    // button in the pane still ends at one x — only the two
                    // long ones reach further left, instead of truncating.
                    .frame(minWidth: Tokens.Control.actionColumn, alignment: .trailing)
            }

            if namesAccounts { renameField }
        }
        .padding(.vertical, Tokens.Space.tight)
        .task { credentialOrigin = Self.credentialOrigin(forService: provider.serviceID) }
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

    /// The local source this row is, if it is one. A stored property would be
    /// wrong: the row is rebuilt from the provider, and this is a fact about
    /// the service rather than about the instance.
    private var localSource: LocalSource? { LocalSource(rawValue: provider.serviceID) }

    @ViewBuilder
    private var signInControl: some View {
        if let local = localSource {
            // No Connect and no Sign out. There is no credential either way,
            // and the switch beside this already does the only thing "stop
            // showing me this" can mean for a source that needs no permission.
            Button("Reveal in Finder") { local.reveal() }
                .help("Opens \(local.directory.path) in Finder.")
        } else if provider.isAuthenticated {
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
    ///
    /// Amber and red are two different asks and now say so. A sign-in that has
    /// expired — or a Keychain the user declined — is `attention`: there is
    /// something for them to do. A request that simply failed is `failure`:
    /// there is not, and colouring it amber sent people looking for a dialog
    /// that was never going to appear.
    ///
    /// And this is one of the only two places `Ink.ok` is allowed: a connection
    /// row here, and the status dot on a connected status-only service in the
    /// panel. Both are places where the connection *is* the reading. A panel row
    /// showing 92% has already proved it is connected, and a green tick beside
    /// that figure is ink spent saying what the figure said.
    private var statusColor: Color {
        guard provider.isAuthenticated else { return Tokens.Ink.idle }
        switch snapshot {
        case .success: return Tokens.Ink.ok
        case .failure(let error): return wantsTheUser(error) ? Tokens.Ink.attention : Tokens.Ink.failure
        case .none:    return Tokens.Ink.idle
        }
    }

    /// Whether the failure is one the user can act on.
    private func wantsTheUser(_ error: ProviderError) -> Bool {
        SessionStore.shared.isAccessDenied || error.isAuth
    }

    /// What the row says under the name. "Connected" alone leaves the obvious
    /// next question — connected to what plan, and is it actually working.
    private var status: String {
        if let local = localSource {
            return provider.isAuthenticated ? local.reads : local.absent
        }
        guard provider.isAuthenticated else {
            return provider.webLogin == nil ? "Needs a token" : "Not connected"
        }
        switch snapshot {
        case .success(let data):
            // Prefer the account over the plan: with more than one subscription
            // in the list, "which account" is the question "Connected" leaves.
            // The origin goes last, because it answers a question only the row
            // that has stopped working makes anyone ask.
            let plan = data.planName.map { PlanName.pretty($0, service: provider.displayName) }
            let lead = [account, plan].compactMap { $0 }.joined(separator: " · ").ifEmpty("Connected")
            return [lead, credentialOrigin].compactMap { $0 }.joined(separator: " · ")
        case .failure(let error):
            return "Connected · \(failureNote(error))"
        case .none:
            return (["Connected"] + [account, credentialOrigin].compactMap { $0 })
                .joined(separator: " · ")
        }
    }

    /// Where a Codex row's credential came from.
    ///
    /// Only Codex, and only because Codex is the one row the user may never
    /// have touched: it takes its own stored token, then the ChatGPT row's
    /// browser session, then the `codex` CLI's own auth file — three sources,
    /// two of them adopted off the machine. A row that works for a reason
    /// nobody stated is a row nobody can fix when it stops.
    ///
    /// Nothing here reads a token or the Keychain item: the credential
    /// metadata lives in UserDefaults, and the CLI rung is answered by the
    /// file's existence. `CodexAuth.load` would fall through to a keychain item
    /// whose ACL names the `codex` binary, and asking that question to label a
    /// settings row would put an access dialog on screen.
    static func credentialOrigin(forService serviceID: String) -> String? {
        guard serviceID == "codex" else { return nil }
        let store = SessionStore.shared
        if let source = store.credential(for: "codex")?.source {
            return source == .browserCookie ? "via browser session" : "via Keychain"
        }
        if store.credential(for: "chatgpt") != nil { return "via browser session" }
        let hasAuthFile = CodexAuth
            .authFileURLs(
                environment: ProcessInfo.processInfo.environment,
                home: FileManager.default.homeDirectoryForCurrentUser
            )
            .contains { FileManager.default.fileExists(atPath: $0.path) }
        return hasAuthFile ? "via Codex CLI" : nil
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

// Manual credential entry was here: a second dialog with its own width, inset,
// logo size and headline — 440/16/34/14pt-semibold against 460/20/26/headline for
// the same job, and the only thing that decided which one you got was whether the
// provider had a login page. It is `ConnectDialog` in `BrowserLoginView` now, at
// one set of measurements.
//
// A note rather than the doc comment this was, because `///` with nothing under it
// is documentation the next declaration added to the end of this file inherits
// silently.
