import SQLite3
import XCTest
@testable import aibarsCore

/// A clock the tests move by hand.
///
/// Every rule in the store is a span — thirty seconds between readings,
/// fourteen days of raw samples, four hundred days of rollups — and none of
/// them are worth waiting out in real time.
private final class HistoryClock {
    private(set) var now: Date

    init(_ start: Date) { self.now = start }

    func advance(_ interval: TimeInterval) { now = now.addingTimeInterval(interval) }
}

/// The file every reading ends up in.
///
/// The cases worth pinning are the ones that cannot be corrected later: what is
/// refused, what a series is keyed under, what a reset does to the rows behind
/// it, what survives a prune, and what the store does with a file it did not
/// write. The reads are `queue.sync` behind a FIFO writer, so a read issued
/// after a write already sees it and none of these tests have to wait.
final class UsageHistoryStoreTests: XCTestCase {

    // MARK: - Harness

    /// Somewhere unremarkable, on a whole second, so a timestamp survives the
    /// round trip through a file that stores seconds.
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// Everything these tests store is at or after `start`, so this reads as
    /// "since the beginning" without asking the calendar about the year 1.
    private let epoch = Date(timeIntervalSince1970: 0)

    /// A fresh directory per test. XCTest builds one instance per test method,
    /// so this initialiser runs once per test and no two share a file.
    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("aibars-history-\(UUID().uuidString)", isDirectory: true)

    private var databaseURL: URL { directory.appendingPathComponent("history.sqlite") }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A scratch domain per test, torn down afterwards, so the recording switch
    /// a test flips is never the user's.
    private func scratchDefaults(_ label: String = #function) throws -> UserDefaults {
        let name = "aibars.history.tests.\(label).\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    @MainActor
    private func makeStore(_ clock: HistoryClock, defaults: UserDefaults? = nil) throws -> UsageHistoryStore {
        try UsageHistoryStore(
            directory: directory,
            now: { clock.now },
            defaults: defaults ?? scratchDefaults()
        )
    }

    /// The series a reading made by `usage` below lands in. Built through
    /// `windowKey(for:)` rather than spelled out, because that function is what
    /// a caller matching a live metric back to a stored series has to use.
    private func series(_ providerID: String = "claude", _ label: String = "5h window") -> HistorySeriesID {
        HistorySeriesID(providerID: providerID, windowKey: HistorySeriesID.windowKey(for: label))
    }

    private func usage(
        _ used: Double,
        limit: Double = 100,
        at date: Date,
        label: String = "5h window",
        unit: String? = "%",
        resetDate: Date? = nil,
        providerID: String = "claude"
    ) -> UsageData {
        UsageData(
            providerID: providerID,
            fetchedAt: date,
            primary: UsageMetric(label: label, used: used, limit: limit, unit: unit, resetDate: resetDate)
        )
    }

    /// Waits for something the store publishes from a hop back to the main
    /// actor. A poll rather than a fixed sleep: it ends as soon as the hop
    /// happens, and a store that never bumps fails an assertion rather than the
    /// timeout.
    @MainActor
    private func waitUntil(
        _ what: String,
        timeout: TimeInterval = 2,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertTrue(condition(), what, file: file, line: line)
    }

    // MARK: - The round trip

    @MainActor
    func testAReadingComesBackOutOfTheFile() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(42, at: clock.now), for: "claude")

        let samples = store.samples(for: series(), since: epoch)
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(try XCTUnwrap(samples.first).at, start)
        XCTAssertEqual(try XCTUnwrap(samples.first).percent, 0.42, accuracy: 1e-9)
        XCTAssertEqual(store.series(), [series()])

