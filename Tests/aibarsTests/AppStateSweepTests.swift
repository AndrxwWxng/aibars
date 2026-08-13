import XCTest
import Combine
@testable import aibarsCore

/// What a sweep does to state, as opposed to what it fetches.
///
/// Four properties, all of which the app got wrong in ways nothing on screen
/// could explain: a bill split across two accounts alerted against neither
/// half, cancelling a sweep marked every provider in flight as failing, a
/// per-row refresh moved the reading without moving its age, and fifteen
/// concurrent fetches each asked the Keychain for the same item.
///
/// None of them are reachable through `refreshAll` with the real providers —
/// that path wants fifteen live credentials and a network to fail against — so
/// the readings come from `StubProvider` below and the sweep's own interleaving
/// is modelled by `sweep(_:_:)`.
final class AppStateSweepTests: XCTestCase {
    override func tearDown() async throws {
        // `note` feeds the trend store and the history database, and both of
        // those are process-wide and belong to whoever is running the suite.
        // The app's own forget path is what puts them back.
        for id in ["claude", "claude#2", "slow", "stubborn", "solo"] {
            await AppState.forgetHistory(id)
        }
        try await super.tearDown()
    }

    // MARK: - Budgets

    /// A budget is one line per service, so two accounts of that service have
    /// to be measured against the sum. Handing the policy each account's own
    /// half instead let them overwrite each other's remembered fraction: see
    /// `testNeitherAccountsOwnFigureCrossesTheLineTheirBillWalkedPast` for what
    /// that costs.
    ///
    /// Three sweeps: one to seed, one that crosses, one that repeats the same
    /// readings. Exactly one alert in total, and it carries $25.00 — the folded
    /// figure, which is also the figure the Budget pane shows.
    @MainActor
    func testTwoAccountsOfOneServiceCrossTheBudgetOnceCarryingTheFoldedTotal() async throws {
        let centre = try makeCentre(budget: Budget(
            amountMinor: 2_000, currency: "USD", alertsAt: [0.80, 1.0]
        ))
        let state = AppState()
        state.alertCenter = centre
        state.providers = [
            AnyUsageProvider(StubProvider(id: "claude", serviceID: "claude", displayName: "Claude")),
            AnyUsageProvider(StubProvider(
                id: "claude#2", serviceID: "claude", accountID: "2", displayName: "Claude"
            ))
        ]

        // $2 + $3 of a $20 budget. Under the line, and the first observation
        // seeds rather than fires however far past the line it is.
        await sweep(state, [("claude", 200), ("claude#2", 300)])
        XCTAssertTrue(centre.recent.isEmpty, "the first sweep a service is seen must only seed")

        // $10 + $15 = $25, which is 125% of the budget. Neither half crosses
        // 80% on its own; the bill does.
        await sweep(state, [("claude", 1_000), ("claude#2", 1_500)])
        XCTAssertEqual(
            centre.recent.count, 1,
            "one bill crossed one line, so one alert — got \(centre.recent.map(\.title))"
        )
        let alert = try XCTUnwrap(centre.recent.first)
        XCTAssertEqual(alert.providerID, "claude", "a budget alert names the service, not the slot")
        XCTAssertTrue(
            alert.body.contains("25"),
            "the alert carried an account's share rather than the bill: \(alert.body)"
        )
        XCTAssertTrue(
            alert.title.contains("125%"),
            "the fraction is the folded total over the budget: \(alert.title)"
        )

        // The same readings again. This is the crossing that used to re-fire
        // for as long as both accounts kept reporting.
        await sweep(state, [("claude", 1_000), ("claude#2", 1_500)])
        XCTAssertEqual(centre.recent.count, 1, "a sweep that changed nothing fired again")
    }

    /// The premise, without which the test above is a test of nothing: fed each
    /// account's own figure — which is what `note` used to hand it — the policy
    /// is silent through a bill 25% over budget, forever. $10 and $15 are 50%
    /// and 75% of $20 and neither one ever reaches 80%.
    @MainActor
    func testNeitherAccountsOwnFigureCrossesTheLineTheirBillWalkedPast() async throws {
        let centre = try makeCentre(budget: Budget(
            amountMinor: 2_000, currency: "USD", alertsAt: [0.80, 1.0]
        ))

        for _ in 0..<3 {
            for amount in [1_000, 1_500] {
                await centre.consider(
                    spend: Self.spend(amount), serviceID: "claude", displayName: "Claude"
                )
            }
        }

        XCTAssertTrue(
            centre.recent.isEmpty,
            "the per-account figures alerted after all, so the fold is not what the fix rests on"
        )
    }

