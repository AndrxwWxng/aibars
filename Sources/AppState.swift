import Foundation
import AppKit
import SwiftUI
import Combine

/// Central state for the menu bar app. Owns all provider instances,
/// drives the refresh loop, and surfaces the data the dropdown renders.
@MainActor
public final class AppState: ObservableObject {
    /// Providers the user deliberately signed out of.
    ///
    /// Without this the launch sweep simply adopted the session again, so signing
    /// out lasted until the next refresh. An explicit sign-in clears the mark;
    /// automatic adoption respects it.
    nonisolated private static let signedOutKey = "aibars.signedOut"

    nonisolated public static var signedOutProviders: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: signedOutKey) ?? [])
    }

    nonisolated static func markSignedOut(_ providerID: String) {
        var ids = signedOutProviders
        ids.insert(providerID)
        UserDefaults.standard.set(Array(ids), forKey: signedOutKey)
    }

    nonisolated static func clearSignedOut(_ providerID: String) {
        var ids = signedOutProviders
        guard ids.remove(providerID) != nil else { return }
        UserDefaults.standard.set(Array(ids), forKey: signedOutKey)
    }

    /// Names the user has given accounts, keyed by provider id.
    ///
    /// Two Gemini accounts labelled "Firefox" and "Firefox · Profile 1" are
    /// technically distinguished and practically not — nobody knows which
    /// profile holds which account. Google's app HTML carries no email and its
    /// account-list endpoint refuses anything but a Chromium client, so the
    /// reliable answer is to let people write it down.
    public static func customAccountName(for providerID: String) -> String? {
        let value = UserDefaults.standard.string(forKey: "aibars.accountName.\(providerID)")
        return (value?.isEmpty ?? true) ? nil : value
    }

    public static func setCustomAccountName(_ name: String?, for providerID: String) {
        let key = "aibars.accountName.\(providerID)"
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// The app's single instance. Shared because the refresh loop is started by
    /// the app delegate at launch, while the views are built later and have to
    /// observe the same object.
    public static let shared = AppState()

    @Published public var providers: [AnyUsageProvider] = []
    @Published public var snapshots: [String: Result<UsageData, ProviderError>] = [:]
    @Published public var isRefreshing: Bool = false
    /// Which single rows have a fetch in flight, by provider id.
    ///
    /// `isRefreshing` only ever meant "refreshAll is running", so a per-row
    /// refresh had no cue at all: the row's reading was thrown away, the row
    /// shrank, and nothing said why. The reading stays now, and this is what
    /// turns that row's ⟳ into a spinner in the box it already occupies.
    @Published public var refreshingRows: Set<String> = []
    /// Sessions found but not readable, keyed by service. Chromium cookies need
    /// a keychain key the silent sweep will not ask for, so these exist and are
    /// simply locked — worth saying so rather than looking like nothing is there.
    @Published public var lockedAccounts: [String: Int] = [:]
    /// True while the launch sweep is still reading the browsers. There was no
    /// state for "we have not looked yet", so the panel stated its final answer
    /// — that nothing is connected — during the seconds it was still deciding.
    @Published public private(set) var isAdopting = false
    @Published public var lastRefresh: Date?
    @Published public var refreshIntervalSeconds: Int {
        didSet { userDefaults.set(refreshIntervalSeconds, forKey: intervalKey) }
    }

    /// Where readings go to be judged against the user's thresholds and
    /// budgets.
    ///
    /// `shared` in the app, and settable so a test can hand this state a centre
    /// with its own defaults domain and its own budget store. That is not
    /// tidiness: arming a budget against the shared one writes the amount into
    /// the developer's own preferences and leaves it there, and the budget
    /// fold is not assertable without arming one.
    ///
    /// `forgetHistory` below is the one path that still reaches
    /// `AlertCenter.shared` directly, because it is static — `signOut()` calls
    /// it from a provider, which has no state to ask. The two are the same
    /// object everywhere but a test.
    var alertCenter: AlertCenter = .shared

    private let userDefaults = UserDefaults.standard
    private let intervalKey = "aibars.refreshInterval"
    private var refreshTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?
    /// Providers the timer should leave alone until this date, and how many
    /// times in a row they have failed. Both are cleared by a success or by the
    /// user asking for a refresh.
    private var cooldownUntil: [String: Date] = [:]
    private var consecutiveFailures: [String: Int] = [:]
    /// When each provider's snapshot was actually fetched. A provider serving a
    /// backoff keeps its old snapshot, so the panel's one freshness line has to
    /// be the age of the oldest thing on screen — not the age of the sweep.
    private var fetchedAt: [String: Date] = [:]

    public init() {
        let stored = userDefaults.integer(forKey: intervalKey)
        self.refreshIntervalSeconds = stored == 0 ? 60 : stored

        self.providers = Self.services.map { $0.make(nil) }
        // Every provider is told which state holds it, so that signing out can
        // drop the reading as well as the credential. See
        // `AnyUsageProvider.owner`; `attach` does the same for the accounts it
        // discovers later.
        for provider in providers { provider.owner = self }
    }

    /// One entry per service aibars knows how to read. `make` builds an
    /// instance for a given account, so a service signed into several times
    /// becomes several providers rather than one that silently picks a winner.
    struct Service {
        let id: String
        /// Wraps at the call site, where the concrete type is still known —
        /// the type-erasing initialiser needs that.
        let make: (String?) -> AnyUsageProvider
    }

    static let services: [Service] = [
        Service(id: "claude") { AnyUsageProvider(ClaudeProvider(accountID: $0)) },
        Service(id: "chatgpt") { AnyUsageProvider(ChatGPTProvider(accountID: $0)) },
        Service(id: "gemini") { AnyUsageProvider(GoogleGeminiProvider(accountID: $0)) },
        Service(id: "grok") { AnyUsageProvider(GrokProvider(accountID: $0)) },
        Service(id: "perplexity") { AnyUsageProvider(PerplexityProvider(accountID: $0)) },
        Service(id: "deepseek") { AnyUsageProvider(DeepSeekProvider(accountID: $0)) },
        Service(id: "cursor") { AnyUsageProvider(CursorProvider(accountID: $0)) },
        Service(id: "copilot") { AnyUsageProvider(CopilotProvider(accountID: $0)) },
        Service(id: "openrouter") { AnyUsageProvider(OpenRouterProvider(accountID: $0)) },
        Service(id: "mistral") { AnyUsageProvider(MistralProvider(accountID: $0)) },
        Service(id: "minimax") { AnyUsageProvider(MiniMaxProvider(accountID: $0)) },
        // Appended rather than slotted in by importance. Declared order is the
        // sort tiebreak in `rankedProviders` and the fallback for manual order,
        // so inserting anything above the original eleven would reshuffle rows
        // that have been sitting still for existing users.
        Service(id: "codex") { AnyUsageProvider(CodexProvider(accountID: $0)) },
        Service(id: "zai") { AnyUsageProvider(ZaiProvider(accountID: $0)) },
        Service(id: "claudecode") { AnyUsageProvider(ClaudeCodeProvider(accountID: $0)) },
        Service(id: "opencode") { AnyUsageProvider(OpenCodeProvider(accountID: $0)) }
    ]

    public func start() {
        guard refreshTask == nil else { return }
        // A sleeping Mac stops the clock: `Task.sleep` counts uptime, so an
        // eight-hour lid close leaves the panel showing pre-sleep numbers until
        // the rest of the interval elapses. Wake is the trigger the loop itself
        // cannot provide.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                // A twenty-second nap should not stack a sweep on top of the one
                // already due — only act when the data is older than the user asked for.
                if let last = self.lastRefresh,
                   Date().timeIntervalSince(last) < Double(self.refreshIntervalSeconds) { return }
                // Firing immediately races the network stack coming back, which
                // would mark every provider failed for one cycle.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await self.refreshAll()
            }
        }
        refreshTask = Task { [weak self] in
            // Adopt sessions the user already has before the first fetch, so a
            // browser they're logged into shows usage without them being asked
            // to "sign in" to something they're signed into.
            self?.isAdopting = true
            await self?.adoptBrowserSessions()
            self?.isAdopting = false
            while !Task.isCancelled {
                await self?.refreshAll()
                let interval = self?.refreshIntervalSeconds ?? 60
                try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
            }
        }
    }

    public func stop() {
        // Paired with `start()` exactly: the interval picker calls stop-then-start,
        // and a token left behind would either leak an observer or skip the next
        // registration.
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
        }
        wakeObserver = nil
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// `userInitiated` is the difference between the timer coming round and the
    /// user clicking refresh. Only the latter retries a Keychain read that was
    /// refused — retrying on the timer would put the dialog back on screen every
    /// minute, which is the behaviour this app is trying not to have.
    public func refreshAll(userInitiated: Bool = false) async {
        if userInitiated, SessionStore.shared.isAccessDenied {
            SessionStore.shared.invalidateCache()
        }
        // Asking is exactly the thing a cooldown must not refuse.
        if userInitiated {
            cooldownUntil.removeAll()
            consecutiveFailures.removeAll()
        }
        isRefreshing = true
        defer { isRefreshing = false; lastRefresh = oldestSnapshotDate() }
        await withTaskGroup(of: (String, Result<UsageData, ProviderError>).self) { group in
            for provider in providers where provider.isEnabled && isDue(provider.id) {
                let id = provider.id
                group.addTask {
                    do {
                        let data = try await provider.fetchUsage()
                        return (id, .success(data))
                    } catch let e as ProviderError {
                        return (id, .failure(e))
                    } catch {
                        return (id, .failure(.network(error.localizedDescription)))
                    }
                }
            }
            for await (id, result) in group {
                // A fetch that was torn down is not a fetch that failed. The
                // catch-all above turns anything that is not a `ProviderError`
                // into `.network(...)`, and `URLError.cancelled` arrives as
                // exactly that (ProviderHTTP.swift:83-84) — so cancelling this
                // task, which `stop()` does at terminate and on every interval
                // change, used to write a failure snapshot over every provider
                // still in flight and count it toward that provider's backoff.
                //
                // `continue`, not `break`: a success that landed before the
                // cancellation is a real reading and still belongs on screen,
                // and the group has to be drained either way.
                if Task.isCancelled, case .failure = result { continue }
                snapshots[id] = clarify(result)
                fetchedAt[id] = Date()
                noteOutcome(id, result)
                await note(id, result)
                await discardRejectedCredential(id, result)
                // A key kept through a 403 had its row flag dropped; an answer
                // means it works after all, so let the row say so again.
                if case .success = result, let provider = provider(for: id), !provider.isAuthenticated {
                    await provider.syncAuthState()
                }
            }
        }
    }

    /// Hands a reading to everything that watches usage over time rather than at
    /// an instant: the sample ring the pace line is fitted to, the ninety-day
    /// history, and the two alert policies.
    ///
    /// It hangs off the one place results land, so a single-row refresh feeds
    /// them exactly as a sweep does — otherwise a user watching one service and
    /// refreshing it by hand would contribute no samples at all, and could cross
    /// a level without aibars ever seeing it happen.
    ///
    /// Nothing here can fail the poll: the trend store writes to UserDefaults,
    /// the history store swallows its own write errors by design and is simply
    /// absent when its file could not be opened, and the alert centre swallows
    /// every delivery failure.
    ///
    /// Internal rather than private so `AppStateSweepTests` can put one sweep's
    /// worth of readings through it. The fold below is only ever wrong in the
    /// presence of a second account, and there is no other way into this path
    /// that does not need a network and fifteen live credentials.
    func note(_ providerID: String, _ result: Result<UsageData, ProviderError>) async {
        guard case .success(let data) = result,
              let provider = provider(for: providerID) else { return }
        UsageTrendStore.shared.record(data, for: providerID)
        UsageHistoryStore.shared?.record(data, for: providerID)
        // The row's own twenty-four-hour trace, rebuilt at most once every five
        // minutes per row and always off the main actor. It goes here and not in
        // the view for the reason everything else in this method is here: a
        // single-row refresh has to feed it exactly as a sweep does, or a user
        // watching one service by hand would draw a trace that stopped the day
        // they started watching.
        RowSparklineStore.shared.note(data, for: providerID)
        await alertCenter.consider(
            data, providerID: providerID, displayName: provider.displayName
        )
        // Budgets are per service, not per account: two Claude subscriptions are
        // one bill to the person paying it, and an alert naming the account slot
        // would be reporting an internal id.
        //
        // Which is why the figure has to be the service's folded total and not
        // this account's share of it. `BudgetAlertState` keeps one entry per
        // service, so two accounts handing it their own halves overwrote each
        // other's remembered fraction on every sweep: a $25 bill split $10/$15
        // against a $20 budget left both halves under the line the sum had
        // walked past, and a fraction that ping-ponged between the two re-armed
        // the same crossing for as long as both accounts kept reporting.
        //
        // Both callers assign `snapshots[id]` before they arrive here (the
        // sweep's consumer loop and `refresh(_:)`), so the fold already contains
        // the reading that just landed. That is what makes calling once per
        // account harmless rather than something to dedupe: every call in one
        // sweep carries the identical total, and the second one sees
        // `previous == current` and produces no crossing.
        if let folded = spendReports.first(where: { $0.serviceID == provider.serviceID })?.report {
            await alertCenter.consider(
                spend: folded, serviceID: provider.serviceID, displayName: provider.displayName
            )
        }
    }

    /// Drops what the time-series features remember about an account.
    ///
    /// Slot numbers are reused: sign out of "claude#2" and the next session
    /// discovered for that service takes the same id. Without this it would
    /// inherit the previous account's samples — projecting a pace across two
    /// people's usage — and its armed levels, so a fresh account at 40% could
    /// fire nothing until it passed a line the old one had already crossed.
    ///
    /// The stored history is dropped for the same reason and it is the worst of
    /// the three to get wrong: a chart is read as one person's record, so ninety
    /// days of somebody else's usage under a new account's name is not a stale
    /// number, it is a fabricated one. And the trace under the row goes with it,
    /// which is the same fabrication at a smaller scale — twenty-four hours of
    /// somebody else's day drawn under a new account's name, in the one place the
    /// user is looking rather than in a settings window they may never open.
    @MainActor
    public static func forgetHistory(_ providerID: String) {
        UsageTrendStore.shared.forget(providerID)
        UsageHistoryStore.shared?.forget(providerID)
        RowSparklineStore.shared.forget(providerID)
        AlertCenter.shared.forget(providerID)
    }

    /// The age the panel should report: that of the stalest snapshot it is
    /// showing. A sweep that skipped a cooled-down provider has not made that
    /// provider's numbers any newer, and "updated just now" over half-hour-old
    /// figures is the one thing this app must not say.
    private func oldestSnapshotDate() -> Date? {
        providers
            .filter { $0.isEnabled && snapshots[$0.id] != nil }
            .compactMap { fetchedAt[$0.id] }
            .min()
    }

    /// True unless this provider is serving a backoff.
    private func isDue(_ providerID: String) -> Bool {
        guard let until = cooldownUntil[providerID] else { return true }
        return until <= Date()
    }

    /// Backs a failing provider off instead of asking again on the next tick.
    ///
    /// A 429 answered at the same cadence for hours, with the user's own session
    /// cookie, is the traffic pattern that gets an account flagged. A success
    /// clears the mark; so does the user clicking refresh.
    private func noteOutcome(_ providerID: String, _ result: Result<UsageData, ProviderError>) {
        switch result {
        case .success:
            cooldownUntil[providerID] = nil
            consecutiveFailures[providerID] = 0
        case .failure(.rateLimited):
            // Being told to slow down is worth taking literally, from the first one.
            consecutiveFailures[providerID, default: 0] += 1
            cooldownUntil[providerID] = Date().addingTimeInterval(
                max(300, Double(refreshIntervalSeconds) * 5)
            )
        case .failure(.sessionExpired), .failure(.notAuthenticated):
            // Already handled: the credential is dropped and the row says "Not
            // connected", so there is nothing left to back off from.
            cooldownUntil[providerID] = nil
            consecutiveFailures[providerID] = 0
        case .failure:
            // The first couple are usually a blip. After that, double the wait
            // each time up to half an hour.
            let count = consecutiveFailures[providerID, default: 0] + 1
            consecutiveFailures[providerID] = count
            if count >= 3 {
                let delay = min(1800, Double(refreshIntervalSeconds) * pow(2, Double(count - 2)))
                cooldownUntil[providerID] = Date().addingTimeInterval(delay)
            }
        }
    }

    /// A credential the service has rejected is not a credential.
    ///
    /// An expired session left `isAuthenticated` true because a token still
    /// existed, so the row read "Connected · not responding" — which invites
    /// waiting for it to recover. It never will. Dropping the token turns those
    /// rows into "Not connected" with a Sign in button, and lets an extra
    /// account whose session has died be pruned instead of sitting there
    /// failing forever.
    ///
    /// The sign-out mark is deliberately not set: the session expired on its
    /// own, so a fresh one appearing in the browser should still be adopted.
    ///
    /// Only a browser cookie is thrown away, because only a browser cookie can be
    /// re-derived. `sessionExpired` covers every 401 and 403, so a Cloudflare
    /// challenge or a captive portal after a wake looks exactly like an expiry —
    /// and deleting a pasted key over one of those loses something the user
    /// cannot get back by relaunching.
    private func discardRejectedCredential(
        _ providerID: String,
        _ result: Result<UsageData, ProviderError>
    ) async {
        guard case .failure(let error) = result,
              case .sessionExpired = error,
              let provider = provider(for: providerID)
        else { return }
        guard SessionStore.shared.credential(for: providerID)?.source == .browserCookie else {
            // Drop the connected flag so the row stops claiming it works, but
            // keep the key: a recovered endpoint starts working on the next tick.
            provider.isAuthenticated = false
            return
        }
        SessionStore.shared.clear(providerID)
        Self.forgetHistory(providerID)
        await provider.syncAuthState()
        provider.isAuthenticated = false
        pruneEmptyAccounts()
    }

    /// A provider whose token couldn't be read out of the Keychain throws
    /// `notAuthenticated`, which renders as "Not signed in. Open Settings to
    /// authenticate." — advice that cannot work, for a user who is signed in.
    /// Name the real cause instead.
    private func clarify(_ result: Result<UsageData, ProviderError>) -> Result<UsageData, ProviderError> {
        guard case .failure(let error) = result,
              case .notAuthenticated = error,
              SessionStore.shared.isAccessDenied
        else { return result }
        return .failure(.configuration(
            "aibars couldn't read your saved sign-in — Keychain access was denied. Hit refresh to ask again."
        ))
    }

    /// Connects any provider whose session is already sitting in one of the
    /// user's browsers.
    ///
    /// Being logged into claude.ai in your browser and being asked by aibars to
    /// "sign in" is the same thing twice. One sweep resolves every disconnected
    /// provider at once — per-provider lookups would copy each browser's cookie
    /// database once per provider.
    ///
    /// `allowingKeychainPrompt` should only be true when the user asked for
    /// this. The launch sweep runs silently: a keychain dialog appearing on its
    /// own, before the user has touched anything, is alarming — and it blocks
    /// the sweep until they answer.
    ///
    /// Returns the providers it connected.
    @discardableResult
    public func adoptBrowserSessions(allowingKeychainPrompt: Bool = false) async -> [String] {
        // One query per service, not per provider: several providers can share
        // a service once its accounts have been discovered.
        //
        // A service whose template has no `webLogin`, or a `webLogin` with no
        // cookie domain, contributes no query and so costs the sweep nothing.
        // That was incidental and is now load-bearing: Claude Code and OpenCode
        // are read off this Mac, have no session to adopt and nothing to log
        // into, and they must not make every launch copy the browser cookie
        // databases twice more for a lookup that could never match.
        let queries = Self.services.compactMap { service -> CookieExtractors.Query? in
            guard let template = providers.first(where: { $0.serviceID == service.id }),
                  let config = template.webLogin,
                  let domain = config.cookieDomain
            else { return nil }
            return CookieExtractors.Query(
                key: service.id,
                names: config.candidateCookieNames,
                domain: domain
            )
        }
        guard !queries.isEmpty else { return [] }

        let sessions = await Task.detached(priority: .utility) {
            // The process's one Keychain read, moved off the main actor and in
            // front of the sweep that needs it. `attach` below asks for a token
            // per discovered session while it is on the main actor, and on a
            // locally signed build that read is the one that can raise the
            // access dialog — a blocking `SecItemCopyMatching` there is a
            // frozen panel during a sweep documented as never prompting.
            // Cached and idempotent, refusals included, so every launch after
            // the first read pays a lock for this and nothing more.
            SessionStore.shared.warm()
            return CookieExtractors.searchAll(queries, allowingKeychainPrompt: allowingKeychainPrompt)
        }.value
        // Deliberately not awaited. The census is a second full copy of every
        // browser's cookie database and nothing between here and the first fetch
        // reads it, so waiting on it delayed the first number every user sees —
        // including the ones with no locked sessions to be told about.
        Task { [weak self] in
            let locked = await Task.detached(priority: .utility) {
                CookieExtractors.lockedSessionCounts(queries)
            }.value
            self?.lockedAccounts = locked
        }

        var adopted: [String] = []
        for service in Self.services {
            let found = sessions[service.id] ?? []
            guard !found.isEmpty else { continue }
            adopted.append(contentsOf: attach(found, to: service))
        }
        if !adopted.isEmpty { pruneEmptyAccounts() }
        return adopted
    }

    /// Gives every discovered session a provider of its own.
    ///
    /// The first keeps the plain service id so existing settings and stored
    /// keys carry over; the rest get "<service>#<n>". A session is matched back
    /// to the account that already holds it, or failing that to the account
    /// whose stored hint names the same browser profile, and only then falls
    /// back to the lowest free slot. Position in the discovery list is not an
    /// identity: sign out of Chrome's default profile and everything after it
    /// shifts down a place, which would hand one account's name, hidden flag and
    /// sign-out mark to another.
    private func attach(_ sessions: [BrowserCookie], to service: Service) -> [String] {
        func identity(_ slot: Int) -> (id: String, accountID: String?) {
            slot <= 1 ? (service.id, nil) : ("\(service.id)#\(slot)", String(slot))
        }
        func slot(_ provider: AnyUsageProvider) -> Int {
            provider.accountID.flatMap(Int.init) ?? 1
        }

        var hints: [String: String] = [:]
        for credential in SessionStore.shared.allCredentials() {
            if let hint = credential.accountHint { hints[credential.providerID] = hint }
        }
        let siblings = providers.filter { $0.serviceID == service.id }

        var slots: [Int?] = Array(repeating: nil, count: sessions.count)
        var claimed: Set<Int> = []
        // Two rules, strongest first: the session an account already holds
        // identifies it wherever it turned up this time, and the stored profile
        // hint takes over across launches, once the browser-derived token is gone.
        // Both run before anything is handed out positionally, or a new session
        // takes the slot of an account one of them would have recognised.
        let rules: [(AnyUsageProvider, BrowserCookie) -> Bool] = [
            { provider, cookie in
                // Only browser-derived credentials are compared — and no longer
                // because of what reading a pasted one would cost. `warm()`
                // above has already done the read, and it reads one combined
                // item covering every provider at once, so the cost is paid the
                // moment any pasted credential exists whether or not this line
                // looks at one. What survives is the comparison itself: a
                // pasted key is not a browser cookie, and matching one against
                // a cookie value would hand a session to the wrong account.
                SessionStore.shared.credential(for: provider.id)?.source == .browserCookie
                    && SessionStore.shared.token(for: provider.id) == cookie.value
            },
            { provider, cookie in hints[provider.id] == cookie.origin }
        ]
        for rule in rules {
            for (index, cookie) in sessions.enumerated() where slots[index] == nil {
                guard let match = siblings.first(where: {
                    !claimed.contains(slot($0)) && rule($0, cookie)
                }) else { continue }
                slots[index] = slot(match)
                claimed.insert(slot(match))
            }
        }
        var next = 1
        for index in sessions.indices where slots[index] == nil {
            while claimed.contains(next) { next += 1 }
            slots[index] = next
            claimed.insert(next)
        }

        var adopted: [String] = []
        for (index, cookie) in sessions.enumerated() {
            guard let slot = slots[index] else { continue }
            let (id, accountID) = identity(slot)

            // A deliberate sign-out outranks a session sitting in a browser.
            if Self.signedOutProviders.contains(id) { continue }

            let provider = providers.first { $0.id == id } ?? {
                let created = service.make(accountID)
                created.owner = self
                providers.append(created)
                return created
            }()

            // Nothing to do if this provider already holds this exact session.
            guard SessionStore.shared.token(for: id) != cookie.value else {
                rememberOrigin(cookie.origin, for: id)
                continue
            }
            do {
                try provider.adoptBrowserSession(cookie.value)
                provider.browserOrigin = cookie.origin
                rememberOrigin(cookie.origin, for: id)
                adopted.append(id)
            } catch {
                continue
            }
        }
        return adopted
    }

    /// Records which browser profile an account's session was last seen in, so
    /// the next launch can find it again by something other than its position.
    ///
    /// Refreshed rather than written once: `searchAll` dedupes on the value and
    /// reports whichever browser it scanned first, so an account signed into both
    /// Safari and Chrome changes origin when one of them signs out.
    private func rememberOrigin(_ origin: String, for providerID: String) {
        guard let credential = SessionStore.shared.credential(for: providerID),
              credential.source == .browserCookie,
              credential.accountHint != origin,
              let token = SessionStore.shared.token(for: providerID)
        else { return }
        try? SessionStore.shared.setToken(
            token, for: providerID, source: .browserCookie, accountHint: origin
        )
    }

    /// Drops extra accounts that no longer have a session, so signing out of a
    /// browser profile removes its row rather than leaving a dead one.
    private func pruneEmptyAccounts() {
        let dropped = providers.filter { provider in
            provider.accountID != nil && SessionStore.shared.token(for: provider.id) == nil
        }
        guard !dropped.isEmpty else { return }
        let ids = Set(dropped.map(\.id))
        providers.removeAll { ids.contains($0.id) }
        // The row is gone, so the samples and armed levels behind it belong to
        // nobody — and the id is about to be handed to whichever session turns
        // up next.
        for id in ids {
            forgetSnapshot(of: id)
            Self.forgetHistory(id)
        }
    }

    /// Drops the reading a row is drawn from, leaving the credential alone.
    ///
    /// Two callers, one reason each. Pruning reuses slot numbers, so a snapshot
    /// left behind under `claude#2` is the previous account's figure drawn
    /// under the next account's name. Signing out leaves the row on screen and
    /// only unauthenticated, and `ProviderRow` reserves its detail box for any
    /// row that is authenticated *or* holds a result — so a snapshot outliving
    /// the credential freezes the last sentence the row said, usually "Session
    /// expired", under a row the user disconnected on purpose.
    ///
    /// `fetchedAt` goes with it. The stamp is documented as when this
    /// provider's snapshot was fetched, and a stamp for a snapshot that no
    /// longer exists is that sentence being false.
    func forgetSnapshot(of providerID: String) {
        snapshots.removeValue(forKey: providerID)
        fetchedAt.removeValue(forKey: providerID)
    }

    /// How many times in a row a provider has failed, for the test that a
    /// cancelled fetch is not one of them. The dictionary stays private:
    /// nothing outside this file has any business writing a backoff.
    func consecutiveFailureCount(for providerID: String) -> Int {
        consecutiveFailures[providerID, default: 0]
    }

    /// Refreshes a single provider, for the per-row refresh button and for the
    /// moment right after a successful sign-in.
    public func refresh(_ providerID: String) async {
        guard let provider = provider(for: providerID) else { return }
        // The reading this row already has stands until a new one lands.
        //
        // This line used to be `snapshots.removeValue(forKey: providerID)`, and
        // it was the resize the user was seeing: click ⟳, and the row dropped
        // from 66pt to 38pt while a fetch ran on a 15-second timeout, taking
        // 28pt of `MenuBarExtra` window with it, under the pointer, with nothing
        // anywhere saying a fetch was in flight. A refresh never discards what
        // it has — the row keeps its figure, its meter and its height, and the
        // in-flight cue is the row's own refresh glyph becoming a spinner in the
        // 18pt box it already occupies.
        refreshingRows.insert(providerID)
        defer {
            refreshingRows.remove(providerID)
            // Stamped on every outcome, exactly as the sweep stamps its own,
            // and for the same reason: `refresh(_:)` overwrites the snapshot on
            // both catch branches below, so a row that fails by hand is in the
            // same state as a row that fails on the timer, and reporting the
            // age of a reading it no longer holds is the one thing the
            // freshness line must not do. Both quantities move together because
            // `lastRefresh` is derived from the stamps and nothing else — the
            // minimum over every row, so this one getting newer only moves the
            // line when this row was the stalest thing on screen.
            fetchedAt[providerID] = Date()
            lastRefresh = oldestSnapshotDate()
        }
        // The user asked for this one by name, so any backoff it was serving goes.
        cooldownUntil[providerID] = nil
        consecutiveFailures[providerID] = 0
        if SessionStore.shared.isAccessDenied {
            // A per-row refresh is a user action, so retry the Keychain.
            SessionStore.shared.invalidateCache()
        }
        do {
            let result = Result<UsageData, ProviderError>.success(try await provider.fetchUsage())
            snapshots[providerID] = result
            await note(providerID, result)
        } catch let error as ProviderError {
            snapshots[providerID] = clarify(.failure(error))
        } catch {
            snapshots[providerID] = clarify(.failure(.network(error.localizedDescription)))
        }
    }

    public func provider(for id: String) -> AnyUsageProvider? {
        providers.first { $0.id == id }
    }

    /// Primary usage fraction for every enabled provider that reported
    /// successfully. Drives the menu bar meter.
    public var usageLevels: [Double] {
        providers
            .filter(\.isEnabled)
            .compactMap { provider in
                guard let snapshot = snapshots[provider.id],
                      let data = try? snapshot.get(),
                      // Status-only metrics (Copilot reports "active", not a
                      // quota) carry no usage and would otherwise read as 100%.
                      data.primary.limit > 0 else { return nil }
                return data.primary.percent
            }
    }

    /// Highest primary % across enabled, authenticated providers. Drives the
    /// menu bar badge.
    public var topUsagePercent: Double {
        usageLevels.max() ?? 0
    }

    /// Average of primary % across enabled providers. Used for icon color.
    public var averageUsagePercent: Double {
        let values = usageLevels
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }

    /// What each service has reported, for the menu bar strip to draw a mark and
    /// a figure against.
    ///
    /// `nil` percent means the service publishes no quota — ChatGPT reports a
    /// subscription and Copilot reports a seat, and neither is a fraction of
    /// anything. They must never be handed a number: an invented 0 reads as
    /// plenty left and an invented 100 reads as capped, and both are claims the
    /// provider did not make.
    ///
    /// A provider that has not answered yet is left out rather than given that
    /// same `nil`, because the strip draws `nil` as a dash and "reports no
    /// quota" is a different statement from "has not answered". An empty list is
    /// what the renderer's own fallback is for, and it is the honest first
    /// second of a launch.
    ///
    /// One entry per account, not per service: two Claude subscriptions arrive
    /// as two entries. Which of them the strip keeps, in what order, and how
    /// many fit are all `MenuBarStripContent`'s — it is pure and it is the part
    /// that has to be assertable without a menu bar to look at.
    public var serviceReadings: [(serviceID: String, displayName: String, percent: Double?)] {
        providers
            .filter(\.isEnabled)
            .compactMap { provider in
                guard let snapshot = snapshots[provider.id],
                      let data = try? snapshot.get() else { return nil }
                let percent: Double? = data.primary.limit > 0 ? data.primary.percent : nil
                return (
                    serviceID: provider.serviceID,
                    displayName: provider.displayName,
                    percent: percent
                )
            }
    }

    /// What each service says it has cost, one figure per service, in the order
    /// the services were declared.
    ///
    /// Folded per service rather than per account because that is the unit a
    /// budget is set in: two subscriptions to one service are one bill to the
    /// person paying it. Only services that actually reported a figure appear —
    /// most publish usage and not spend, and a row of zero would claim a month
    /// had cost nothing.
    public var spendReports: [(serviceID: String, report: SpendReport)] {
        var order: [String] = []
        var byService: [String: [SpendReport]] = [:]

        for provider in providers where provider.isEnabled {
            guard let snapshot = snapshots[provider.id],
                  let data = try? snapshot.get(),
                  let spend = data.spend else { continue }
            if byService[provider.serviceID] == nil { order.append(provider.serviceID) }
            byService[provider.serviceID, default: []].append(spend)
        }

        return order.compactMap { service in
            guard let folded = Self.fold(byService[service] ?? []) else { return nil }
            return (serviceID: service, report: folded)
        }
    }

    /// Several accounts of one service, added into the single figure a budget is
    /// measured against.
    ///
    /// Only what can honestly be added. `BudgetPolicy.total` refuses to cross
    /// currencies because there is no exchange rate in this app and there is not
    /// going to be one, and a month's spend added to a lifetime total is the
    /// same kind of fiction — so the first account's currency and period decide
    /// what joins the sum, and anything else is left out rather than folded in
    /// wrong. One report passes through untouched, which is every case but the
    /// rare one.
    private static func fold(_ reports: [SpendReport]) -> SpendReport? {
        guard let first = reports.first else { return nil }
        guard reports.count > 1 else { return first }

        let joined = reports.filter {
            $0.period == first.period && $0.currency == first.currency
        }
        let (minor, _) = BudgetPolicy.total(joined, currency: first.currency)

        return SpendReport(
            amountMinor: minor,
            currency: first.currency,
            // The scale the total was carried at: `BudgetPolicy` restates
            // everything at the coarsest exponent present, and reading the sum
            // back at a finer one would be off by orders of magnitude.
            exponent: joined.map(\.exponent).min() ?? first.exponent,
            // Deliberately dropped. Adding two accounts' ceilings together
            // invents headroom the service never offered, and one account with
            // no ceiling makes the sum uncapped anyway — the budget the user set
            // is the ceiling that means anything here.
            limitMinor: nil,
            period: first.period,
            // One estimate in the sum makes the sum an estimate. A total that
            // presented itself as measured because most of it was would be the
            // one thing `SpendReport.Confidence` exists to prevent.
            confidence: joined.allSatisfy { $0.confidence == .measured } ? .measured : .estimated,
            // The soonest rollover: the first of these periods to end is the
            // point the total stops being current.
            resetDate: joined.compactMap(\.resetDate).min()
        )
    }

    /// How many accounts exist for a service, for the settings UI to mention.
    public func accountCount(ofService serviceID: String) -> Int {
        providers.filter { $0.serviceID == serviceID }.count
    }

    /// Enabled providers in the order the dropdown should show them: the ones
    /// reporting real usage first and busiest-first within that, then status-only
    /// rows, then anything still loading or erroring, then the disconnected ones.
    /// Sorting by urgency means the row you need is always at the top.
    public var rankedProviders: [AnyUsageProvider] {
        providers
            .filter(\.isEnabled)
            .enumerated()
            .sorted { lhs, rhs in
                let a = rank(lhs.element), b = rank(rhs.element)
                if a.group != b.group { return a.group < b.group }
                if a.percent != b.percent { return a.percent > b.percent }
                // Declared order is the tiebreak, so rows don't shuffle
                // between refreshes.
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func rank(_ provider: AnyUsageProvider) -> (group: Int, percent: Double) {
        guard provider.isAuthenticated else { return (3, 0) }
        guard let snapshot = snapshots[provider.id] else { return (2, 0) }
        switch snapshot {
        case .success(let data):
            return data.primary.limit > 0 ? (0, data.primary.percent) : (1, 0)
        case .failure:
            return (2, 0)
        }
    }

    /// One line for the dropdown header — what the user would want to know
    /// without reading the whole list.
    ///
    /// "No quotas reported" was technically true and completely unhelpful: it
    /// showed while every connected provider was failing, and said nothing about
    /// why. The failure count is the useful part, and a Keychain refusal gets
    /// named outright because nothing else in the UI would explain it.
    public var headlineSummary: String {
        let enabled = providers.filter(\.isEnabled)
        let connected = enabled.filter(\.isAuthenticated)

        // Said while the launch sweep is still reading the browsers, because
        // every line below it is a verdict and there is nothing to have a
        // verdict about yet.
        if isAdopting { return "Looking for sessions in your browsers…" }

        guard !connected.isEmpty else {
            // A Chromium session aibars can see but not read is the difference
            // between an app that found nothing and an app that needs one
            // keychain prompt. Saying "No services connected yet" over a
            // browser full of sessions reads as an app that does not work.
            let locked = lockedAccounts.values.reduce(0, +)
            guard locked > 0 else { return "No services connected yet" }
            let noun = locked == 1 ? "session" : "sessions"
            return "\(locked) \(noun) found but locked — unlock a browser in Settings"
        }

        if SessionStore.shared.isAccessDenied {
            return "Keychain access denied — click to retry"
        }

        let failures = connected.filter { provider in
            if case .failure = snapshots[provider.id] { return true }
            return false
        }.count
        let pending = connected.filter { snapshots[$0.id] == nil }.count

        if let name = topProviderName, let top = usageLevels.max() {
            let percent = Int((top * 100).rounded())
            var lead = top >= 0.85
                ? "\(name) is nearly capped — \(percent)%"
                : "\(name) highest at \(percent)%"
            // The percentage says where the busiest service is; the pace says
            // whether that matters. This is the header's only prose slot, so the
            // short form goes here and the line stays one line when the samples
            // cannot support one.
            if let pace = topProviderPace { lead += ", \(pace)" }
            return failures > 0 ? "\(lead) · \(failures) failing" : lead
        }

        if pending > 0 { return "\(connected.count) connected · checking…" }
        if failures > 0 {
            return failures == connected.count
                ? "\(failures) connected but not responding"
                : "\(connected.count) connected · \(failures) failing"
        }
        return "\(connected.count) connected · no quota to report"
    }

    /// Display name of the provider currently closest to its cap.
    public var topProviderName: String? {
        topProvider?.displayName
    }

    /// Where that provider's pace is heading, in the header's short form —
    /// "caps in 40m". Nil whenever the samples cannot support a claim, which is
    /// most of the time and is the point: an absent forecast leaves the headline
    /// exactly as it was.
    public var topProviderPace: String? {
        // The same switch that hides the pace line on the rows. It reads as a
        // setting about the pace, not about one place the pace is drawn, and a
        // user who turned it off should not still be hearing it from the header
        // or from VoiceOver reading the header out.
        guard UsageTrendStore.shared.showsPaceInPanel else { return nil }
        guard let provider = topProvider,
              let projection = UsageTrendStore.shared.projection(for: provider.id)
        else { return nil }
        return UsageForecast.shortPhrase(for: projection, now: Date())
    }

    /// The enabled provider currently closest to its cap. Kept whole rather than
    /// reduced to a name, because the forecast is keyed by account id and two
    /// accounts of one service share a display name.
    private var topProvider: AnyUsageProvider? {
        providers
            .filter(\.isEnabled)
            .compactMap { provider -> (provider: AnyUsageProvider, percent: Double)? in
                guard let snapshot = snapshots[provider.id],
                      let data = try? snapshot.get(),
                      data.primary.limit > 0 else { return nil }
                return (provider, data.primary.percent)
            }
            .sorted { $0.percent > $1.percent }
            .first?
            .provider
    }
}

/// Type-erased wrapper so AppState can hold heterogeneous providers.
public final class AnyUsageProvider: ObservableObject, Identifiable {
    public let id: String
    /// The service family — what the logo and the name come from. Several
    /// accounts of one service share it while their `id`s differ.
    public let serviceID: String
    public let accountID: String?
    public let displayName: String
    public let iconName: String

    /// The brand colour, for `ColorRamp.provider` and nothing else.
    ///
    /// Computed rather than captured, and computed from the same table the mark
    /// is drawn from: it used to be copied off the wrapped provider, which
    /// copied it from one of sixteen hand-written literals that disagreed with
    /// the marks by up to 98° of hue. One source of truth, pre-banded to be
    /// legible as a figure.
    public var accentColor: Color {
        BrandMark.mark(for: serviceID)?.brandInk ?? .accentColor
    }

    public let webLogin: WebLoginConfig?
    public let dashboardURL: URL?

    /// The state holding this provider, so signing out can drop the reading as
    /// well as the credential.
    ///
    /// A back-reference rather than a parameter because `signOut()` is called
    /// on a provider and not on a state — the settings pane has the row, not
    /// the list — and weak because `AppState.providers` is what owns these, so
    /// a strong link here would be one retain cycle per row.
    weak var owner: AppState?

    @Published public var isEnabled: Bool
    @Published public var isAuthenticated: Bool
    /// "Chrome · Profile 2" — which browser and profile this account's session
    /// came from. The only thing distinguishing two accounts before either has
    /// reported who it is.
    @Published public var browserOrigin: String?

    private let _fetch: () async throws -> UsageData
    private let _authenticate: () async throws -> Void
    private let _signOut: () async throws -> Void
    private let _setEnabled: (Bool) -> Void
    private let _saveToken: (String, SessionSource) throws -> Void
    private let _readAuthState: () -> Bool
    /// Only set for providers that need a user-supplied endpoint as well as a
    /// token (the generic JSON provider).
    private let _configure: ((String, String) -> Void)?
    private let _readEndpoint: (() -> String?)?

    public init<P: UsageProvider>(_ provider: P) where P: ObservableObject {
        self.id = provider.id
        self.serviceID = provider.serviceID
        self.accountID = provider.accountID
        self.displayName = provider.displayName
        self.iconName = provider.iconName
        self.webLogin = provider.webLogin
        self.dashboardURL = provider.dashboardURL
        self.isEnabled = provider.isEnabled
        self.isAuthenticated = provider.isAuthenticated
        self.browserOrigin = nil
        self._fetch = { try await provider.fetchUsage() }
        self._authenticate = { try await provider.authenticate() }
        self._signOut = { try await provider.signOut() }
        self._setEnabled = { [weak provider] in provider?.setEnabled($0) }
        self._readAuthState = { [weak provider] in provider?.isAuthenticated ?? false }
        if let generic = provider as? MiniMaxProvider {
            self._configure = { [weak generic] endpoint, plan in
                generic?.configure(endpoint: endpoint, planName: plan)
            }
            self._readEndpoint = { [weak generic] in generic?.configuredEndpoint }
        } else {
            self._configure = nil
            self._readEndpoint = nil
        }
        // Dispatched through the protocol rather than a switch on the id
        // string, which stopped working the moment an id could be "claude#2".
        self._saveToken = { [weak provider] token, source in
            guard let provider else { throw ProviderError.unsupported }
            try provider.saveTokenManually(token, source: source)
        }
    }

    public func fetchUsage() async throws -> UsageData {
        try await _fetch()
    }

    public func authenticate() async throws {
        try await _authenticate()
        await syncAuthState()
    }

    public func signOut() async throws {
        // Only aibars' own copy of the credential is dropped. The session lives
        // in the user's browser and is theirs — clearing it would silently log
        // them out of the website itself. The mark is what stops the next sweep
        // from adopting that very session straight back.
        AppState.markSignedOut(id)
        try await _signOut()
        await syncAuthState()
        // The account is gone even though the row may not be: a sign-in later
        // starts from no samples and no armed levels rather than picking up
        // whatever this one left behind.
        await AppState.forgetHistory(id)
        // The reading goes with the credential. `ProviderRow` reserves its
        // detail box for a row that is authenticated *or* holds a result, so a
        // snapshot left here keeps a disconnected row at its full height with
        // the last sentence it managed to say still in it — and that row now
        // offers "Sign in" under a figure from the session the user just ended.
        await owner?.forgetSnapshot(of: id)
    }

    public func setEnabled(_ enabled: Bool) {
        _setEnabled(enabled)
        isEnabled = enabled
    }

    public func saveTokenManually(_ token: String) throws {
        try saveToken(token, source: .manualPaste)
    }

    /// A session lifted out of the user's browser. Recorded as such so the store
    /// keeps it in memory instead of the Keychain — it is re-derived at every
    /// launch, so persisting it only buys an access-control dialog.
    public func adoptBrowserSession(_ token: String) throws {
        try saveToken(token, source: .browserCookie)
    }

    public func saveToken(_ token: String, source: SessionSource) throws {
        // Signing in is the user changing their mind, so the sign-out mark goes.
        // `adoptBrowserSession` filters marked providers out before reaching
        // here, so automatic adoption cannot clear it by accident.
        AppState.clearSignedOut(id)
        try _saveToken(token, source)
        // The save succeeded, so the credential exists regardless of when the
        // underlying provider gets around to flipping its own flag.
        Task { @MainActor in self.isAuthenticated = true }
    }

    /// True when the provider needs a usage endpoint configured alongside its
    /// token, rather than having one baked in.
    public var needsEndpointConfiguration: Bool { _configure != nil }

    public var configuredEndpoint: String? { _readEndpoint?() }

    public func configure(endpoint: String, planName: String) {
        _configure?(endpoint, planName)
    }

    /// The wrapper holds a snapshot of the underlying provider's auth flag, so
    /// it has to be pulled forward whenever the credential changes — otherwise
    /// rows keep showing "Sign in" after a successful login.
    @MainActor
    public func syncAuthState() async {
        isAuthenticated = _readAuthState()
    }
}