        let days = store.days(for: series(), since: epoch)
        XCTAssertEqual(days.count, 1)
        XCTAssertEqual(try XCTUnwrap(days.first).day, Calendar.current.startOfDay(for: start))
        XCTAssertEqual(try XCTUnwrap(days.first).peak, 0.42, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(days.first).mean, 0.42, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(days.first).samples, 1)
    }

    @MainActor
    func testASecondStoreOverTheSameDirectorySeesTheFirstsHistory() throws {
        let clock = HistoryClock(start)
        do {
            let first = try makeStore(clock)
            first.record(usage(42, at: clock.now), for: "claude")
            XCTAssertEqual(first.samples(for: series(), since: epoch).count, 1)
        }

        let second = try makeStore(clock)
        XCTAssertEqual(second.samples(for: series(), since: epoch).count, 1)
        XCTAssertEqual(second.series(), [series()])
    }

    @MainActor
    func testAStoredReadingBumpsTheRevision() async throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)
        XCTAssertEqual(store.revision, 0)

        store.record(usage(42, at: clock.now), for: "claude")
        // The read syncs behind the write, so the row is already there by the
        // time this line runs; only the bump has still to hop home.
        XCTAssertEqual(store.samples(for: series(), since: epoch).count, 1)

        await waitUntil("a stored reading should have told the charts to redraw") { store.revision > 0 }
    }

    @MainActor
    func testAnEmptyStoreAnswersEmptyRatherThanNothing() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        XCTAssertEqual(store.series(), [])
        XCTAssertEqual(store.samples(for: series(), since: epoch), [])
        XCTAssertEqual(store.days(for: series(), since: epoch), [])
        XCTAssertEqual(store.samples(for: series("grok", "monthly"), since: epoch), [])
    }

    // MARK: - Readings the store refuses

    @MainActor
    func testTheSameReadingRecordedTwiceLeavesOneRow() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        let reading = usage(42, at: clock.now)
        store.record(reading, for: "claude")
        store.record(reading, for: "claude")

        XCTAssertEqual(store.samples(for: series(), since: epoch).count, 1)
        XCTAssertEqual(
            store.days(for: series(), since: epoch).first?.samples, 1,
            "two sweeps racing must not double-count the day they land in"
        )
    }

    /// The rule is "closer together than thirty seconds", so thirty seconds
    /// itself is far enough apart.
    @MainActor
    func testTwentyNineSecondsApartIsRefusedAndThirtyIsKept() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(10, at: clock.now), for: "claude")
        clock.advance(29)
        store.record(usage(11, at: clock.now), for: "claude")
        XCTAssertEqual(
            store.samples(for: series(), since: epoch).count, 1,
            "a refresh twenty-nine seconds later carries the provider's cached figure"
        )

        clock.advance(1)
        store.record(usage(12, at: clock.now), for: "claude")
        XCTAssertEqual(store.samples(for: series(), since: epoch).count, 2)
    }

    /// A clock that moves backwards — a daylight saving change, an ntp
    /// correction — fails the gap rule the same way a burst of refreshes does.
    @MainActor
    func testAReadingOlderThanTheLastOneIsRefused() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(10, at: clock.now), for: "claude")
        clock.advance(-600)
        store.record(usage(90, at: clock.now), for: "claude")

        XCTAssertEqual(store.samples(for: series(), since: epoch).map(\.at), [start])
    }

    @MainActor
    func testAFutureStampIsPulledBackToNow() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(10, at: clock.now.addingTimeInterval(3600), providerID: "claude"), for: "claude")
        XCTAssertEqual(store.samples(for: series(), since: epoch).map(\.at), [start])

        clock.advance(60)
        store.record(usage(11, at: clock.now), for: "claude")
        XCTAssertEqual(
            store.samples(for: series(), since: epoch).count, 2,
            "the next real reading was measured against an hour that never happened"
        )
    }

    /// A status-only service reports no cap, and `percent` answers zero for one.
    /// Storing that would draw a fortnight of a flat line at zero, which is an
    /// assertion about usage rather than an absence of one.
    @MainActor
    func testUnusableFiguresAreNeverStored() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        let refused: [(String, UsageData)] = [
            ("no cap", usage(10, limit: 0, at: clock.now)),
            ("negative cap", usage(10, limit: -100, at: clock.now)),
            ("infinite cap", usage(10, limit: .infinity, at: clock.now)),
            ("nan cap", usage(10, limit: .nan, at: clock.now)),
            ("infinite usage", usage(.infinity, at: clock.now)),
            ("nan usage", usage(.nan, at: clock.now))
        ]

        for (what, data) in refused {
            store.record(data, for: "claude")
            XCTAssertTrue(store.samples(for: series(), since: epoch).isEmpty, "\(what) reached the file")
            XCTAssertTrue(store.series().isEmpty, "\(what) left a series behind with nothing in it")
            clock.advance(60)
        }
    }

    /// Zero used against a real cap is a true reading, not a missing one.
    @MainActor
    func testAnUntouchedQuotaIsStillWorthStoring() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(0, at: clock.now), for: "claude")

        XCTAssertEqual(store.samples(for: series(), since: epoch).map(\.percent), [0])
        XCTAssertEqual(store.days(for: series(), since: epoch).first?.samples, 1)
    }

    /// Providers overshoot soft limits, and one of them once reported a
    /// negative balance.
    @MainActor
    func testFiguresOutsideTheCapComeBackClamped() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(150, at: clock.now), for: "claude")
        clock.advance(60)
        store.record(usage(-40, at: clock.now), for: "claude")

        XCTAssertEqual(store.samples(for: series(), since: epoch).map(\.percent), [1, 0])
    }

    // MARK: - Identity

    @MainActor
    func testTwoAccountsOfOneServiceAreSeparateSeries() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(20, at: clock.now, providerID: "claude"), for: "claude")
        store.record(usage(80, at: clock.now, providerID: "claude"), for: "claude#2")

        XCTAssertEqual(store.series(), [series("claude"), series("claude#2")])
        XCTAssertEqual(store.samples(for: series("claude"), since: epoch).map(\.percent), [0.2])
        XCTAssertEqual(store.samples(for: series("claude#2"), since: epoch).map(\.percent), [0.8])
    }

    /// Rows are keyed per account; the payload only knows which service it came
    /// from, so the id the caller passes has to win.
    @MainActor
    func testTheSeriesIsKeyedByTheCallersIdNotThePayloads() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(10, at: clock.now, providerID: "claude"), for: "claude#2")

        XCTAssertEqual(store.series(), [series("claude#2")])
        XCTAssertTrue(store.samples(for: series("claude"), since: epoch).isEmpty)
    }

    @MainActor
    func testEachWindowOfOnePayloadIsItsOwnSeriesAndAStatusOnlyOneIsNotStored() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(
            UsageData(
                providerID: "claude",
                fetchedAt: clock.now,
                primary: UsageMetric(label: "5h window", used: 42, limit: 100, unit: "%"),
                secondary: [
                    UsageMetric(label: "Weekly", used: 10, limit: 50, unit: "messages"),
                    UsageMetric(label: "Status", used: 0, limit: 0)
                ]
            ),
            for: "claude"
        )

        XCTAssertEqual(store.series(), [series("claude", "5h window"), series("claude", "Weekly")])
        XCTAssertEqual(store.samples(for: series("claude", "Weekly"), since: epoch).map(\.percent), [0.2])
        XCTAssertTrue(store.samples(for: series("claude", "Status"), since: epoch).isEmpty)
    }

    /// Two labels that differ only in punctuation are one window, so the second
    /// of them is refused rather than opening a second series.
    @MainActor
    func testWindowsWhoseLabelsNormaliseToOneKeyAreOneSeries() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(
            UsageData(
                providerID: "claude",
                fetchedAt: clock.now,
                primary: UsageMetric(label: "Weekly · all models", used: 40, limit: 100, unit: "%"),
                secondary: [UsageMetric(label: "Weekly (all models)", used: 90, limit: 100, unit: "%")]
            ),
            for: "claude"
        )

        XCTAssertEqual(store.series(), [series("claude", "Weekly · all models")])
        XCTAssertEqual(store.samples(for: series("claude", "Weekly · all models"), since: epoch).map(\.percent), [0.4])
        XCTAssertEqual(store.days(for: series("claude", "Weekly · all models"), since: epoch).first?.samples, 1)
    }

    func testTheWindowKeyIgnoresCasePunctuationAndAccents() {
        XCTAssertEqual(HistorySeriesID.windowKey(for: "5h window"), "5h-window")
        XCTAssertEqual(HistorySeriesID.windowKey(for: "5H  WINDOW"), "5h-window")
        XCTAssertEqual(HistorySeriesID.windowKey(for: "Weekly · all models"), "weekly-all-models")
        XCTAssertEqual(HistorySeriesID.windowKey(for: "Weekly (all models)"), "weekly-all-models")
        XCTAssertEqual(HistorySeriesID.windowKey(for: "Crédits"), "credits")
        // Leading and trailing punctuation must not leave a separator on the
        // end, or "(weekly)" and "weekly" would be two series.
        XCTAssertEqual(HistorySeriesID.windowKey(for: "  (weekly)  "), "weekly")
    }

    /// A label with nothing alphanumeric in it would otherwise key every such
    /// window in a provider to the empty string and merge them.
    func testALabelWithNothingToKeyOnFallsBackToOneName() {
        XCTAssertEqual(HistorySeriesID.windowKey(for: ""), "window")
        XCTAssertEqual(HistorySeriesID.windowKey(for: "   "), "window")
        XCTAssertEqual(HistorySeriesID.windowKey(for: "—··—"), "window")
    }

    // MARK: - Resets and cap hits

    /// The one thing a history view exists to show. Clearing at a reset would
    /// throw away exactly the part the user came to look at.
    @MainActor
    func testAResetKeepsBothSidesOfTheBoundary() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(100, at: clock.now), for: "claude")
        clock.advance(60)
        store.record(usage(2, at: clock.now), for: "claude")

        let samples = store.samples(for: series(), since: epoch)
        XCTAssertEqual(samples.map(\.percent), [1, 0.02])
        XCTAssertEqual(samples.map(\.at), [start, start.addingTimeInterval(60)])

        // The boundary itself is only visible in the export, which is where a
        // reader needs to know that the plunge between two rows never happened.
        XCTAssertEqual(exportedFields(store).map { $0[9] }, ["0", "1"])
    }

    /// Either side of `UsageForecast.resetDrop`, kept clear of it: the two
    /// figures are divisions, and asserting a fall of exactly 0.20 would be
    /// asserting how a double rounds rather than what the store decides.
    @MainActor
    func testAFallShortOfTheResetDropIsNotARollover() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(80, at: clock.now), for: "claude")
        clock.advance(60)
        store.record(usage(61, at: clock.now), for: "claude")
        XCTAssertEqual(exportedFields(store).map { $0[9] }, ["0", "0"], "a fall of 0.19 is usage, not a rollover")

        // Each reading is judged against the one before it, so this is a fall of
        // 0.21 from 0.61 rather than 0.40 from where the series started.
        clock.advance(60)
        store.record(usage(40, at: clock.now), for: "claude")
        XCTAssertEqual(exportedFields(store).map { $0[9] }, ["0", "0", "1"], "a fall of 0.21 opened a new window")
    }

    /// A provider that says "resets in 5h" hands back a date that drifts
    /// forward at every poll. Without the requirement that the old date be in
    /// the past, every reading of such a provider would open a new window.
    @MainActor
    func testADriftingRenewalDateIsNotARollover() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        for step in 0..<4 {
            store.record(
                usage(Double(step * 10), at: clock.now, resetDate: clock.now.addingTimeInterval(5 * 3600)),
                for: "claude"
            )
            clock.advance(60)
        }

        XCTAssertEqual(exportedFields(store).map { $0[9] }, ["0", "0", "0", "0"])
    }

    /// A window that rolled over without shedding much — a weekly cap that was
    /// barely touched — is still a rollover, and the provider said so.
    @MainActor
    func testARenewalDateThatHasPassedAndBeenReplacedIsARollover() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)
        let firstReset = start.addingTimeInterval(60)

        store.record(usage(50, at: clock.now, resetDate: firstReset), for: "claude")
        clock.advance(120)
        store.record(usage(52, at: clock.now, resetDate: clock.now.addingTimeInterval(7 * 24 * 3600)), for: "claude")

        XCTAssertEqual(exportedFields(store).map { $0[9] }, ["0", "1"])
    }

    /// Counting readings at the cap rather than crossings would make the figure
    /// a measure of the polling interval.
    @MainActor
    func testCapHitsCountCrossingsOfTheThreshold() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        // 0.989 is under the threshold, 0.99 is the threshold, 1.0 is already
        // over it and must not count a second time.
        for used in [98.9, 99.0, 100.0, 50.0, 99.0] {
            store.record(usage(used, at: clock.now), for: "claude")
            clock.advance(60)
        }

        let day = try XCTUnwrap(store.days(for: series(), since: epoch).first)
        XCTAssertEqual(day.capHits, 2)
        XCTAssertEqual(day.samples, 5)
        XCTAssertEqual(day.peak, 1, accuracy: 1e-9)
        XCTAssertEqual(day.mean, (0.989 + 0.99 + 1 + 0.5 + 0.99) / 5, accuracy: 1e-9)
    }

    /// The crossing happened before aibars was watching, but a day spent pinned
    /// at the cap reporting no hits at all is the worse answer.
    @MainActor
    func testASeriesThatOpensAtTheCapCountsOneHit() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(100, at: clock.now), for: "claude")

        XCTAssertEqual(store.days(for: series(), since: epoch).first?.capHits, 1)
    }

    // MARK: - Days

    @MainActor
    func testTodaysRollupIsRecomputedAsReadingsLand() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(10, at: clock.now), for: "claude")
        XCTAssertEqual(store.days(for: series(), since: epoch).first?.mean ?? 0, 0.1, accuracy: 1e-9)

        clock.advance(60)
        store.record(usage(30, at: clock.now), for: "claude")

        let day = try XCTUnwrap(store.days(for: series(), since: epoch).first)
        XCTAssertEqual(day.mean, 0.2, accuracy: 1e-9, "the mean of a day still being written to is the mean of what it holds")
        XCTAssertEqual(day.peak, 0.3, accuracy: 1e-9)
        XCTAssertEqual(day.samples, 2)
    }

    @MainActor
    func testDaysComeBackInOrderAndOnlyFromTheFloorAsked() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(10, at: clock.now), for: "claude")
        clock.advance(24 * 3600)
        let secondDay = clock.now
        store.record(usage(90, at: clock.now), for: "claude")

        let both = store.days(for: series(), since: epoch)
        XCTAssertEqual(both.count, 2)
        XCTAssertEqual(both.map(\.day), both.map(\.day).sorted())

        let later = store.days(for: series(), since: secondDay)
        XCTAssertEqual(later.count, 1, "the floor is rounded down to its own midnight, not to the instant given")
        XCTAssertEqual(later.first?.peak ?? 0, 0.9, accuracy: 1e-9)
    }

    // MARK: - Pruning

    /// The boundary is `ts < floor`, so a sample exactly at the retention edge
    /// survives and one a second older does not.
    @MainActor
    func testSamplesAgeOutAtTheEdgeAndTheirDaysSurvive() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(42, at: clock.now), for: "claude")

        clock.advance(HistoryRetention.sample)
        store.maintain()
        XCTAssertEqual(
            store.samples(for: series(), since: epoch).count, 1,
            "a sample exactly at the retention edge is still inside it"
        )

        clock.advance(1)
        store.maintain()
        XCTAssertTrue(store.samples(for: series(), since: epoch).isEmpty)
        XCTAssertEqual(
            store.days(for: series(), since: epoch).count, 1,
            "a rollup that survives its samples can never be rebuilt from them"
        )
        XCTAssertEqual(store.series(), [series()], "the series still has a day behind it")
    }

    /// The rollup outlives the samples by a long way, and then it goes too —
    /// and takes the empty series name with it, or a picker would list it for
    /// ever.
    @MainActor
    func testASeriesWithNothingLeftStopsBeingListed() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(42, at: clock.now), for: "claude")

        clock.advance(HistoryRetention.day + 24 * 3600)
        store.maintain()

        XCTAssertTrue(store.samples(for: series(), since: epoch).isEmpty)
        XCTAssertTrue(store.days(for: series(), since: epoch).isEmpty)
        XCTAssertEqual(store.series(), [])
    }

    @MainActor
    func testMaintenanceIsHarmlessOnAnEmptyStoreAndWhenRepeated() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.maintain()
        store.maintain()
        XCTAssertEqual(store.series(), [])

        store.record(usage(42, at: clock.now), for: "claude")
        clock.advance(60)
        store.maintain()
        store.maintain()

        XCTAssertEqual(
            store.samples(for: series(), since: epoch).count, 1,
            "nothing had aged out, so maintenance had nothing to take"
        )
        XCTAssertEqual(store.days(for: series(), since: epoch).count, 1)
    }

    // MARK: - Forgetting

    @MainActor
    func testForgettingOneAccountLeavesEveryOther() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        for id in ["claude", "claude#2", "gemini"] {
            store.record(usage(40, at: clock.now, providerID: id), for: id)
        }

        store.forget("claude")

        XCTAssertEqual(store.series(), [series("claude#2"), series("gemini")])
        XCTAssertTrue(store.samples(for: series("claude"), since: epoch).isEmpty)
        XCTAssertTrue(store.days(for: series("claude"), since: epoch).isEmpty)
        XCTAssertEqual(store.samples(for: series("claude#2"), since: epoch).count, 1)
        XCTAssertEqual(store.days(for: series("gemini"), since: epoch).count, 1)
    }

    /// Nothing upstream should ask to store a reading under no account at all,
    /// but a store that filed one under a key it could never be asked for again
    /// would keep it for four hundred days.
    @MainActor
    func testAnEmptyAccountIdIsStillItsOwnSeriesAndCanBeForgotten() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(40, at: clock.now), for: "")
        store.record(usage(60, at: clock.now), for: "claude")

        XCTAssertEqual(store.series(), [series(""), series("claude")])
        XCTAssertEqual(store.samples(for: series(""), since: epoch).map(\.percent), [0.4])

        store.forget("")
        XCTAssertEqual(store.series(), [series("claude")])
    }

    @MainActor
    func testForgettingSomethingUnknownChangesNothing() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(40, at: clock.now), for: "claude")
        store.forget("copilot")
        store.forget("")

        XCTAssertEqual(store.series(), [series()])
        XCTAssertEqual(store.samples(for: series(), since: epoch).count, 1)
    }

    // MARK: - The recording switch

    @MainActor
    func testRecordingIsOnUntilSomebodyTurnsItOff() throws {
        let clock = HistoryClock(start)
        let defaults = try scratchDefaults()

        // Read before asserting: the property is main-actor isolated and an
        // autoclosure argument is not.
        let fresh = try makeStore(clock, defaults: defaults).isEnabled
        XCTAssertTrue(fresh, "a key nobody has written should not ship with history switched off")

        defaults.set(false, forKey: Self.isEnabledKey)
        let reopened = try makeStore(clock, defaults: defaults).isEnabled
        XCTAssertFalse(reopened)
    }

    @MainActor
    func testTurningRecordingOffStopsNewReadingsAndKeepsTheOld() throws {
        let clock = HistoryClock(start)
        let defaults = try scratchDefaults()
        let store = try makeStore(clock, defaults: defaults)

        store.record(usage(42, at: clock.now), for: "claude")
        store.isEnabled = false
        clock.advance(3600)
        store.record(usage(90, at: clock.now), for: "claude")

        XCTAssertEqual(
            store.samples(for: series(), since: epoch).map(\.percent), [0.42],
            "turning recording off deletes nothing — that is what forget is for"
        )
        XCTAssertEqual(defaults.object(forKey: Self.isEnabledKey) as? Bool, false)

        store.isEnabled = true
        clock.advance(3600)
        store.record(usage(91, at: clock.now), for: "claude")
        XCTAssertEqual(store.samples(for: series(), since: epoch).count, 2)
    }

    /// The switch is read out of a file anything can write to.
    @MainActor
    func testAnUnreadableSwitchLeavesRecordingOn() throws {
        let clock = HistoryClock(start)
        let defaults = try scratchDefaults()
        defaults.set("sometimes", forKey: Self.isEnabledKey)

        let store = try makeStore(clock, defaults: defaults)
        XCTAssertTrue(store.isEnabled)

        store.record(usage(42, at: clock.now), for: "claude")
        XCTAssertEqual(store.samples(for: series(), since: epoch).count, 1)
    }

    // MARK: - Export

    @MainActor
    func testExportHasAHeaderAndOneLineForEachReading() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        for used in [10.0, 20.0, 30.0] {
            store.record(usage(used, at: clock.now, unit: "messages"), for: "claude")
            clock.advance(60)
        }

        let csv = store.exportCSV(since: epoch)
        XCTAssertTrue(csv.hasSuffix("\n"), "a file that does not end in a newline loses its last row to some readers")
        let lines = csv.split(separator: "\n", omittingEmptySubsequences: false).dropLast()
        XCTAssertEqual(lines.count, 4)
        XCTAssertEqual(lines.first.map(String.init), "grain,provider,window,label,unit,at,used,limit,percent,resets")

        let first = try XCTUnwrap(exportedFields(store).first)
        XCTAssertEqual(first[0], "sample")
        XCTAssertEqual(first[1], "claude")
        XCTAssertEqual(first[2], "5h-window")
        XCTAssertEqual(first[3], "5h window")
        XCTAssertEqual(first[4], "messages")
        XCTAssertEqual(Self.iso.date(from: first[5]), start)
        XCTAssertEqual(first[6], "10.0000")
        XCTAssertEqual(first[7], "100.0000")
        XCTAssertEqual(first[8], "10.00")
    }

    @MainActor
    func testExportOfAnEmptyStoreIsJustItsHeader() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        XCTAssertEqual(store.exportCSV(since: epoch), "grain,provider,window,label,unit,at,used,limit,percent,resets\n")
    }

    /// One unescaped comma shifts every later column, and provider labels carry
    /// them. A newline is worse: it ends the row.
    @MainActor
    func testExportQuotesLabelsThatCarryCommasQuotesAndNewlines() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(40, at: clock.now, label: "Weekly, \"all\" models\nsince Monday", unit: nil), for: "claude")

        let csv = store.exportCSV(since: epoch)
        XCTAssertTrue(csv.contains("\"Weekly, \"\"all\"\" models\nsince Monday\""), "got \(csv)")
        XCTAssertTrue(csv.contains(",,"), "a window with no unit should export an empty field, not the word nil")
    }

    /// Raw readings are kept for a fortnight and rollups for over a year, so an
    /// export spanning both switches grain once, at the day the oldest
    /// surviving reading falls in, and never covers a day twice.
    @MainActor
    func testExportSwitchesFromDaysToReadingsAtTheOldestSurvivingReading() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(40, at: clock.now), for: "claude")
        clock.advance(HistoryRetention.sample + 24 * 3600)
        store.record(usage(60, at: clock.now), for: "claude")
        store.maintain()

        let rows = exportedFields(store)
        XCTAssertEqual(rows.map { $0[0] }, ["day", "sample"])
        XCTAssertEqual(Self.iso.date(from: rows[0][5]), Calendar.current.startOfDay(for: start))
        XCTAssertEqual(rows[0][8], "40.00", "a day row carries the day's peak")
        XCTAssertEqual(Self.iso.date(from: rows[1][5]), clock.now)
    }

    @MainActor
    func testExportHonoursItsFloor() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)

        store.record(usage(40, at: clock.now), for: "claude")
        clock.advance(600)
        store.record(usage(60, at: clock.now), for: "claude")

        let recent = exportedFields(store, since: start.addingTimeInterval(300))
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent[0][8], "60.00")
    }

    // MARK: - Files the store did not write

    @MainActor
    func testADirectoryThatCannotBeCreatedThrows() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("occupied")
        XCTAssertTrue(FileManager.default.createFile(atPath: blocker.path, contents: Data("no".utf8)))

        do {
            // A history that cannot be opened has to say so. Swallowing it here
            // is how an app ends up reporting a fortnight of nothing.
            _ = try UsageHistoryStore(
                directory: blocker.appendingPathComponent("history", isDirectory: true),
                defaults: try scratchDefaults()
            )
            XCTFail("a store under a regular file should not have opened")
        } catch {
            // Which error the filesystem raises is its business; that it reaches
            // the caller instead of leaving a half-open store is the point.
            XCTAssertFalse(FileManager.default.fileExists(atPath: blocker.appendingPathComponent("history").path))
        }
    }

    @MainActor
    func testAFileThatIsNotADatabaseThrows() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("this is prose, not a database".utf8).write(to: databaseURL)

        do {
            _ = try UsageHistoryStore(directory: directory, defaults: try scratchDefaults())
            XCTFail("a file with no SQLite header should not have opened")
        } catch let error as HistoryError {
            guard case .unavailable = error else { return XCTFail("got \(error)") }
        }
    }

    /// Opening a file a later version wrote would mean appending rows that a
    /// schema we know nothing about has to make sense of.
    @MainActor
    func testAFileFromANewerSchemaIsRefused() throws {
        let clock = HistoryClock(start)
        do {
            let first = try makeStore(clock)
            first.record(usage(42, at: clock.now), for: "claude")
            XCTAssertEqual(first.samples(for: series(), since: epoch).count, 1)
        }
        try execDirect(["PRAGMA user_version = 99"])

        do {
            _ = try UsageHistoryStore(directory: directory, defaults: try scratchDefaults())
            XCTFail("a file from schema 99 should not have opened")
        } catch let error as HistoryError {
            guard case .unsupportedSchema(let version) = error else { return XCTFail("got \(error)") }
            XCTAssertEqual(version, 99)
        }
    }

    /// The point of versioning the schema is that the shape can change without
    /// the history being thrown away.
    @MainActor
    func testAFileAtVersionZeroMigratesAndKeepsEveryRowItHad() throws {
        let clock = HistoryClock(start)
        do {
            let first = try makeStore(clock)
            first.record(usage(42, at: clock.now), for: "claude")
            XCTAssertEqual(first.samples(for: series(), since: epoch).count, 1)
        }
        XCTAssertEqual(try userVersion(), 1)
        try execDirect(["PRAGMA user_version = 0"])

        let migrated = try makeStore(clock)
        XCTAssertEqual(migrated.samples(for: series(), since: epoch).map(\.percent), [0.42])
        XCTAssertEqual(migrated.days(for: series(), since: epoch).count, 1)
        XCTAssertEqual(try userVersion(), 1, "a file that migrates on every open migrates on every open for ever")

        // And it takes new readings afterwards, into the series it already had.
        clock.advance(60)
        migrated.record(usage(43, at: clock.now), for: "claude")
        XCTAssertEqual(migrated.samples(for: series(), since: epoch).count, 2)
        XCTAssertEqual(migrated.series(), [series()])
    }

    /// Rows off disk are untrusted input like anything else in a file: they may
    /// have been written by a version that clamped differently, or not at all.
    @MainActor
    func testPersistedRowsAreTreatedAsUntrustedInput() throws {
        let clock = HistoryClock(start)
        let store = try makeStore(clock)
        store.record(usage(42, at: clock.now), for: "claude")
        // Read it back before opening a second connection: `record` writes on the
        // store's queue inside BEGIN IMMEDIATE, and the fixture connection below
        // sets no busy timeout, so a write still in flight would come back as
        // "database is locked" instead of arranging the rows.
        XCTAssertEqual(store.samples(for: series(), since: epoch).count, 1)

        let ts = Int64(start.timeIntervalSince1970)
        let previousDay = Int64(Calendar.current.startOfDay(for: start).timeIntervalSince1970) - 24 * 3600
        try execDirect([
            // A cap of zero would divide to infinity, and one of these is what a
            // status-only row looked like before it stopped being stored.
            "INSERT INTO sample (series, ts, used, cap, boundary) SELECT id, \(ts + 100), 5, 0, 0 FROM series",
            "INSERT INTO sample (series, ts, used, cap, boundary) SELECT id, \(ts + 200), 500, 100, 0 FROM series",
            "INSERT INTO sample (series, ts, used, cap, boundary) SELECT id, \(ts + 300), -5, 100, 0 FROM series",
            // A day with no samples behind it: the mean of it is a division by
            // zero waiting to happen.
            """
            INSERT INTO day (series, day, peak, total, peak_used, cap, samples, hits, resets)
            SELECT id, \(previousDay), 0.5, 3, 10, 100, 0, 0, 0 FROM series
            """
        ])

        let percents = store.samples(for: series(), since: epoch).map(\.percent)
        // Counted before it is indexed: the readings below are positional, and a
        // trap here would take the whole bundle down with it.
        guard percents.count == 4 else {
            return XCTFail("expected the store's reading and the three arranged ones, got \(percents.count)")
        }
        XCTAssertEqual(percents[0], 0.42, accuracy: 1e-9)
        XCTAssertEqual(percents[1], 0, "a cap of zero is no denominator, not an infinite reading")
        XCTAssertEqual(percents[2], 1)
        XCTAssertEqual(percents[3], 0)
        XCTAssertTrue(percents.allSatisfy(\.isFinite))

        let days = store.days(for: series(), since: epoch)
        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(try XCTUnwrap(days.first).mean, 0)
        XCTAssertEqual(try XCTUnwrap(days.first).samples, 0)
    }

    // MARK: - Errors

    /// Both failures end with the user looking at an empty chart, and the two
    /// of them ask for different things.
    func testBothFailuresExplainThemselves() throws {
        XCTAssertNotNil(HistoryError.unavailable("disk full").errorDescription)
        let newer = try XCTUnwrap(HistoryError.unsupportedSchema(7).errorDescription)
        XCTAssertTrue(newer.contains("7"), "got \(newer)")
    }

    // MARK: - Reading the file back

    private static let isEnabledKey = "aibars.history.enabled"

    private static let iso: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// Every exported row split back into its columns, header dropped.
    ///
    /// Unquoted on purpose: the one case that needs the quoting inspected
    /// asserts against the raw line instead, and every other case here uses
    /// labels with no commas in them.
    @MainActor
    private func exportedFields(_ store: UsageHistoryStore, since: Date? = nil) -> [[String]] {
        store.exportCSV(since: since ?? epoch)
            .split(separator: "\n")
            .dropFirst()
            .map { $0.components(separatedBy: ",") }
    }

    /// A second connection to the store's file, for arranging a fixture the
    /// store would never write itself.
    private func execDirect(_ statements: [String]) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let opened = try XCTUnwrap(handle)

        for sql in statements {
            var message: UnsafeMutablePointer<CChar>?
            let status = sqlite3_exec(opened, sql, nil, nil, &message)
            if status != SQLITE_OK {
                XCTFail("\(sql) failed: \(message.map { String(cString: $0) } ?? "code \(status)")")
            }
            sqlite3_free(message)
        }
    }

    /// The one question the store deliberately does not answer.
    private func userVersion() throws -> Int32 {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READWRITE, nil), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let opened = try XCTUnwrap(handle)

        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(opened, "PRAGMA user_version", -1, &statement, nil), SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        let prepared = try XCTUnwrap(statement)
        XCTAssertEqual(sqlite3_step(prepared), SQLITE_ROW)
        return sqlite3_column_int(prepared, 0)
    }
}