    // MARK: - Cancellation

    /// `stop()` cancels the refresh task at terminate and on every interval
    /// change, and `URLError.cancelled` reaches the sweep as an ordinary
    /// `.network(...)`. Recording that as a failure threw away the reading on
    /// screen and armed a backoff against a provider that never answered badly.
    @MainActor
    func testACancelledSweepLeavesTheSnapshotsAndTheFailureCountsAlone() async throws {
        let state = AppState()
        state.alertCenter = try makeCentre()
        state.providers = [AnyUsageProvider(StubProvider(id: "slow", answer: .sleepsUntilCancelled))]
        let standing = Self.reading("slow", percent: 0.42)
        state.snapshots["slow"] = .success(standing)

        let sweep = Task { await state.refreshAll() }
        // Long enough that the group has started its child. Cancelling before
        // there is anything in flight would pass for the wrong reason.
        try await Task.sleep(nanoseconds: 100_000_000)
        sweep.cancel()
        await sweep.value

        XCTAssertEqual(
            state.snapshots["slow"].flatMap { try? $0.get() }, standing,
            "a torn-down fetch overwrote the reading the row was drawing"
        )
        XCTAssertEqual(
            state.consecutiveFailureCount(for: "slow"), 0,
            "a cancellation was counted toward the backoff"
        )
    }

    /// Why the guard is `continue` and not `break`. A fetch already past its
    /// last suspension point finishes and answers whatever happens to the group
    /// around it; breaking out on the first cancelled sibling would throw that
    /// answer away, which is the same lost reading in a different place.
    @MainActor
    func testACancelledSweepStillRecordsASuccessThatLanded() async throws {
        let state = AppState()
        state.alertCenter = try makeCentre()
        let landed = Self.reading("stubborn", percent: 0.61)
        state.providers = [
            AnyUsageProvider(StubProvider(id: "slow", answer: .sleepsUntilCancelled)),
            AnyUsageProvider(StubProvider(
                id: "stubborn", answer: .reportsDespiteCancellation(landed, after: 0.35)
            ))
        ]

        let sweep = Task { await state.refreshAll() }
        // The cancellable child throws here, at 0.10s; the stubborn one answers
        // at 0.35s. So the failure is consumed first, which is the ordering
        // that tells `continue` and `break` apart.
        try await Task.sleep(nanoseconds: 100_000_000)
        sweep.cancel()
        await sweep.value

        XCTAssertEqual(
            state.snapshots["stubborn"].flatMap { try? $0.get() }, landed,
            "the loop stopped draining at the first cancelled fetch and lost a real reading"
        )
        XCTAssertNil(state.snapshots["slow"], "the cancelled fetch wrote a snapshot anyway")
    }

    // MARK: - Per-row refresh

    /// The freshness line is the age of the stalest reading on screen, derived
    /// from a per-provider stamp that only the sweep used to write. A row
    /// refreshed by hand therefore kept reporting the age of the reading it had
    /// just replaced — on both outcomes, because `refresh(_:)` overwrites the
    /// snapshot when it fails too.
    @MainActor
    func testAPerRowRefreshStampsTheReadingOnBothOutcomes() async throws {
        let state = AppState()
        state.alertCenter = try makeCentre()
        let stub = StubProvider(id: "solo", answer: .fails(.network("no route")))
        state.providers = [AnyUsageProvider(stub)]

        await state.refresh("solo")
        let afterFailure = try XCTUnwrap(
            state.lastRefresh, "a failed row refresh left the reading unstamped"
        )

        // `lastRefresh` is a minimum over stamps, so a second refresh can only
        // move it if the first one really wrote the row's own stamp.
        try await Task.sleep(nanoseconds: 20_000_000)
        stub.answer = .reports(Self.reading("solo", percent: 0.5))
        await state.refresh("solo")
        let afterSuccess = try XCTUnwrap(state.lastRefresh)

        XCTAssertGreaterThan(
            afterSuccess, afterFailure,
            "the row reported a new reading at the old reading's age"
        )
    }

    // MARK: - The Keychain read

