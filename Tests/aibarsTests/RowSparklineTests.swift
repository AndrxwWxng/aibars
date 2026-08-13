import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// The trace under a row: where its ink goes, what it says out loud, and the
/// cache that stops nine rows asking a database the same question nine times.
///
/// Everything about the picture is pinned through `SparklineLayout`, which is
/// pure, so none of those cases host a view. The two that do host one are asking
/// questions only a layout pass can answer: how wide the thing asks to be, and
/// how tall.
final class RowSparklineTests: XCTestCase {

    /// The box the layout cases measure against: 230pt of text column at the
    /// shipped cozy sparkline height, both whole numbers so an off-by-a-half is
    /// visible in the failure message rather than hidden in a rounding.
    private let box = CGRect(x: 0, y: 0, width: 230, height: 18)

    // MARK: - runs: where the trace is cut

    /// Nothing to draw is not the same as a flat line at the floor, and the two
    /// have to be distinguishable from the outside — `runs` answering `[]` is
    /// what makes the `Path` empty rather than a rule across the box.
    func testAnEmptyOrAllNilSeriesHasNoRuns() {
        XCTAssertEqual(SparklineLayout.runs([]).count, 0)
        XCTAssertEqual(SparklineLayout.runs([nil, nil, nil]).count, 0)
    }

    func testOneReadingIsOneRunOfOne() {
        XCTAssertEqual(SparklineLayout.runs([nil, 0.4, nil]), [[1]])
    }

    /// The rule the store keeps and the reason it keeps it: an hour nothing
    /// landed in is `nil`, and joining across it would draw a night at the floor
    /// the Mac spent asleep.
    func testAGapCutsTheTrace() {
        XCTAssertEqual(SparklineLayout.runs([0.2, nil, 0.3]), [[0], [2]])
    }

    /// A window rolling over. At exactly `resetDrop` it cuts, so the boundary is
    /// the same closed one `HistoryQuery.segments` uses — a renewal reads as two
    /// traces with a break rather than one plunge through the box.
    func testAFallOfExactlyTheResetDropCuts() {
        XCTAssertEqual(SparklineLayout.runs([0.60, 0.30]), [[0], [1]])
    }

    /// And a thousandth under it does not. Written beside the case above because
    /// the pair is the boundary: either alone accepts a `>` where a `>=` belongs.
    func testAFallJustUnderTheResetDropDoesNotCut() {
        XCTAssertEqual(SparklineLayout.runs([0.60, 0.301]), [[0, 1]])
    }

    /// A drop of zero or less would ask for a cut at every hour that did not
    /// rise, which is nobody's intent, so it is read as "do not cut".
    func testAResetDropOfZeroNeverCuts() {
        XCTAssertEqual(
            SparklineLayout.runs([0.9, 0.1, 0.9, 0.0], resetDrop: 0),
            [[0, 1, 2, 3]]
        )
    }

    /// A non-finite reading is treated as a gap rather than allowed into the
    /// comparison. `min`/`max` both lose to a NaN, so one surviving into `point`
    /// would put a NaN in a `Path` and take the row's layout with it.
    func testANonFiniteReadingIsAGap() {
        XCTAssertEqual(SparklineLayout.runs([0.2, .nan, 0.3]), [[0], [2]])
        XCTAssertEqual(SparklineLayout.runs([0.2, .infinity, 0.3]), [[0], [2]])
    }

    // MARK: - point: where a bucket lands

    /// Both rails are on the box's own edges. The newest hour is the one the eye
    /// goes to, and a trace that stopped short of the row's text edge would be
    /// the only thing in the panel that did.
    func testTheFirstAndLastBucketsSitOnTheBoxEdges() {
        let first = SparklineLayout.point(bucket: 0, of: 24, peak: 0.5, in: box)
        let last = SparklineLayout.point(bucket: 23, of: 24, peak: 0.5, in: box)
        XCTAssertEqual(first.x, box.minX, accuracy: 1e-9)
        XCTAssertEqual(last.x, box.maxX, accuracy: 1e-9)
    }

