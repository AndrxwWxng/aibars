import SwiftUI

/// One service being connected, and everything the connect dialog draws.
///
/// This replaces `BrowserLoginCoordinator.Phase`, which had five cases for a job
/// with a dozen honest outcomes: a session sitting in three browser profiles, a
/// session found and not readable, a credential the service rejected outright, an
/// account whose session quietly expired, a browser whose cookies cannot be read
/// on this machine at all. All of those were `.waiting` or `.failed(String)`, so
/// the window could only say "waiting for your session…" or hand the user a
/// sentence and no way to act on it.
///
/// Exactly one `Stage` is true at a time, and every control on screen comes from
/// `picks` and `actions`. A stage therefore cannot acquire a button that cannot
/// work in it — which is what "Paste a token instead" was for MiniMax (whose
/// token field was already open) and what "Check now" was for a user whose
/// Keychain read had been refused.
@MainActor
public final class ConnectionFlow: ObservableObject {

    // MARK: - How a service is connected

    /// The three ways in, derived from the provider rather than declared, so a
    /// new provider cannot forget to say which one it uses.
    public enum Method: Equatable {
        /// A session cookie, which a browser sweep can find on its own.
        case session(cookieNames: [String], domain: String)
        /// The page shows a token to copy (Copilot's PAT form, DeepSeek's API
        /// keys). There is nothing to watch for: the token does not exist until
        /// the user has generated it.
        case tokenFromPage(url: URL, hint: String)
        /// No hosted login page at all (MiniMax). `needsEndpoint` is true when
        /// the provider also needs to be told where to look.
        case pastedKey(hint: String, needsEndpoint: Bool)

        public static func resolve(for provider: AnyUsageProvider) -> Method {
            guard let config = provider.webLogin else {
                // Keyed on the capability, not on `provider.id == "minimax"`:
                // that comparison silently handed the generic text to a second
                // account called "minimax#2".
                return provider.needsEndpointConfiguration
                    ? .pastedKey(
                        hint: "Point aibars at any endpoint that returns JSON usage data, and give it a token with read access.",
                        needsEndpoint: true
                    )
                    : .pastedKey(
                        hint: "Paste a token with read access to this service's usage endpoint.",
                        needsEndpoint: false
                    )
            }
            switch config.capture {
            case .cookie(_, let domainSuffix):
                return .session(cookieNames: config.candidateCookieNames, domain: domainSuffix)
            case .tokenShownOnPage:
                return .tokenFromPage(url: config.startURL, hint: config.hint)
            }
        }

        /// Whether a browser sweep could ever produce this credential. False for
        /// both token methods, which is why the dialog must not offer to watch
        /// for a cookie that will never appear.
        public var isDiscoverable: Bool {
            if case .session = self { return true }
            return false
        }
    }

    // MARK: - A session we could connect

    /// A session found in a browser profile, and whether it is already spoken
    /// for. Identity is the browser and profile rather than the cookie value:
    /// logging out and back in changes the value, and that is the same account.
    public struct Candidate: Identifiable, Equatable {
        public let browser: BrowserCookie.Browser
        public let profile: String?
        /// "Chrome · Work", as `BrowserCookie.origin` spells it.
        public let label: String
        /// The provider id of another account of this service that already holds
        /// this exact session. Offering it again would move one account's
        /// credential onto another's row.
        public let claimedBy: String?

        public var id: String { "\(browser.rawValue)|\(profile ?? "")" }
        public var isClaimedElsewhere: Bool { claimedBy != nil }

        public init(browser: BrowserCookie.Browser, profile: String?, label: String, claimedBy: String?) {
            self.browser = browser
            self.profile = profile
            self.label = label
            self.claimedBy = claimedBy
        }
    }

    /// Sessions that are present and unreadable. Chromium keeps its cookie key
    /// in the login keychain, and a sweep the user did not ask for will not raise
    /// that dialog — so these are found, not missing, and saying so is the
    /// difference between an actionable prompt and the app looking broken.
    public struct Locked: Equatable {
        public let count: Int
        /// True once the user has been asked and said no. Nothing retries after
        /// that; the dialog would otherwise come back on every poll tick.
        public let keychainRefused: Bool
    }

    /// What a token-entry stage needs to explain itself.
    public struct TokenRequest: Equatable {
        public let hint: String
        /// The page the token comes from, when there is one to reopen.
        public let pageURL: URL?
        public let needsEndpoint: Bool
    }

    // MARK: - The state machine