    /// The defect behind "aibars keeps asking for Keychain access". Every
    /// provider fetch in one sweep calls `token(for:)`, the cache check was not
    /// atomic with the read it guards, and so every one of them issued its own
    /// `SecItemCopyMatching` — one access dialog per provider, of which
    /// dismissing any single one marks the store denied for all the rest.
    ///
    /// Counted through an injected reader rather than timed: a race that
    /// happens not to happen on this run is not evidence of anything.
    func testSixteenConcurrentCallersIssueOneKeychainRead() throws {
        let reads = Counter()
        let payload = try JSONEncoder().encode(["claude": "the-pasted-key"])
        let store = try seededStore { _ in
            reads.bump()
            // Wide enough that all sixteen callers are inside `token(for:)`
            // before the first of them is finished. Detaching fifteen more
            // threads takes microseconds; this is fifty milliseconds.
            Thread.sleep(forTimeInterval: 0.05)
            return .success(payload)
        }

        let answers = race(16) { store.token(for: "claude") }

        XCTAssertEqual(reads.value, 1, "sixteen callers raised \(reads.value) Keychain reads")
        XCTAssertEqual(
            answers, Array(repeating: Optional("the-pasted-key"), count: 16),
            "a caller that waited on the gate got something other than the loaded answer"
        )

        // The point of the cache, restated: nothing after the first read costs
        // a read, including the explicit warm-up the launch sweep runs.
        store.warm()
        _ = store.token(for: "claude")
        XCTAssertEqual(reads.value, 1)
    }

    /// A refusal is an answer, and it has to be cached like one. This is the
    /// half of the race that put the dialog back on screen every few seconds:
    /// the first caller's refusal was stored, but the fourteen already past the
    /// check asked again regardless.
    func testARefusedReadIsMadeOnceAndRememberedForEveryCaller() throws {
        let reads = Counter()
        let store = try seededStore { _ in
            reads.bump()
            Thread.sleep(forTimeInterval: 0.05)
            return .denied
        }

        let answers = race(16) { store.token(for: "claude") }

        XCTAssertEqual(reads.value, 1, "a dismissed dialog was raised \(reads.value) times")
        XCTAssertEqual(answers, Array(repeating: String?.none, count: 16))
        XCTAssertTrue(store.isAccessDenied, "the refusal was not recorded as one")
    }

    // MARK: - Fixtures

    /// One sweep's worth of spend readings, in the order and the interleaving
    /// `refreshAll`'s consumer loop uses: each result is written to `snapshots`
    /// and then noted, before the next result arrives. That ordering is what
    /// makes the fold correct — `note` reads `spendReports`, so the reading
    /// that just landed is already in the total it is judged against.
    @MainActor
    private func sweep(_ state: AppState, _ readings: [(String, Int)]) async {
        for (id, amountMinor) in readings {
            let data = UsageData(
                providerID: id,
                primary: UsageMetric(label: "Monthly", used: 1, limit: 100),
                spend: Self.spend(amountMinor)
            )
            state.snapshots[id] = .success(data)
            await state.note(id, .success(data))
        }
    }

    private static func spend(_ amountMinor: Int) -> SpendReport {
        SpendReport(
            amountMinor: amountMinor, currency: "USD", period: .month, confidence: .measured
        )
    }

    private static func reading(_ id: String, percent: Double) -> UsageData {
        UsageData(
            providerID: id,
            fetchedAt: Date(timeIntervalSinceReferenceDate: 700_000_000),
            primary: UsageMetric(label: "5h window", used: percent * 100, limit: 100)
        )
    }

    /// Fixed, so that two crossings in one test share an instant and the
    /// cooldown is exercised at its hardest.
    private static let clock = Date(timeIntervalSinceReferenceDate: 700_000_000)

    /// A scratch domain per store: an alert centre writes its rules and its
    /// arming on every change, and a budget written to the shared store is an
    /// amount left behind in the developer's own preferences.
    private func scratchDomain(_ label: String, _ function: String = #function) throws -> UserDefaults {
        // Stable, not a UUID. `TestDomain` in `TestIsolation.swift` has the
        // measurement: `removePersistentDomain` empties a domain and does not
        // delete its file, so a fresh name per run left a plist behind every time.
        let suite = TestDomain.stable("\(TestDomain.prefix).sweep.\(function).\(label)")
        let store = try XCTUnwrap(UserDefaults(suiteName: suite), "could not open a scratch suite")
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return store
    }

    /// An alert centre that can fire, on its own domain. `levels: []` switches
    /// the usage policy off without switching the centre off, so `recent` holds
    /// budget crossings and nothing else.
    @MainActor
    private func makeCentre(budget: Budget? = nil, _ function: String = #function) throws -> AlertCenter {
        let budgets = BudgetStore(store: try scratchDomain("budgets", function))
        if let budget { budgets.setBudget(budget, for: "claude") }
        let centre = AlertCenter(
            store: try scratchDomain("alerts", function), budgets: budgets, now: { Self.clock }
        )
        centre.rules = ThresholdRules(
            isEnabled: true, levels: [], coversSecondaryWindows: false, announcesReset: false
        )
        return centre
    }