    /// Twenty-four buckets divide the rail into twenty-three even steps, which is
    /// 230 / 23 = 10pt on this box. Written as the literal and as the division,
    /// because either alone accepts a rail divided by `count` instead of
    /// `count - 1` at some widths.
    func testTheRailDividesEvenly() {
        let step = box.width / CGFloat(24 - 1)
        XCTAssertEqual(step, 10, "the box this case is named for stopped being 230pt wide")
        for bucket in 0..<24 {
            let x = SparklineLayout.point(bucket: bucket, of: 24, peak: 0.5, in: box).x
            XCTAssertEqual(x, CGFloat(bucket) * step, accuracy: 1e-9, "bucket \(bucket)")
        }
    }

    /// A single-bucket series owns the whole rail and is placed at its centre.
    /// On the leading edge it would read as a trace that had been truncated.
    func testASingleBucketSitsAtTheCentre() {
        let only = SparklineLayout.point(bucket: 0, of: 1, peak: 0.5, in: box)
        XCTAssertEqual(only.x, box.midX, accuracy: 1e-9)
    }

    /// An index outside the series is clamped rather than placed outside the box.
    /// Nothing in the app can produce one; a `Path` that escaped its frame would
    /// be the row overflowing the panel, which is the failure this whole rollout
    /// is about.
    func testABucketOutsideTheSeriesIsClampedToTheRails() {
        XCTAssertEqual(SparklineLayout.point(bucket: -4, of: 24, peak: 0.5, in: box).x, box.minX)
        XCTAssertEqual(SparklineLayout.point(bucket: 99, of: 24, peak: 0.5, in: box).x, box.maxX)
    }

    // MARK: - y: the fixed axis

    /// 0 and 1 land half a stroke inside the box at each end, so a reading at the
    /// floor and a reading at the cap are both drawn wholly inside their slot
    /// rather than half outside it.
    func testTheRailsAreInsetByHalfAStroke() {
        let inset = Tokens.Control.sparklineStroke / 2
        XCTAssertEqual(SparklineLayout.y(0, in: box), box.maxY - inset, accuracy: 1e-9)
        XCTAssertEqual(SparklineLayout.y(1, in: box), box.minY + inset, accuracy: 1e-9)
        // 18pt box, 1pt stroke: the usable rail is 17pt and its centre is 0.5 +
        // 17/2 = 9pt down from the top, which is the box's own midY.
        XCTAssertEqual(SparklineLayout.y(0.5, in: box), box.midY, accuracy: 1e-9)
    }

    /// An overage a provider reports is drawn at the cap rather than above the
    /// box, exactly as the history chart does it.
    func testAnOverageIsDrawnAtTheCap() {
        XCTAssertEqual(SparklineLayout.y(1.3, in: box), SparklineLayout.y(1, in: box))
        XCTAssertEqual(SparklineLayout.y(-0.2, in: box), SparklineLayout.y(0, in: box))
    }

    /// A NaN answers the floor rather than surviving into the `Path`.
    func testANonFiniteReadingAnswersTheFloor() {
        XCTAssertEqual(SparklineLayout.y(.nan, in: box), box.maxY)
    }

    /// A box with no height answers its own centre rather than an inverted range.
    /// Reachable from a `Metrics` built by hand in a test, and the arithmetic
    /// below it (`floor - (floor - ceiling) * ratio`) would otherwise run
    /// backwards.
    func testAZeroHeightBoxAnswersItsCentre() {
        let flat = CGRect(x: 0, y: 4, width: 230, height: 0)
        XCTAssertEqual(SparklineLayout.y(0.5, in: flat), flat.midY)
        XCTAssertEqual(SparklineLayout.y(1, in: flat), flat.midY)
    }

    // MARK: - What it says out loud

    /// An all-empty trace draws nothing and therefore says nothing. An element
    /// announcing "no readings" on every row of a fresh install is fifteen
    /// sentences reporting the age of the app.
    func testAnEmptyTraceIsSilent() {
        XCTAssertNil(RowSparkline.spoken([]))
        XCTAssertNil(RowSparkline.spoken([nil, nil, nil]))
        XCTAssertNil(RowSparkline.spoken([.nan]))
    }