    /// What this connection is doing, one case at a time.
    public enum Stage: Equatable {
        case idle
        /// Looking for a session that already exists, before sending anyone
        /// anywhere.
        case checkingBrowser
        /// More than one session, so which account this is, is the user's call.
        case choosing([Candidate])
        /// This account was connected at `origin` and its credential has gone.
        case expired(origin: String)
        case locked(Locked)
        /// The credential cannot be read on this machine at all.
        case unreadable(DefaultBrowser.Limitation)
        /// Waiting for the user to paste something.
        case needsToken(TokenRequest)
        /// Watching for a session, and which one we will accept.
        case watching(Candidate?)
        case captured(origin: String)
        case verifying
        case connected(origin: String?, summary: String?)
        /// Credential held, the service answered badly. Still connected: this is
        /// not a sign-in problem and must not offer a sign-in button.
        case notResponding(message: String)
        /// The service rejected the credential, so it has been dropped.
        case rejected(message: String)
        /// The poll ran out. Bounded on purpose — see `watchAttempts`.
        case timedOut
        case failed(message: String)
    }

    /// Which of `Tokens.Ink` a stage's headline is drawn in. Connection state is
    /// the one thing in the app with no single source of colour, which is how the
    /// same condition came to read orange in one pane and red in another.
    ///
    /// Never the usage ramp and never `AppearanceSettings.tint`: a connection is
    /// not a reading, so nothing here walks grey to amber to red with a number
    /// behind it. The two alarm hues are still the ramp's own amber and red
    /// rather than a second pair the user has to learn — the ramp says "this is
    /// nearly full", these say "this needs you", and one palette carries both.
    /// Never `Ink.arc` either: the app's own colour has a closed list of call
    /// sites and a state is not on it.
    ///
    /// `Ink.ok` is spent here deliberately. Green beside a figure is redundant,
    /// because a row reporting 92% has already proved the connection works —
    /// which is why the panel body has no use for it. This window has no figure:
    /// "Connected." is the whole reading, and the ink is doing real work rather
    /// than decorating one. It never does it alone — the word and `symbol`'s
    /// tick say the same thing, so the state survives greyscale.
    public enum Tone {
        case ok, attention, failure, idle

        public var ink: Color {
            switch self {
            case .ok:        return Tokens.Ink.ok
            case .attention: return Tokens.Ink.attention
            case .failure:   return Tokens.Ink.failure
            case .idle:      return Tokens.Ink.idle
            }
        }
    }

    /// The controls a stage deserves, and nothing else.
    public enum Action: Equatable, Identifiable {
        /// Adopt one specific discovered session.
        case connectTo(Candidate)
        case signInAgain
        case openPageAgain
        case checkNow
        /// Ask the Keychain for this service, because the user asked.
        case unlock
        case fullDiskAccess
        case retryFetch

        public var id: String {
            switch self {
            case .connectTo(let candidate): return "connect|\(candidate.id)"
            case .signInAgain:              return "signInAgain"
            case .openPageAgain:            return "openPageAgain"
            case .checkNow:                 return "checkNow"
            case .unlock:                   return "unlock"
            case .fullDiskAccess:           return "fullDiskAccess"
            case .retryFetch:               return "retryFetch"
            }
        }

        public var label: String {
            switch self {
            case .connectTo:      return "Connect"
            case .signInAgain:    return "Sign in again"
            case .openPageAgain:  return "Open page again"
            case .checkNow:       return "Check now"
            case .unlock:         return "Unlock with Keychain"
            case .fullDiskAccess: return "Open Full Disk Access…"
            case .retryFetch:     return "Try again"
            }
        }

        /// Whether this is the one thing to do here. `openPageAgain` never is:
        /// it is the escape hatch beside whatever the stage is actually asking,
        /// and the dialog draws that as a link rather than a button.
        ///
        /// The emphasis the true case earns is the user's accent, which keeps
        /// primary buttons. `Tokens.Ink.arc` is a different fact and never fills
        /// a control: the app's own colour has a closed list of call sites, and
        /// on that list Connect is `.bordered`. `connectTo` sits outside this
        /// question in any case — it never reaches `actions`, because the picker
        /// draws its own Connect per row — so what it answers here is only what a
        /// later call site would inherit.
        public var isProminent: Bool {
            switch self {
            case .openPageAgain: return false
            default:             return true
            }
        }
    }

    // MARK: - State

    @Published public private(set) var stage: Stage = .idle
    /// Whether the manual field is on screen. Open from the start for the token
    /// methods, where it is the whole flow.
    @Published public private(set) var showsTokenField: Bool
    @Published public var pastedToken: String = ""
    @Published public var endpoint: String = ""