    /// A store whose Keychain read is the given function, with the metadata a
    /// read needs to happen at all: `loadPersisted` refuses to touch the
    /// Keychain unless a pasted credential is on record, which is the whole
    /// reason a launch with only browser sessions never prompts.
    private func seededStore(
        _ function: String = #function,
        reader: @escaping @Sendable (String) -> KeychainStore.ReadResult
    ) throws -> SessionStore {
        let store = SessionStore(reader: reader, defaults: try scratchDomain("sessions", function))
        // Seeding costs no read of its own: with the metadata still empty,
        // `loadPersisted` short-circuits before the reader.
        try store.setToken("seed", for: "claude", source: .apiKey)
        store.invalidateCache()
        addTeardownBlock {
            // The seed is a real write, and under xctest `KeychainStore` is one
            // dictionary shared by the whole process — so it is undone rather
            // than left for the next suite. Written back first on purpose:
            // `clear` only deletes the combined item when removing the entry
            // empties the dictionary, and a reader that answered `.denied`
            // during the test leaves that dictionary empty already.
            store.invalidateCache()
            try? store.setToken("seed", for: "claude", source: .apiKey)
            store.clear("claude")
        }
        return store
    }

    /// `count` real threads, not tasks. The cooperative pool is as wide as the
    /// machine's cores and each caller here blocks it, so a task group would
    /// quietly serialise the tail of the race and the count would be right for
    /// the wrong reason.
    private func race<Answer>(_ count: Int, _ body: @escaping @Sendable () -> Answer) -> [Answer] {
        let answers = Collector<Answer>()
        let finished = DispatchGroup()
        for _ in 0..<count {
            finished.enter()
            Thread.detachNewThread {
                answers.append(body())
                finished.leave()
            }
        }
        XCTAssertEqual(finished.wait(timeout: .now() + 10), .success, "the race deadlocked")
        return answers.values
    }
}

/// A provider that answers on command, so the sweep can be driven without a
/// network. It implements the protocol and holds no opinions of its own.
private final class StubProvider: UsageProvider, ObservableObject {
    enum Answer {
        case reports(UsageData)
        case fails(ProviderError)
        /// Sleeps cancellably, so tearing the group down reaches `refreshAll`'s
        /// catch-all as `CancellationError` exactly as a torn-down URLSession
        /// task reaches it as `URLError.cancelled`.
        case sleepsUntilCancelled
        /// Sleeps *un*cancellably and then answers — a fetch already past its
        /// last suspension point when the sweep around it was cancelled.
        case reportsDespiteCancellation(UsageData, after: TimeInterval)
    }

    let id: String
    let serviceID: String
    let accountID: String?
    let displayName: String
    let iconName = "circle"
    var isEnabled = true
    var isAuthenticated = true
    var answer: Answer

    init(
        id: String,
        serviceID: String? = nil,
        accountID: String? = nil,
        displayName: String = "Stub",
        answer: Answer = .fails(.unsupported)
    ) {
        self.id = id
        self.serviceID = serviceID ?? id
        self.accountID = accountID
        self.displayName = displayName
        self.answer = answer
    }

    func fetchUsage() async throws -> UsageData {
        switch answer {
        case .reports(let data):
            return data
        case .fails(let error):
            throw error
        case .sleepsUntilCancelled:
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw ProviderError.unsupported
        case .reportsDespiteCancellation(let data, let delay):
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    continuation.resume()
                }
            }
            return data
        }
    }

    func authenticate() async throws {}
    func signOut() async throws {}
    func saveTokenManually(_ token: String, source: SessionSource) throws {}
}

/// Counts calls from whichever thread makes them.
private final class Counter: @unchecked Sendable {
    private let mutex = NSLock()
    private var count = 0

    func bump() {
        mutex.lock()
        count += 1
        mutex.unlock()
    }

    var value: Int {
        mutex.lock()
        defer { mutex.unlock() }
        return count
    }
}

/// Collects answers from whichever thread produced them. The order is whatever
/// the race decided; every assertion here is about the multiset.
private final class Collector<Value>: @unchecked Sendable {
    private let mutex = NSLock()
    private var collected: [Value] = []

    func append(_ value: Value) {
        mutex.lock()
        collected.append(value)
        mutex.unlock()
    }

    var values: [Value] {
        mutex.lock()
        defer { mutex.unlock() }
        return collected
    }
}
