import XCTest
@testable import aibarsCore

/// The four decisions the history view rests on, none of which need a store.
///
/// The tests are mostly about the difference between "no reading" and "a
/// reading of zero", because every way of getting history wrong collapses that
/// distinction: a bucket that fills a gap with zero invents a quiet night, a
/// segment that spans a reset draws a plunge that never happened, and a
/// roll-up that counts readings at the cap instead of crossings of it reports
/// the polling interval rather than the subscription.
///
/// `HistoryQuery` is pure, so there is no clock and nothing to stub; the dates
/// are offsets from one fixed instant and the calendar is always a parameter.
final class HistoryQueryTests: XCTestCase {

    // MARK: - Harness

    /// Somewhere unremarkable, and exactly representable as a Double, so the
    /// bucket arithmetic in the assertions is the same arithmetic the code does.
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(_ percent: Double, at offset: TimeInterval) -> HistorySample {
        HistorySample(at: start.addingTimeInterval(offset), percent: percent)
    }

    private func calendar(_ zone: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone), "\(zone) is not a zone this machine knows")
        return calendar
    }

    private func date(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        _ minute: Int,
        in calendar: Calendar
    ) throws -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return try XCTUnwrap(
            calendar.date(from: components),
            "\(year)-\(month)-\(day) \(hour):\(minute) is not a wall clock time in \(calendar.timeZone.identifier)"
        )
    }

    // MARK: - The sample itself

    /// A percentage arrives from a provider, a decoder, or a test, and none of
    /// the three are trusted. A NaN in particular loses every comparison it
    /// takes part in, so it would survive `max` and become a day's peak.
    func testAPercentageIsClampedAndANonFiniteOneBecomesZero() {
        XCTAssertEqual(HistorySample(at: start, percent: -2).percent, 0)
        XCTAssertEqual(HistorySample(at: start, percent: 0).percent, 0)
        XCTAssertEqual(HistorySample(at: start, percent: 0.5).percent, 0.5)
        XCTAssertEqual(HistorySample(at: start, percent: 1).percent, 1)
        XCTAssertEqual(HistorySample(at: start, percent: 4).percent, 1)
        XCTAssertEqual(HistorySample(at: start, percent: .nan).percent, 0)
        XCTAssertEqual(
            HistorySample(at: start, percent: .infinity).percent, 0,
            "an infinite reading is a broken one, not a full window"
        )
        XCTAssertEqual(HistorySample(at: start, percent: -.infinity).percent, 0)
    }

    /// History outlives the version that wrote it, so what comes back off disk
    /// takes the same clamping the live path does.
    func testAStoredPercentageIsClampedOnTheWayBackIn() throws {
        let stamp = start.timeIntervalSinceReferenceDate
        let json = """
        [{"at":\(stamp),"percent":-3},\
        {"at":\(stamp),"percent":0},\
        {"at":\(stamp),"percent":0.25},\
        {"at":\(stamp),"percent":88}]
        """
        let decoded = try JSONDecoder().decode([HistorySample].self, from: Data(json.utf8))
        XCTAssertEqual(decoded.map(\.percent), [0, 0, 0.25, 1])
    }

    func testAMalformedStoredSampleFailsToDecodeRatherThanArrivingWrong() {
        let broken = [
            #"{"percent":0.5}"#,
            #"{"at":0}"#,
            #"{"at":"soon","percent":0.5}"#,
            #"{"at":0,"percent":"half"}"#,
            #"{"at":0,"percent":null}"#,
            "[]",
            "not json at all"
        ]
        for json in broken {
            XCTAssertThrowsError(
                try JSONDecoder().decode(HistorySample.self, from: Data(json.utf8)),
                "\(json) decoded into a sample"
            )
        }
    }

    func testASampleSurvivesItsOwnRoundTrip() throws {
        let original = HistorySample(at: start.addingTimeInterval(1234.5), percent: 0.75)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(HistorySample.self, from: data), original)
    }

    // MARK: - Buckets

    /// The rule the whole chart hangs on: a bucket nothing landed in is nil.
    func testBucketsOverAnEmptySeriesAreAllNilRatherThanAllZero() {
        let result = HistoryQuery.buckets([], from: start, to: start.addingTimeInterval(100), count: 6)

        XCTAssertEqual(result.count, 6)
        XCTAssertTrue(result.allSatisfy { $0 == nil }, "an unused chart is not a chart of a used-up window")
    }

    func testABucketWithNoSampleStaysNilBetweenNeighboursThatHaveOne() {
        let samples = [
            sample(0.4, at: 5),
            sample(0.6, at: 95)
        ]
        let result = HistoryQuery.buckets(samples, from: start, to: start.addingTimeInterval(100), count: 3)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0], 0.4)
        XCTAssertNil(result[1], "a gap in the record is not a dip in usage")
        XCTAssertEqual(result[2], 0.6)
    }

    /// The distinction the nil exists for: zero is a reading and is kept as one.
    func testABucketHoldingOnlyAZeroReadingIsZeroAndNotNil() {
        let result = HistoryQuery.buckets([sample(0, at: 5)], from: start, to: start.addingTimeInterval(100), count: 2)

        XCTAssertEqual(result[0], 0, "a window observed at zero is a fact the chart should draw")
        XCTAssertNil(result[1])
    }

    func testABucketTakesItsPeakAndNotItsMean() {
        let samples = [
            sample(0.2, at: 1),
            sample(0.9, at: 2),
            sample(0.3, at: 3)
        ]
        let result = HistoryQuery.buckets(samples, from: start, to: start.addingTimeInterval(10), count: 1)

        XCTAssertEqual(result, [0.9], "averaging hides the spike, and the spike is the only thing anyone acted on")
    }

    /// Order is the caller's business, not the bucketing's.
    func testBucketsDoNotCareWhatOrderTheSamplesArriveIn() {
        let samples = [
            sample(0.3, at: 90),
            sample(0.9, at: 10),
            sample(0.1, at: 50)
        ]
        let forwards = HistoryQuery.buckets(samples.sorted { $0.at < $1.at },
                                            from: start, to: start.addingTimeInterval(100), count: 5)
        let shuffled = HistoryQuery.buckets(samples, from: start, to: start.addingTimeInterval(100), count: 5)

        XCTAssertEqual(forwards, shuffled)
        XCTAssertEqual(shuffled, [0.9, nil, 0.1, nil, 0.3])
    }

    /// Half-open everywhere but the end: a sample on a boundary opens the later
    /// bucket, and the newest reading of all lands in the last one rather than
    /// falling off the chart.
    func testBoundarySamplesOpenTheLaterBucketAndTheLastBucketIsClosed() {
        let samples = [
            sample(0.1, at: 0),
            sample(0.2, at: 10),
            sample(0.3, at: 20),
            sample(0.4, at: 100)
        ]
        let result = HistoryQuery.buckets(samples, from: start, to: start.addingTimeInterval(100), count: 10)

        XCTAssertEqual(result[0], 0.1, "a sample on `from` belongs to the first bucket")
        XCTAssertEqual(result[1], 0.2)
        XCTAssertEqual(result[2], 0.3)
        XCTAssertEqual(result[9], 0.4, "the newest reading there is must not fall off the end")
        XCTAssertNil(result[3])
    }

    func testSamplesOutsideTheRangeAreIgnoredRatherThanPinnedToAnEnd() {
        let samples = [
            sample(0.9, at: -1),
            sample(0.8, at: -3600),
            sample(0.7, at: 101),
            sample(0.5, at: 50)
        ]
        let result = HistoryQuery.buckets(samples, from: start, to: start.addingTimeInterval(100), count: 2)

        XCTAssertEqual(result, [nil, 0.5], "a reading from outside the visible span is not a reading inside it")
    }

    func testAnUndividableRequestAnswersEmptyRatherThanARowOfNils() {
        let samples = [sample(0.5, at: 50)]
        let hour = start.addingTimeInterval(3600)

        XCTAssertEqual(HistoryQuery.buckets(samples, from: start, to: hour, count: 0), [])
        XCTAssertEqual(HistoryQuery.buckets(samples, from: start, to: hour, count: -4), [])
        XCTAssertEqual(HistoryQuery.buckets(samples, from: start, to: start, count: 6), [], "an empty span")
        XCTAssertEqual(HistoryQuery.buckets(samples, from: hour, to: start, count: 6), [], "a backwards span")
    }

    /// A range built from a broken date would otherwise reach `Int(offset / step)`
    /// with a NaN in it, and converting a NaN to an Int traps.
    func testABrokenRangeOrTimestampIsRefusedRatherThanCrashing() {
        let broken = Date(timeIntervalSince1970: .nan)
        let good = start.addingTimeInterval(100)

        XCTAssertEqual(HistoryQuery.buckets([sample(0.5, at: 50)], from: broken, to: good, count: 4), [])
        XCTAssertEqual(HistoryQuery.buckets([sample(0.5, at: 50)], from: start, to: broken, count: 4), [])

        let brokenSamples = [
            HistorySample(at: broken, percent: 0.5),
            HistorySample(at: Date(timeIntervalSince1970: .infinity), percent: 0.5),
            HistorySample(at: Date(timeIntervalSince1970: -.infinity), percent: 0.5)
        ]
        let result = HistoryQuery.buckets(brokenSamples, from: start, to: good, count: 4)
        XCTAssertEqual(result, [nil, nil, nil, nil], "a sample with no real timestamp belongs to no bucket")
    }

    func testASingleBucketHoldsThePeakOfTheWholeRange() {
        let samples = (0..<20).map { sample(Double($0) / 20, at: TimeInterval($0) * 5) }
        XCTAssertEqual(HistoryQuery.buckets(samples, from: start, to: start.addingTimeInterval(100), count: 1), [0.95])
    }

    func testTheAnswerIsAlwaysAsLongAsTheCountAskedFor() {
        for count in [1, 2, 7, 24, 365] {
            let result = HistoryQuery.buckets([sample(0.5, at: 1)], from: start,
                                              to: start.addingTimeInterval(100), count: count)
            XCTAssertEqual(result.count, count)
            XCTAssertEqual(result.compactMap { $0 }, [0.5], "one sample should light exactly one bucket")
        }
    }

    // MARK: - Segments

    func testAnEmptySeriesHasNoSegmentsAtAll() {
        XCTAssertTrue(HistoryQuery.segments([]).isEmpty, "no readings is not one empty line")
        XCTAssertTrue(HistoryQuery.segments([], resetDrop: 0).isEmpty)
    }

    func testOneReadingIsOneSegment() {
        let only = sample(0.5, at: 0)
        XCTAssertEqual(HistoryQuery.segments([only]), [[only]])
    }

    func testAGentleDeclineStaysOneSegment() {
        let samples = (0..<10).map { sample(0.9 - Double($0) * 0.05, at: TimeInterval($0) * 300) }
        let result = HistoryQuery.segments(samples)

        XCTAssertEqual(result.count, 1, "five points a reading is a window being spent, not a window rolling over")
        XCTAssertEqual(result.first, samples)
    }

    func testARiseNeverCutsHoweverSteep() {
        let samples = [sample(0.05, at: 0), sample(0.95, at: 300)]
        XCTAssertEqual(HistoryQuery.segments(samples), [samples])
    }

    /// The cut is at or above the drop, so the drop itself cuts. The figures are
    /// exact in binary, because a boundary tested with 0.9 and 0.6 would be
    /// asserting the last bit of a subtraction rather than the rule.
    func testTheCutIsAtTheDropAndNotJustBelowIt() {
        let onTheLine = [sample(0.5, at: 0), sample(0.25, at: 300)]
        XCTAssertEqual(HistoryQuery.segments(onTheLine, resetDrop: 0.25).count, 2, "exactly the drop is a reset")

        let justUnder = [sample(0.5, at: 0), sample(0.265625, at: 300)]
        XCTAssertEqual(HistoryQuery.segments(justUnder, resetDrop: 0.25).count, 1, "a hair under the drop is not")
    }

    func testASeriesThatResetsTwiceYieldsThreeNonEmptySegments() {
        let samples = [
            sample(0.20, at: 0),
            sample(0.60, at: 300),
            sample(0.95, at: 600),
            sample(0.05, at: 900),
            sample(0.40, at: 1200),
            sample(0.90, at: 1500),
            sample(0.10, at: 1800),
            sample(0.30, at: 2100)
        ]
        let result = HistoryQuery.segments(samples)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.count), [3, 3, 2])
        XCTAssertFalse(result.contains { $0.isEmpty }, "an empty segment is a line with nothing to draw")
        XCTAssertEqual(result.flatMap { $0 }, samples, "cutting a series must not lose or reorder a reading")
        for segment in result {
            XCTAssertEqual(segment.map(\.at), segment.map(\.at).sorted(), "each segment runs forwards")
        }
    }

    /// A reset lands on the first reading after it, not the last before it: the
    /// old window's line ends at its peak and the new one starts at the floor.
    func testTheReadingAfterAResetOpensTheNewSegment() throws {
        let samples = [sample(0.9, at: 0), sample(0.1, at: 300), sample(0.2, at: 600)]
        let result = HistoryQuery.segments(samples)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(try XCTUnwrap(result.first).map(\.percent), [0.9])
        XCTAssertEqual(try XCTUnwrap(result.last).map(\.percent), [0.1, 0.2])
    }

    func testSegmentsSortTheSeriesBeforeCuttingIt() {
        let samples = [
            sample(0.10, at: 900),
            sample(0.90, at: 600),
            sample(0.20, at: 0),
            sample(0.55, at: 300)
        ]
        let result = HistoryQuery.segments(samples)

        XCTAssertEqual(result.map { $0.map(\.percent) }, [[0.20, 0.55, 0.90], [0.10]])
    }

    /// A drop of zero asks for a cut at every reading that did not rise, which is
    /// nobody's intent, and a negative one asks for something incoherent.
    func testADropOfZeroOrLessCutsNothing() {
        let samples = [sample(0.9, at: 0), sample(0.1, at: 300), sample(0.05, at: 600)]

        XCTAssertEqual(HistoryQuery.segments(samples, resetDrop: 0).count, 1)
        XCTAssertEqual(HistoryQuery.segments(samples, resetDrop: -0.5).count, 1)
        XCTAssertEqual(HistoryQuery.segments(samples, resetDrop: 0), [samples])
    }

    func testADropNoReadingCanReachCutsNothingEither() {
        let samples = [sample(1, at: 0), sample(0, at: 300), sample(1, at: 600)]
        XCTAssertEqual(HistoryQuery.segments(samples, resetDrop: 2).count, 1)
        XCTAssertEqual(HistoryQuery.segments(samples, resetDrop: .infinity).count, 1)
    }

    /// The default is deliberately looser than the forecast's, because history
    /// is sampled at whatever spacing the mac was awake for.
    func testTheDefaultDropSitsAboveWhatARollingWindowCanShedBetweenReadings() {
        let samples = [sample(0.80, at: 0), sample(0.55, at: 3600)]
        XCTAssertEqual(
            HistoryQuery.segments(samples).count, 1,
            "twenty-five points across an hour is a rolling window, not a reset"
        )
    }

    // MARK: - The daily roll-up

    func testAnEmptySeriesRollsUpToNoDays() throws {
        XCTAssertTrue(HistoryQuery.rollUp([], calendar: try calendar("UTC")).isEmpty)
    }

    func testAHandBuiltDayReportsItsPeakMeanCapHitsAndCount() throws {
        let utc = try calendar("UTC")
        let day = try date(2026, 3, 12, 0, 0, in: utc)
        let samples = [
            HistorySample(at: day.addingTimeInterval(3600), percent: 0.10),
            HistorySample(at: day.addingTimeInterval(7200), percent: 0.50),
            HistorySample(at: day.addingTimeInterval(10800), percent: 1.00),
            HistorySample(at: day.addingTimeInterval(14400), percent: 0.20)
        ]

        let result = HistoryQuery.rollUp(samples, calendar: utc)

        XCTAssertEqual(result.count, 1)
        let only = try XCTUnwrap(result.first)
        XCTAssertEqual(only.day, day)
        XCTAssertEqual(only.peak, 1.0)
        XCTAssertEqual(only.mean, 0.45, accuracy: 1e-12)
        XCTAssertEqual(only.capHits, 1)
        XCTAssertEqual(only.samples, 4)
    }

    func testASingleReadingIsItsOwnPeakAndMean() throws {
        let utc = try calendar("UTC")
        let result = HistoryQuery.rollUp([sample(0.3, at: 0)], calendar: utc)

        let only = try XCTUnwrap(result.first)
        XCTAssertEqual(only.peak, 0.3)
        XCTAssertEqual(only.mean, 0.3)
        XCTAssertEqual(only.samples, 1)
        XCTAssertEqual(only.capHits, 0)
        XCTAssertEqual(only.day, utc.startOfDay(for: start))
    }

    /// A day of untouched quota is a day with readings, not a day that is absent.
    func testADayOfZeroesIsStillADay() throws {
        let samples = [sample(0, at: 0), sample(0, at: 3600)]
        let result = HistoryQuery.rollUp(samples, calendar: try calendar("UTC"))

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.peak, 0)
        XCTAssertEqual(result.first?.mean, 0)
        XCTAssertEqual(result.first?.samples, 2)
    }

    /// 0.99 rather than 1.0: a provider reporting 4 999 of 5 000 has stopped
    /// being useful, and demanding exactly the cap makes the figure depend on how
    /// the provider rounds its own arithmetic.
    func testTheCapIsReachedAtNinetyNineAndNotAtNinetyEight() throws {
        let utc = try calendar("UTC")

        XCTAssertEqual(HistoryQuery.rollUp([sample(HistoryQuery.capThreshold, at: 0)], calendar: utc).first?.capHits, 1)
        XCTAssertEqual(HistoryQuery.rollUp([sample(0.99, at: 0)], calendar: utc).first?.capHits, 1)
        XCTAssertEqual(HistoryQuery.rollUp([sample(0.98, at: 0)], calendar: utc).first?.capHits, 0)
        XCTAssertEqual(HistoryQuery.rollUp([sample(1, at: 0)], calendar: utc).first?.capHits, 1)
    }

    /// Counted as crossings, so a fast refresh and a slow one describe the same
    /// afternoon the same way.
    func testCapHitsCountCrossingsRatherThanReadingsAtTheCap() throws {
        let utc = try calendar("UTC")
        let pinned = (0..<12).map { sample(1, at: TimeInterval($0) * 300) }

        XCTAssertEqual(HistoryQuery.rollUp(pinned, calendar: utc).first?.capHits, 1)

        let twice = [
            sample(0.5, at: 0),
            sample(1.0, at: 300),
            sample(1.0, at: 600),
            sample(0.2, at: 900),
            sample(0.7, at: 1200),
            sample(0.99, at: 1500)
        ]
        XCTAssertEqual(HistoryQuery.rollUp(twice, calendar: utc).first?.capHits, 2)
    }

    /// The crossing has to be seen next to the reading before it, which may be
    /// yesterday's — so a window still pinned at midnight is not a fresh hit.
    func testACapCarriedOverMidnightIsNotCountedTwice() throws {
        let utc = try calendar("UTC")
        let midnight = try date(2026, 3, 12, 0, 0, in: utc)
        let samples = [
            HistorySample(at: midnight.addingTimeInterval(-3600), percent: 0.5),
            HistorySample(at: midnight.addingTimeInterval(-600), percent: 1.0),
            HistorySample(at: midnight.addingTimeInterval(600), percent: 1.0),
            HistorySample(at: midnight.addingTimeInterval(3600), percent: 1.0)
        ]

        let result = HistoryQuery.rollUp(samples, calendar: utc)

        XCTAssertEqual(result.map(\.capHits), [1, 0], "the second day inherited a cap it did not cross")
        XCTAssertEqual(result.map(\.samples), [2, 2])
    }

    /// The alternative — no hit at all — is worse: a day spent at the cap that
    /// reports nothing is the day the heatmap exists to show.
    func testASeriesThatOpensAtTheCapCountsOneHit() throws {
        let result = HistoryQuery.rollUp([sample(1, at: 0), sample(1, at: 300)], calendar: try calendar("UTC"))
        XCTAssertEqual(result.first?.capHits, 1)
    }

    func testDaysComeBackOldestFirstAndEmptyOnesAreAbsentRatherThanZeroFilled() throws {
        let utc = try calendar("UTC")
        let first = try date(2026, 3, 1, 12, 0, in: utc)
        let samples = [
            HistorySample(at: first.addingTimeInterval(4 * 86_400), percent: 0.4),
            HistorySample(at: first, percent: 0.2),
            HistorySample(at: first.addingTimeInterval(86_400), percent: 0.3)
        ]

        let result = HistoryQuery.rollUp(samples, calendar: utc)

        XCTAssertEqual(result.map(\.peak), [0.2, 0.3, 0.4])
        XCTAssertEqual(result.count, 3, "the three days between were not observed, so they are not reported")
        XCTAssertEqual(result.map(\.day), result.map(\.day).sorted())
    }

    /// The cap count depends on the order the readings are walked in, so the
    /// roll-up sorts first rather than trusting the caller.
    func testTheRollUpSortsBeforeItCounts() throws {
        let utc = try calendar("UTC")
        let samples = [
            sample(0.5, at: 0),
            sample(1.0, at: 300),
            sample(0.4, at: 600),
            sample(1.0, at: 900)
        ]

        XCTAssertEqual(
            HistoryQuery.rollUp(samples.reversed(), calendar: utc),
            HistoryQuery.rollUp(samples, calendar: utc)
        )
        XCTAssertEqual(HistoryQuery.rollUp(samples.reversed(), calendar: utc).first?.capHits, 2)
    }

    /// Spring forward, where 02:00 does not exist. All three readings are on the
    /// clock the user was actually looking at, and the day boundary is the one
    /// the given calendar draws — not a fixed 86 400 seconds.
    func testSamplesEitherSideOfADSTChangeLandInTheDaysTheCalendarSays() throws {
        let newYork = try calendar("America/New_York")
        let beforeMidnight = try date(2026, 3, 7, 23, 30, in: newYork)
        let beforeTheChange = try date(2026, 3, 8, 1, 30, in: newYork)
        let afterTheChange = try date(2026, 3, 8, 3, 30, in: newYork)
        let lateOnTheShortDay = try date(2026, 3, 8, 23, 30, in: newYork)

        XCTAssertEqual(
            afterTheChange.timeIntervalSince(beforeTheChange), 3600, accuracy: 1e-9,
            "01:30 to 03:30 is one real hour, which is what makes this a test of the change"
        )

        let samples = [
            HistorySample(at: beforeMidnight, percent: 0.2),
            HistorySample(at: beforeTheChange, percent: 0.4),
            HistorySample(at: afterTheChange, percent: 0.6),
            HistorySample(at: lateOnTheShortDay, percent: 0.8)
        ]

        let local = HistoryQuery.rollUp(samples, calendar: newYork)
        XCTAssertEqual(local.count, 2)
        XCTAssertEqual(local.map(\.day), [
            newYork.startOfDay(for: beforeMidnight),
            newYork.startOfDay(for: beforeTheChange)
        ])
        XCTAssertEqual(local.map(\.samples), [1, 3])
        XCTAssertEqual(local.map(\.peak), [0.2, 0.8])

        // The same four instants, split by a calendar that has no DST at all:
        // a different answer, and the point of passing the calendar in.
        let utc = HistoryQuery.rollUp(samples, calendar: try calendar("UTC"))
        XCTAssertEqual(utc.map(\.samples), [3, 1])
    }

    // MARK: - Series identity

    func testASeriesIDSurvivesItsStorageKey() throws {
        let ids = [
            HistorySeriesID(providerID: "claude", windowKey: "5h"),
            HistorySeriesID(providerID: "claude#2", windowKey: "weekly"),
            HistorySeriesID(providerID: "a.b", windowKey: "c.d"),
            HistorySeriesID(providerID: "100%", windowKey: "50%"),
            HistorySeriesID(providerID: "open router", windowKey: "credits/month"),
            HistorySeriesID(providerID: "клод", windowKey: "окно"),
            HistorySeriesID(providerID: "", windowKey: ""),
            HistorySeriesID(providerID: "aibars.forecast.samples.claude", windowKey: "5h")
        ]

        for id in ids {
            XCTAssertEqual(HistorySeriesID(storageKey: id.storageKey), id, "\(id.storageKey) did not come back")
        }
    }

    /// The reason the halves are encoded rather than joined: an account id
    /// already carries "#", a window key is whoever-wired-it-up's choice, and a
    /// raw join is one unlucky string away from two series sharing a row.
    func testTwoSeriesThatWouldCollideUnderARawJoinDoNot() {
        let left = HistorySeriesID(providerID: "a.b", windowKey: "c")
        let right = HistorySeriesID(providerID: "a", windowKey: "b.c")

        XCTAssertNotEqual(left.storageKey, right.storageKey)
        XCTAssertEqual(HistorySeriesID(storageKey: left.storageKey), left)
        XCTAssertEqual(HistorySeriesID(storageKey: right.storageKey), right)
    }

    func testAStorageKeyEscapesEverythingThatIsNotALetterOrADigit() {
        XCTAssertEqual(HistorySeriesID(providerID: "a.b", windowKey: "c").storageKey, "a%2Eb.c")
        XCTAssertEqual(HistorySeriesID(providerID: "claude#2", windowKey: "5h").storageKey, "claude%232.5h")
        XCTAssertEqual(HistorySeriesID(providerID: "", windowKey: "").storageKey, ".")
    }

    /// Callers enumerate stored keys to find out what history exists, so a key
    /// from another shape has to read as unreadable rather than parse into a
    /// series that never existed.
    func testAKeyThisTypeDidNotWriteIsRefused() {
        let refused = [
            "",
            "claude",
            "claude.5h.weekly",
            "a.b.c.d",
            // A hand-joined key: the provider id carries the separator, which the
            // encoder would have escaped and a naive writer did not.
            "aibars.forecast.claude",
            // Percent signs that decode to nothing.
            "%zz.5h",
            "claude.%",
            "%.%"
        ]

        for key in refused {
            XCTAssertNil(HistorySeriesID(storageKey: key), "\(key) parsed into a series")
        }
    }

    func testASeriesIDSurvivesACodableRoundTrip() throws {
        let id = HistorySeriesID(providerID: "claude#2", windowKey: "weekly")
        let data = try JSONEncoder().encode(id)

        XCTAssertEqual(try JSONDecoder().decode(HistorySeriesID.self, from: data), id)
        XCTAssertThrowsError(try JSONDecoder().decode(HistorySeriesID.self, from: Data(#"{"providerID":"a"}"#.utf8)))
    }

    func testTwoSeriesOfOneAccountAreDifferentSeries() {
        let short = HistorySeriesID(providerID: "claude", windowKey: "5h")
        let weekly = HistorySeriesID(providerID: "claude", windowKey: "weekly")

        XCTAssertNotEqual(short, weekly)
        XCTAssertEqual(Set([short, weekly, short]).count, 2)
    }
}