    func testOneReadingIsSaidAsOneReading() {
        XCTAssertEqual(
            RowSparkline.spoken([0.41]),
            "one reading in the last 24 hours, 41 percent"
        )
    }

    /// The three facts anyone would take off the curve: where it ended, how high
    /// it got, and how much of the day is missing.
    func testManyReadingsNameTheLatestThePeakAndTheGaps() throws {
        let spoken = try XCTUnwrap(RowSparkline.spoken([0.2, nil, 0.9, nil, 0.35]))
        XCTAssertEqual(spoken, "last 24 hours, latest 35 percent, peak 90 percent, 2 hours with no reading")
    }

    /// The singular, which is the case a plural rule gets wrong.
    func testOneMissingHourIsSaidInTheSingular() throws {
        let spoken = try XCTUnwrap(RowSparkline.spoken([0.2, nil, 0.35]))
        XCTAssertTrue(spoken.hasSuffix(", 1 hour with no reading"), spoken)
    }

    /// A full day says nothing about gaps, because there are none to explain.
    func testAFullDaySaysNothingAboutGaps() throws {
        let spoken = try XCTUnwrap(RowSparkline.spoken([0.2, 0.3, 0.4]))
        XCTAssertFalse(spoken.contains("no reading"), spoken)
    }

    // MARK: - The preview's own series

    /// The sample is a day long, so the pane previews the resolution the panel
    /// actually draws rather than a shorter series that would space its buckets
    /// differently.
    func testTheSampleIsAWholeDay() {
        XCTAssertEqual(RowSparkline.sample.count, RowSparklineStore.buckets)
    }

    /// And it really demonstrates both cases the drawing exists to handle: the
    /// gap at hours 6–8 and the reset between 15 and 16 cut it into three runs.
    /// Without this the preview could quietly become a plain rising line and the
    /// pane would be showing a feature it does not have.
    func testThePreviewSampleCarriesAGapAndAReset() {
        let runs = SparklineLayout.runs(RowSparkline.sample)
        XCTAssertEqual(runs.count, 3, "the sample stopped demonstrating a gap and a reset")
        XCTAssertEqual(runs[0], Array(0...5), "the gap moved off hours 6-8")
        XCTAssertEqual(runs[1], Array(9...15), "the reset moved off the 15/16 boundary")
        XCTAssertEqual(runs[2], Array(16...23))
    }

    // MARK: - The one thing on the row that cannot widen it

    /// **The structural half of the width contract.**
    ///
    /// A view's minimum width is what the panel has to find for it whatever else
    /// is on the line, and `SecondaryChipRun` is the cautionary tale: `fixedSize`
    /// on a run spanning the text column is what let one row draw 40pt past the
    /// panel's ground and drag every other row's alignment with it. This asks the
    /// same question of the trace and requires the answer to be zero.
    ///
    /// It is not zero for free. SwiftUI gives a bare `Shape` a default ideal of
    /// 10×10, so `.frame(maxWidth: .infinity)` on its own reports a 10pt ideal
    /// width — measured, not assumed — and the row would acquire a 10pt floor
    /// nothing asked for. `idealWidth: 0` is what takes it to zero, and this is
    /// the case that fails if somebody tidies that argument away.
    @MainActor
    func testTheTraceAsksForNoWidthAtAll() {
        for peaks in [[], RowSparkline.sample] as [[Double?]] {
            let host = NSHostingView(rootView: AnyView(RowSparkline(peaks: peaks, height: 18)))
            XCTAssertEqual(
                host.fittingSize.width, 0,
                "a trace of \(peaks.count) buckets asked the row for \(host.fittingSize.width)pt of width"
            )
        }
    }