    public let provider: AnyUsageProvider
    public let method: Method
    public let browser: DefaultBrowser

    /// Ten minutes at a two-second cadence. Long enough for a password manager,
    /// a 2FA code and a captcha; short enough not to poll a window the user
    /// walked away from until they quit the app.
    private static let watchAttempts = 300
    private static let watchInterval: UInt64 = 2_000_000_000

    private let config: WebLoginConfig?
    /// Where this account was last connected, when its credential vanished
    /// without the user asking. `browserOrigin` outlives the credential —
    /// `AppState.discardRejectedCredential` drops the token and leaves it — so it
    /// is the only thing that still says which profile this account was.
    private let knownOrigin: String?

    /// Candidate id to cookie value. The values stay private rather than riding
    /// along on `Candidate`: `stage` is published, and a credential has no
    /// business in view state.
    private var values: [String: String] = [:]
    /// Sessions that were already in the browser when we started watching. The
    /// user is logging in to something new, so these are not what we are waiting
    /// for — this is what stopped a poll from instantly "capturing" the very
    /// session the user opened the window to replace.
    private var ignoredValues: Set<String> = []
    /// Found, readable, and already connected to another account of this service.
    private var claimedAway: [Candidate] = []
    private var watchTask: Task<Void, Never>?
    /// The one-shot work: a sweep, an adoption, a retried fetch. Held separately
    /// from `watchTask` because `watch(for:)` cancels that one, and a sweep that
    /// ends in `watch(for: nil)` would otherwise cancel itself mid-triage.
    private var sweepTask: Task<Void, Never>?
    /// A Keychain dialog only ever appears because the user asked for it, so
    /// every sweep is silent until they press Unlock or Check now.
    private var mayPromptKeychain = false
    /// Set once an allowed prompt came back with nothing readable — the user
    /// dismissed the dialog.
    ///
    /// Deliberately not `mayPromptKeychain`, which answers "has the user asked"
    /// and stays true after an *approval*. Reporting that as a refusal put
    /// "Keychain access was refused, so those sessions stay locked" on screen
    /// next to an Unlock button that would have worked.
    private var keychainRefused = false

    public init(provider: AnyUsageProvider, method: Method? = nil) {
        let resolved = method ?? Method.resolve(for: provider)
        self.provider = provider
        self.method = resolved
        self.config = provider.webLogin
        self.browser = DefaultBrowser.current()
        self.knownOrigin = Self.expiredOrigin(of: provider)
        // Nothing to watch for in the token flows, so the field starts open.
        self.showsTokenField = !resolved.isDiscoverable
        self.endpoint = provider.configuredEndpoint ?? ""
    }

    private static func expiredOrigin(of provider: AnyUsageProvider) -> String? {
        guard !provider.isAuthenticated,
              let origin = provider.browserOrigin,
              // A deliberate sign-out is not an expiry, and reconnecting it is
              // the user's business rather than something to offer unprompted.
              !AppState.signedOutProviders.contains(provider.id)
        else { return nil }
        return origin
    }

    // MARK: - Entry

    /// Starts the flow. Safe to call again: reopening the window must not
    /// restart a poll that is already running.
    public func begin() {
        // Ordering the window out cancels the poll on the way past. Coming back
        // to a stage that reads "waiting for you to log in…" with nothing
        // actually watching is a window that can only ever time out, so the
        // watch is picked up again rather than left as a claim about a task that
        // no longer exists.
        if case .watching(let target) = stage, watchTask == nil {
            watch(for: target)
            return
        }
        guard stage == .idle else { return }
        switch method {
        case .pastedKey(let hint, let needsEndpoint):
            // No page and no session: opening a browser here would be opening a
            // browser at nothing.
            stage = .needsToken(TokenRequest(hint: hint, pageURL: nil, needsEndpoint: needsEndpoint))
        case .tokenFromPage(let url, let hint):
            openPage()
            stage = .needsToken(TokenRequest(hint: hint, pageURL: url, needsEndpoint: false))
        case .session:
            // `supportsAutomaticCapture` is exactly "no limitation", and the
            // limitation is the thing worth showing, so read it directly.
            guard let limitation = browser.limitation else {
                checkThenConnect()
                return
            }
            // The user still has to log in to get a token out, so the page is
            // worth opening — we just cannot read the result afterwards.
            openPage()
            showsTokenField = true
            stage = .unreadable(limitation)
        }
    }

    private func checkThenConnect() {
        stage = .checkingBrowser
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            guard let self else { return }
            let sweep = await self.sweep(allowingKeychainPrompt: false)
            // Copying every browser's cookie database takes seconds, and the
            // dialog's way out during them says "Cancel". Without this, closing
            // it still opened a login page and started a ten-minute poll.
            guard !Task.isCancelled else { return }
            await self.triage(sweep)
        }
    }

    public func perform(_ action: Action) {
        switch action {
        case .connectTo(let candidate):
            sweepTask?.cancel()
            sweepTask = Task { await adopt(candidate) }
        case .signInAgain:
            openPage()
            ignoreExistingSessions()
            watch(for: nil)
        case .openPageAgain:
            openPage()
        case .checkNow:
            sweepTask?.cancel()
            sweepTask = Task { await checkNow() }
        case .unlock:
            sweepTask?.cancel()
            sweepTask = Task { await unlock() }
        case .fullDiskAccess:
            WebLoginEnvironment.openFullDiskAccessSettings()
        case .retryFetch:
            sweepTask?.cancel()
            sweepTask = Task {
                // A refused Keychain read is cached for the life of the process,
                // so the retry would read the same refusal back and the button
                // would provably do nothing. `AppState.refreshAll` clears it for
                // the same reason on a user-initiated refresh.
                if SessionStore.shared.isAccessDenied {
                    SessionStore.shared.invalidateCache()
                }
                await verify(origin: nil)
            }
        }
    }

    /// Shows or hides the manual field. Only ever hidden for a discoverable
    /// method — for the token methods it is the flow itself.
    public func toggleTokenField() {
        guard method.isDiscoverable else { return }
        showsTokenField.toggle()
    }

    public func cancel() {
        stopWatching()
        sweepTask?.cancel()
        sweepTask = nil
    }

    /// Ends the poll and nothing else. `adopt` and `submitToken` run inside the
    /// sweep task themselves, so the full `cancel()` there would cancel the save
    /// they are in the middle of and report it as the service not responding.
    private func stopWatching() {
        watchTask?.cancel()
        watchTask = nil
    }

    // MARK: - Triage

    private struct Sweep {
        let candidates: [Candidate]
        let locked: Int
    }

    /// What to do with what a sweep found.
    private func triage(_ sweep: Sweep) async {
        let offerable = self.offerable(from: sweep.candidates)

        // A session that comes back at the origin this account was connected at
        // is a session expiring and being renewed, which was never the user's
        // decision. This is the one adoption that should still be silent.
        if let knownOrigin, let match = offerable.first(where: { $0.label == knownOrigin }) {
            await adopt(match)
            return
        }

        if offerable.count > 1 {
            // Picking the first is how the wrong profile got connected while the
            // user sat there deliberately signing into the other one.
            stage = .choosing(offerable)
            return
        }
        if let only = offerable.first {
            await adopt(only)
            return
        }
        if sweep.locked > 0 {
            stage = .locked(Locked(count: sweep.locked, keychainRefused: keychainRefused))
            return
        }
        if let knownOrigin {
            // Saying nothing and reopening a login page for an account that was
            // working ten minutes ago reads as the app having forgotten them.
            stage = .expired(origin: knownOrigin)
            return
        }
        openPage()
        ignoreExistingSessions()
        watch(for: nil)
    }

    /// The sessions worth offering: not already connected to a sibling account,
    /// and not the one this account is connected with right now.
    ///
    /// The second half matters because "Sign in" on a connected row means "sign
    /// in as somebody else". Re-adopting the session it already holds would
    /// verify it, report success and close the window on a user who had asked
    /// for the opposite.
    private func offerable(from candidates: [Candidate]) -> [Candidate] {
        var result = candidates.filter { !$0.isClaimedElsewhere }
        if provider.isAuthenticated, let held = heldSession {
            result.removeAll { values[$0.id] == held }
        }
        return result
    }

    /// The browser session this account currently holds. Only read for a
    /// browser-derived credential, which lives in memory — a pasted one is in the
    /// Keychain, and reaching for it here would raise a dialog nobody asked for.
    private var heldSession: String? {
        guard SessionStore.shared.credential(for: provider.id)?.source == .browserCookie else {
            return nil
        }
        return SessionStore.shared.token(for: provider.id)
    }

    /// One look at the browsers. `searchAll` rather than `firstAvailableCookie`
    /// because the profile a session came from is the account's identity, and
    /// "first one that answers" cannot tell two accounts apart.
    private func sweep(allowingKeychainPrompt: Bool) async -> Sweep {
        guard case .session(let names, let domain) = method else {
            return Sweep(candidates: [], locked: 0)
        }
        let key = provider.serviceID
        let query = CookieExtractors.Query(key: key, names: names, domain: domain)
        // Detached for the same reason the launch sweep is: this copies each
        // browser's cookie database, which is not work for the main thread.
        let found = await Task.detached(priority: .utility) {
            CookieExtractors.searchAll([query], allowingKeychainPrompt: allowingKeychainPrompt)
        }.value[key] ?? []
        // Only worth a second pass over the databases when nothing readable came
        // back — a locked count beside a session we can already read tells the
        // user nothing they can act on.
        let locked: Int
        if found.isEmpty {
            locked = await Task.detached(priority: .utility) {
                CookieExtractors.lockedSessionCounts([query])
            }.value[key] ?? 0
        } else {
            locked = 0
        }

        values.removeAll()
        claimedAway.removeAll()
        var candidates: [Candidate] = []
        for cookie in found {
            let candidate = Candidate(
                browser: cookie.source,
                profile: cookie.profile,
                label: cookie.origin,
                claimedBy: claimant(of: cookie.value)
            )
            values[candidate.id] = cookie.value
            if candidate.isClaimedElsewhere { claimedAway.append(candidate) }
            candidates.append(candidate)
        }
        return Sweep(candidates: candidates, locked: locked)
    }

    /// Which other account of this service already holds this session.
    ///
    /// Only browser-derived credentials are compared. Those live in memory, so
    /// reading them cannot raise a Keychain dialog — which a sweep that is
    /// merely labelling candidates has no business doing.
    private func claimant(of value: String) -> String? {
        let siblings = SessionStore.shared.allCredentials().filter { credential in
            credential.source == .browserCookie
                && credential.providerID != provider.id
                && (credential.providerID == provider.serviceID
                    || credential.providerID.hasPrefix(provider.serviceID + "#"))
        }
        return siblings.first { SessionStore.shared.token(for: $0.providerID) == value }?.providerID
    }

    private func ignoreExistingSessions() {
        ignoredValues = Set(values.values)
    }

    /// What an allowed prompt actually came back with. Still locked and still
    /// nothing readable means the dialog was dismissed.
    private func recordKeychainOutcome(_ sweep: Sweep) {
        keychainRefused = sweep.candidates.isEmpty && sweep.locked > 0
        // Nothing retries a refusal on a timer; the dialog would otherwise come
        // back on every poll tick.
        if keychainRefused { mayPromptKeychain = false }
    }

    /// The user pressed something, so a Keychain dialog is expected here.
    ///
    /// A refusal is cached for the life of the process, so it has to be dropped
    /// first — without this, Unlock worked once and Check now never asked again
    /// at all. Only the failed keys go: re-deriving the ones that worked is a
    /// dialog per browser per press.
    private func allowKeychainPrompt() {
        mayPromptKeychain = true
        CookieExtractors.retryLockedKeys()
    }

    // MARK: - Watching

    private func watch(for candidate: Candidate?) {
        watchTask?.cancel()
        stage = .watching(candidate)
        watchTask = Task { [weak self] in
            for _ in 0..<Self.watchAttempts {
                guard let self, !Task.isCancelled else { return }
                if await self.pollOnce(matching: candidate) { return }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: Self.watchInterval)
            }
            // A cancel landing in the final sleep falls straight out of the loop,
            // and "no new session appeared in ten minutes" is not what happened
            // to a window the user closed.
            guard !Task.isCancelled else { return }
            self?.stage = .timedOut
        }
    }

    /// One poll. Returns true when the watch is over, either because a session
    /// arrived or because one arrived that we are not allowed to read.
    private func pollOnce(matching target: Candidate?) async -> Bool {
        let sweep = await self.sweep(allowingKeychainPrompt: mayPromptKeychain)
        let arrivals = acceptable(from: sweep.candidates, matching: target)
        if arrivals.count > 1 {
            // Two profiles logged in while we were watching. Which of them this
            // account is, is still not ours to decide.
            stage = .choosing(arrivals)
            return true
        }
        if let only = arrivals.first {
            await adopt(only)
            return true
        }
        if sweep.locked > 0 {
            // A session did appear; it is simply not legible. Running the clock
            // down watching for a readable one would be a lie.
            stage = .locked(Locked(count: sweep.locked, keychainRefused: keychainRefused))
            return true
        }
        return false
    }

    /// The sessions a watch would take: offerable, not one that was already in
    /// the browser when the watch started, and the watched profile itself when
    /// the user named one.
    ///
    /// A list rather than the first match, because "first" is the whole bug:
    /// with two readable sessions in front of it, anything that picks one has
    /// picked the account, and that is the user's to pick.
    private func acceptable(from found: [Candidate], matching target: Candidate?) -> [Candidate] {
        offerable(from: found).filter { candidate in
            guard let value = values[candidate.id], !ignoredValues.contains(value) else { return false }
            guard let target else { return true }
            return candidate.id == target.id
        }
    }

    /// One look, because the user pressed a button. This is where a Keychain
    /// prompt is allowed: they asked.
    private func checkNow() async {
        allowKeychainPrompt()
        let resume = stage
        let target: Candidate?
        if case .watching(let watched) = resume { target = watched } else { target = nil }

        stage = .checkingBrowser
        let sweep = await self.sweep(allowingKeychainPrompt: true)
        guard !Task.isCancelled else { return }
        recordKeychainOutcome(sweep)

        let arrivals = acceptable(from: sweep.candidates, matching: target)
        if arrivals.count > 1 {
            stage = .choosing(arrivals)
            return
        }
        if let only = arrivals.first {
            await adopt(only)
            return
        }
        if sweep.locked > 0 {
            stage = .locked(Locked(count: sweep.locked, keychainRefused: keychainRefused))
            return
        }
        // Nothing new. Carry on doing whatever we were doing — and in particular
        // do not restart the poll, whose whole point is that it ends.
        stage = resume
    }

    /// Asks the Keychain for this one service, because the user pressed Unlock.
    private func unlock() async {
        allowKeychainPrompt()
        stage = .checkingBrowser
        let sweep = await self.sweep(allowingKeychainPrompt: true)
        guard !Task.isCancelled else { return }
        recordKeychainOutcome(sweep)
        await triage(sweep)
    }

    // MARK: - Connecting

    private func adopt(_ candidate: Candidate) async {
        guard let value = values[candidate.id] else {
            stage = .failed(message: "That session went away before aibars could read it.")
            return
        }
        stopWatching()
        stage = .captured(origin: candidate.label)
        await save(value, source: .browserCookie, origin: candidate.label)
    }

    /// Saves what the user typed. Handles the endpoint field for the one provider
    /// that needs to be told where to look.
    public func submitToken() async {
        let token = pastedToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else { return }
        // Read off the method rather than the stage: a first attempt that failed
        // validation leaves the stage at `.failed`, and the endpoint would then
        // never be configured on the second try.
        if needsEndpoint {
            let trimmed = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, URL(string: trimmed) != nil else {
                stage = .failed(message: "Enter a valid usage endpoint URL.")
                return
            }
            provider.configure(endpoint: trimmed, planName: "API")
        }
        stopWatching()
        await save(token, source: .manualPaste, origin: nil)
    }

    private func save(_ token: String, source: SessionSource, origin: String?) async {
        do {
            try provider.saveToken(token, source: source)
        } catch {
            stage = .failed(message: error.localizedDescription)
            return
        }
        if let origin { provider.browserOrigin = origin }
        pastedToken = ""
        await verify(origin: origin)
    }

    /// The credential is stored; find out whether the service agrees.
    private func verify(origin: String?) async {
        stage = .verifying
        do {
            let data = try await provider.fetchUsage()
            stage = .connected(origin: origin ?? provider.browserOrigin, summary: summary(of: data))
        } catch let error as ProviderError where error.isAuth {
            guard !SessionStore.shared.isAccessDenied else {
                // Not a rejection: the credential saved and the Keychain then
                // refused to hand it back. Dropping it here would destroy a
                // perfectly good pasted key over a dismissed dialog.
                // Naming this window's own button rather than the panel's refresh:
                // the row's copy says "hit refresh" because that is the control it
                // has, and there is no refresh in here.
                stage = .notResponding(
                    message: "Keychain access was denied, so aibars couldn't read the sign-in it just saved. Try again to ask once more."
                )
                return
            }
            // The service rejected what we just saved, so it is not a
            // credential. Keeping it is what produced "Connected · not
            // responding" on a row that would never recover.
            discardRejected()
            // "Log in again" is advice for a session. A pasted key has no login
            // to redo — the field it came from is still on screen.
            stage = .rejected(message: method.isDiscoverable
                ? "\(provider.displayName) rejected that sign-in. Log in again and it will be picked up."
                : "\(provider.displayName) rejected that token. Check it and paste it again.")
        } catch {
            // The credential saved and only the usage call failed. Keep it — the
            // endpoint may just be temporarily unhappy — but say which it was.
            //
            // `ProviderError.blocked` lands here rather than above, and that is
            // the point of it existing: a Cloudflare interstitial, a captcha or a
            // hotel wifi splash page is a challenge, not a dead session, and
            // `isAuth` leaves it out so nothing discards a session that is
            // perfectly good. The two read differently on screen for the same
            // reason — "rejected that sign-in" tells the user to log in again,
            // which is wasted effort against a challenge that will clear itself.
            stage = .notResponding(message: error.localizedDescription)
        }
    }

    private func summary(of data: UsageData) -> String? {
        let plan = data.planName.map { PlanName.pretty($0, service: provider.displayName) }
        let parts = [data.accountLabel, plan].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// Drops a credential the service refused, without marking the account
    /// signed out: the user did not choose this, so a fresh session appearing in
    /// their browser should still be adopted.
    private func discardRejected() {
        SessionStore.shared.clear(provider.id)
        // `saveToken` flips `isAuthenticated` on a hop of its own. That hop ran
        // long ago — the fetch we just awaited was a network round trip — so
        // forcing the flag down here cannot be undone by it.
        provider.isAuthenticated = false
    }

    private func openPage() {
        guard let config else { return }
        // The user's own browser, on the provider's own page. Nothing is
        // rendered in-app: their passwords and 2FA already live over there.
        WebLoginEnvironment.openLoginPage(for: config)
    }

    // MARK: - What the dialog asks

    /// The accounts to choose between, empty unless there is a choice to make.
    public var picks: [Candidate] {
        if case .choosing(let candidates) = stage { return candidates }
        return []
    }

    /// Whether this provider needs an endpoint alongside its token.
    public var needsEndpoint: Bool {
        if case .pastedKey(_, let needsEndpoint) = method { return needsEndpoint }
        return false
    }

    /// Whether the manual-entry toggle belongs on screen.
    ///
    /// Not one of `actions`, because it opens a field rather than doing
    /// anything — but the decision is still the flow's, on the same rule as the
    /// rest: "Paste a token instead" beside a service that just connected, or
    /// beside a capture already in flight, is a control that cannot help.
    public var offersTokenField: Bool {
        guard method.isDiscoverable else { return false }
        switch stage {
        case .idle, .checkingBrowser, .captured, .verifying, .connected: return false
        default: return true
        }
    }

    public var isBusy: Bool {
        switch stage {
        case .checkingBrowser, .watching, .captured, .verifying: return true
        default: return false
        }
    }

    /// The glyph beside the headline, or nil where a spinner says it better.
    public var symbol: String? {
        switch stage {
        case .idle:             return "arrow.up.forward.app"
        case .checkingBrowser, .watching, .captured, .verifying:
            return nil
        case .choosing:         return "person.2"
        case .expired:          return "clock.arrow.circlepath"
        case .locked:           return "lock.shield"
        case .unreadable:       return "lock.shield"
        case .needsToken:       return "key"
        case .connected:        return "checkmark.circle.fill"
        case .notResponding:    return "exclamationmark.triangle.fill"
        case .rejected:         return "person.crop.circle.badge.exclamationmark"
        case .timedOut:         return "exclamationmark.arrow.circlepath"
        case .failed:           return "exclamationmark.triangle.fill"
        }
    }

    public var tone: Tone {
        switch stage {
        case .connected:
            return .ok
        case .expired, .locked, .unreadable, .needsToken, .timedOut, .notResponding:
            return .attention
        case .rejected, .failed:
            return .failure
        case .idle, .checkingBrowser, .choosing, .watching, .captured, .verifying:
            return .idle
        }
    }

    /// The line the user reads first.
    public var headline: String {
        switch stage {
        case .idle:
            // Whatever `begin()` is about to say. This is the frame before
            // `onAppear`, and the window is measured from it — an empty headline
            // here is a window that opens short and then jumps.
            switch method {
            case .session:
                return config?.hint ?? ""
            case .tokenFromPage(_, let hint), .pastedKey(let hint, _):
                return hint
            }
        case .checkingBrowser:
            return "Checking \(browser.name) for a session you already have…"
        case .choosing(let candidates):
            return "You're signed in to \(candidates.count) accounts. Which one should aibars watch?"
        case .expired(let origin):
            return "Your \(origin) session has expired."
        case .locked(let locked):
            if locked.keychainRefused {
                return locked.count == 1
                    ? "Keychain access was refused, so that session stays locked."
                    : "Keychain access was refused, so those \(locked.count) sessions stay locked."
            }
            return locked.count == 1
                ? "One session found, but reading it needs one Keychain approval."
                : "\(locked.count) sessions found, but reading them needs one Keychain approval."
        case .unreadable(let limitation):
            switch limitation {
            case .needsFullDiskAccess: return "aibars can't read \(browser.name)'s cookies yet."
            case .unsupported:         return "aibars can't read \(browser.name)'s cookies."
            }
        case .needsToken(let request):
            return request.hint
        case .watching(let target):
            if let target { return "Waiting for a session in \(target.label)…" }
            return "Waiting for you to log in to \(browser.name)…"
        case .captured(let origin):
            return "Found your session in \(origin)."
        case .verifying:
            return "Checking your usage…"
        case .connected:
            return "Connected."
        case .notResponding:
            return "Signed in, but the usage check failed."
        case .rejected(let message):
            return message
        case .timedOut:
            return "No new session appeared in ten minutes."
        case .failed(let message):
            return message
        }
    }

    /// A second line where there is one worth having.
    public var detail: String? {
        switch stage {
        case .choosing:
            guard let taken = claimedAway.first else { return nil }
            return claimedAway.count == 1
                ? "\(taken.label) is already connected to another account."
                : "\(claimedAway.count) more are already connected to other accounts."
        case .locked(let locked):
            let ask = locked.keychainRefused
                ? "Nothing will ask again on its own. Press Unlock when you're ready, or paste a token."
                : "aibars only asks the Keychain when you press this."
            // Locked and expired at once: the headline can only be one of them,
            // and the locked session is the half the user can act on — but the
            // expiry still has to be named, or the dialog reads as if it were
            // talking about somebody else's account.
            guard let knownOrigin else { return ask }
            return "Your \(knownOrigin) session has expired too. \(ask)"
        case .unreadable(let limitation):
            return limitation.explanation
        case .connected(let origin, let summary):
            let line = [origin, summary].compactMap { $0 }.joined(separator: " · ")
            return line.isEmpty ? nil : line
        case .notResponding(let message):
            return message
        case .timedOut:
            return "Paste a token instead, or check again once you've logged in."
        case .watching:
            guard let taken = claimedAway.first else { return nil }
            return "\(taken.label) is already connected to another account, so log in somewhere new."
        default:
            return nil
        }
    }

    /// The buttons this stage deserves. Cancel is not here: the dialog always
    /// offers a way out, and what it is called depends on where the flow got to.
    public var actions: [Action] {
        switch stage {
        case .idle, .checkingBrowser, .captured, .verifying, .connected:
            return []
        case .choosing:
            // The picks carry their own Connect buttons; this is the way out for
            // someone whose account is not in the list.
            return pageActions
        case .expired:
            return [.signInAgain] + pageActions
        case .locked:
            return [.unlock] + pageActions
        case .unreadable(let limitation):
            switch limitation {
            case .needsFullDiskAccess: return [.fullDiskAccess, .checkNow] + pageActions
            case .unsupported:         return pageActions
            }
        case .needsToken:
            return pageActions
        case .watching:
            return [.checkNow] + pageActions
        case .notResponding:
            return [.retryFetch]
        case .rejected:
            // `signInAgain` starts a watch, so it is only offered where a session
            // is something that can be watched for. A pasted key is retried in
            // the field, which is already on screen.
            return (method.isDiscoverable ? [.signInAgain] : []) + pageActions
        case .timedOut:
            return [.checkNow] + pageActions
        case .failed:
            return (method.isDiscoverable ? [.checkNow] : []) + pageActions
        }
    }

    /// Reopening the login page, for the methods that have one. `config` is nil
    /// exactly when there is no page, which is the same question.
    private var pageActions: [Action] {
        config == nil ? [] : [.openPageAgain]
    }

    /// What the dismiss button says. "Cancel" while something is still in
    /// flight, "Done" once there is nothing left to abandon.
    public var dismissLabel: String {
        switch stage {
        case .connected, .notResponding: return "Done"
        case .rejected, .failed, .timedOut, .locked, .unreadable: return "Close"
        default: return "Cancel"
        }
    }

    /// True once the credential is stored, whatever the service then said about
    /// it. The dialog reports this to its caller so a row refreshes.
    public var didConnect: Bool {
        switch stage {
        case .connected, .notResponding: return true
        default: return false
        }
    }
}