    /// And the height it draws is the height it was handed, in both states — the
    /// number `RowGeometry` reserved. A trace that measured its own content would
    /// be the reservation and the drawing disagreeing, which is the defect this
    /// whole rollout is about.
    @MainActor
    func testTheTraceIsTheHeightItWasHanded() {
        for height in [16, 18, 19] as [CGFloat] {
            for peaks in [[], [nil], RowSparkline.sample] as [[Double?]] {
                let hosted = RowSparkline(peaks: peaks, height: height).frame(width: 230)
                let host = NSHostingView(rootView: AnyView(hosted))
                XCTAssertEqual(
                    host.fittingSize.height, height, accuracy: 0.01,
                    "\(peaks.count) buckets in a \(height)pt slot drew \(host.fittingSize.height)pt"
                )
            }
        }
    }

    // MARK: - The cache in front of the database

    /// A clock the tests move by hand, so the five-minute throttle does not take
    /// five minutes to assert.
    private final class Clock {
        private(set) var now: Date
        init(_ start: Date) { self.now = start }
        func advance(_ interval: TimeInterval) { now = now.addingTimeInterval(interval) }
    }

    /// Somewhere unremarkable, on a whole second, so a timestamp survives the
    /// round trip through a file that stores seconds.
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("aibars-sparkline-\(UUID().uuidString)", isDirectory: true)

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func scratchDefaults(_ label: String = #function) throws -> UserDefaults {
        // Stable, not a UUID. `TestDomain` in `TestIsolation.swift` has the
        // measurement: `removePersistentDomain` empties a domain and does not
        // delete its file, so a fresh name per run left a plist behind every time.
        let name = TestDomain.stable("\(TestDomain.prefix).sparkline.\(label)")
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    @MainActor
    private func history(_ clock: Clock) throws -> UsageHistoryStore {
        let defaults = try scratchDefaults()
        return try UsageHistoryStore(directory: directory, now: { clock.now }, defaults: defaults)
    }

    private func usage(_ percent: Double, limit: Double = 100, at date: Date) -> UsageData {
        UsageData(
            providerID: "claude",
            fetchedAt: date,
            primary: UsageMetric(label: "5h window", used: percent * limit, limit: limit, unit: "%")
        )
    }

    /// Waits for the rebuild the store detaches, rather than sleeping a fixed
    /// span: it ends the moment the cache is written and a store that never
    /// writes fails an assertion instead of a timeout.
    @MainActor
    private func waitForTrace(
        _ store: RowSparklineStore,
        _ providerID: String = "claude",
        file: StaticString = #filePath,
        line: UInt = #line
    ) async -> RowSparklineStore.Series? {
        let deadline = Date().addingTimeInterval(2)
        while store.series(for: providerID) == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        let series = store.series(for: providerID)
        XCTAssertNotNil(series, "the store never built a trace", file: file, line: line)
        return series
    }

    /// A row asking for a trace nobody has built gets nil and nothing else
    /// happens — no query, no clock read, no allocation. This is the call that
    /// runs nine to fifteen times per `body` pass.
    @MainActor
    func testAnUnseededStoreAnswersNil() throws {
        let clock = Clock(start)
        let store = RowSparklineStore(history: try history(clock), now: { clock.now })
        XCTAssertNil(store.series(for: "claude"))
    }

    /// The round trip: readings in the file, `note` on the main actor, and a
    /// day of buckets back with the three hours that had something in them.
    @MainActor
    func testNoteBucketsTheLastDay() async throws {
        let clock = Clock(start)
        let file = try history(clock)
        // Three readings, one an hour, ending at `start`. Anything closer than
        // thirty seconds apart is refused by the store's own minimum interval.
        for hoursAgo in [3.0, 2.0, 1.0] {
            file.record(usage(0.4 + hoursAgo / 10, at: start.addingTimeInterval(-hoursAgo * 3600)), for: "claude")
        }
        let store = RowSparklineStore(history: file, now: { clock.now })

        store.note(usage(0.5, at: start), for: "claude")
        let built = await waitForTrace(store)
        let series = try XCTUnwrap(built)

        XCTAssertEqual(series.peaks.count, RowSparklineStore.buckets)
        XCTAssertEqual(series.takenAt, start)
        XCTAssertEqual(
            series.peaks.compactMap { $0 }.count, 3,
            "three hours were recorded and \(series.peaks.compactMap { $0 }.count) came back"
        )
    }

    /// The throttle, asserted at both sides of its own boundary through the
    /// injected clock. A rebuild can only ever change the last bucket, and a
    /// reading landing four minutes after the previous one moves that bucket's
    /// peak by an amount no 13pt column can show.
    @MainActor
    func testARebuildIsThrottledToFiveMinutes() async throws {
        let clock = Clock(start)
        let file = try history(clock)
        file.record(usage(0.4, at: start.addingTimeInterval(-600)), for: "claude")
        let store = RowSparklineStore(history: file, now: { clock.now })

        store.note(usage(0.5, at: start), for: "claude")
        let built = await waitForTrace(store)
        let first = try XCTUnwrap(built)
        XCTAssertEqual(first.takenAt, start)

        clock.advance(RowSparklineStore.minimumRefresh - 1)
        store.note(usage(0.6, at: clock.now), for: "claude")
        await Task.yield()
        XCTAssertEqual(
            store.series(for: "claude")?.takenAt, start,
            "a note 299 seconds after the last rebuild started another one"
        )

        clock.advance(2)
        store.note(usage(0.6, at: clock.now), for: "claude")
        let deadline = Date().addingTimeInterval(2)
        while store.series(for: "claude")?.takenAt == start, Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
        XCTAssertEqual(
            store.series(for: "claude")?.takenAt, start.addingTimeInterval(RowSparklineStore.minimumRefresh + 1),
            "a note 301 seconds after the last rebuild did not start another one"
        )
    }

    /// A window with no cap is never written to the history store at all, so
    /// there is nothing to bucket and asking would be a query guaranteed to come
    /// back empty. The row's slot stays reserved and holds nothing, exactly as
    /// its meter slot does.
    @MainActor
    func testAQuotalessWindowIsNeverCached() async throws {
        let clock = Clock(start)
        let store = RowSparklineStore(history: try history(clock), now: { clock.now })

        store.note(
            UsageData(
                providerID: "claudecode",
                fetchedAt: start,
                primary: UsageMetric(label: "in the last 5h", used: 45_000, limit: 0, unit: "tokens")
            ),
            for: "claudecode"
        )
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertNil(
            store.series(for: "claudecode"),
            "a window with no ceiling was given a cache entry no query can fill"
        )
    }

    /// Sign-out. Slot numbers are reused, so a trace left behind would be
    /// twenty-four hours of somebody else's day drawn under a new account's name.
    @MainActor
    func testForgetClearsTheTrace() async throws {
        let clock = Clock(start)
        let file = try history(clock)
        file.record(usage(0.4, at: start.addingTimeInterval(-600)), for: "claude")
        let store = RowSparklineStore(history: file, now: { clock.now })

        store.note(usage(0.5, at: start), for: "claude")
        let built = await waitForTrace(store)
        XCTAssertNotNil(built)

        store.forget("claude")
        XCTAssertNil(store.series(for: "claude"))
    }

    /// The store's own answer against the synchronous one it stands in front of,
    /// on one seed. `peaks` is the only read a row is ever behind, so if it and
    /// `samples` ever disagreed the panel and the settings window would be
    /// drawing two different days.
    @MainActor
    func testPeaksMatchesTheSynchronousReadOnTheSameSeed() async throws {
        let clock = Clock(start)
        let file = try history(clock)
        for hoursAgo in stride(from: 20.0, through: 1.0, by: -1.0) {
            file.record(usage(hoursAgo / 40, at: start.addingTimeInterval(-hoursAgo * 3600)), for: "claude")
        }
        let series = HistorySeriesID(
            providerID: "claude", windowKey: HistorySeriesID.windowKey(for: "5h window")
        )
        let from = start.addingTimeInterval(-RowSparklineStore.window)

        let asynchronous = await file.peaks(
            for: series, from: from, to: start, count: RowSparklineStore.buckets
        )
        let synchronous = HistoryQuery.buckets(
            file.samples(for: series, since: from),
            from: from, to: start, count: RowSparklineStore.buckets
        )
        XCTAssertEqual(asynchronous, synchronous)
        XCTAssertEqual(asynchronous.compactMap { $0 }.count, 20)
    }
}
