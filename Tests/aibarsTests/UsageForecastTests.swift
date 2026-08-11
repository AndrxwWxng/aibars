import XCTest
@testable import aibarsCore

/// The forecast is the one number in the app the provider did not give us, so
/// it is the one number we can be wrong about on our own. These tests pin the
/// refusals as hard as the answers: a parked account claiming a trajectory, or
/// a window reset read as a collapse in usage, is worse than saying nothing.
final class UsageForecastTests: XCTestCase {
    /// Fixed, so a slow machine cannot move the answers between the arrange and
    /// the assert.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Builders

    private func series(_ points: [(minutesAgo: Double, percent: Double)]) -> [UsageSample] {
        points.map { UsageSample(at: now.addingTimeInterval(-$0.minutesAgo * 60), percent: $0.percent) }
    }

    /// A straight climb that arrives at `endPercent` exactly now. Exactly linear
    /// input means any correct weighting recovers the slope exactly, so the
    /// weights are not what is under test here.
    private func climb(
        endingAt endPercent: Double,
        pointsPerHour: Double,
        spanMinutes: Int,
        step: Int = 5
    ) -> [UsageSample] {
        stride(from: spanMinutes, through: 0, by: -step).map { minutesAgo in
            UsageSample(
                at: now.addingTimeInterval(-Double(minutesAgo) * 60),
                percent: endPercent - pointsPerHour / 100 * (Double(minutesAgo) / 60)
            )
        }
    }

    private func capDate(_ outcome: Outcome) -> Date? {
        guard case .capsAt(let date) = outcome else { return nil }
        return date
    }

    private func resetDate(_ outcome: Outcome) -> Date? {
        guard case .resetsFirst(let date) = outcome else { return nil }
        return date
    }

    /// Plain least squares over the same points, for the recency test to beat.
    private func unweightedSlope(_ samples: [UsageSample]) -> Double {
        let sorted = samples.sorted { $0.at < $1.at }
        guard let origin = sorted.first else { return 0 }
        let times = sorted.map { $0.at.timeIntervalSince(origin.at) }
        let percents = sorted.map(\.percent)
        let count = Double(sorted.count)
        let meanTime = times.reduce(0, +) / count
        let meanPercent = percents.reduce(0, +) / count

        var variance = 0.0
        var covariance = 0.0
        for index in sorted.indices {
            let centred = times[index] - meanTime
            variance += centred * centred
            covariance += centred * (percents[index] - meanPercent)
        }
        return variance > 0 ? covariance / variance : 0
    }

    // MARK: - Sample clamping

    func testPercentIsClampedIntoRange() {
        XCTAssertEqual(UsageSample(at: now, percent: -0.4).percent, 0)
        XCTAssertEqual(UsageSample(at: now, percent: 0).percent, 0)
        XCTAssertEqual(UsageSample(at: now, percent: 1).percent, 1)
        XCTAssertEqual(UsageSample(at: now, percent: 1.12).percent, 1, "112% of a soft limit must not sit behind the cap")
    }

    /// A NaN wins nothing and loses nothing under comparison, so `min`/`max`
    /// would pass it straight through and it would reach the divide.
    func testNonFinitePercentsBecomeZero() {
        XCTAssertEqual(UsageSample(at: now, percent: .nan).percent, 0)
        XCTAssertEqual(UsageSample(at: now, percent: .infinity).percent, 0)
        XCTAssertEqual(UsageSample(at: now, percent: -.infinity).percent, 0)
        XCTAssertEqual(UsageSample(at: now, percent: .signalingNaN).percent, 0)
    }

    func testDecodingClampsToo() throws {
        let json = Data(#"{"at": 0, "percent": 5}"#.utf8)
        let sample = try JSONDecoder().decode(UsageSample.self, from: json)
        XCTAssertEqual(sample.percent, 1, "a file on disk is untrusted input like any other")
    }

    func testRoundTripKeepsAValidSample() throws {
        let sample = UsageSample(at: now, percent: 0.42)
        let restored = try JSONDecoder().decode(UsageSample.self, from: JSONEncoder().encode(sample))
        XCTAssertEqual(restored, sample)
    }

    // MARK: - Trimming

    func testTrimmingKeepsTheWindowAndDropsWhatIsOutsideIt() {
        let samples = series([
            (40, 0.1), (31, 0.2), (30, 0.3), (10, 0.4), (0, 0.5),
        ])
        let kept = UsageForecast.trimmed(samples, now: now).map(\.percent)
        XCTAssertEqual(kept, [0.3, 0.4, 0.5], "the 30 minute edge is inside the window, anything older is not")
    }

    /// A clock that jumped would otherwise hand the fit a negative arm.
    func testFutureSamplesAreDropped() {
        let samples = series([(20, 0.2), (10, 0.3), (0, 0.4), (-5, 0.9)])
        XCTAssertEqual(UsageForecast.trimmed(samples, now: now).map(\.percent), [0.2, 0.3, 0.4])
    }

    func testTrimmingSortsUnorderedInput() {
        let samples = series([(0, 0.4), (20, 0.2), (10, 0.3)])
        XCTAssertEqual(UsageForecast.trimmed(samples, now: now).map(\.percent), [0.2, 0.3, 0.4])
    }

    func testEmptyAndTinyInputTrimToThemselves() {
        XCTAssertTrue(UsageForecast.trimmed([], now: now).isEmpty)
        XCTAssertEqual(UsageForecast.trimmed(series([(1, 0.5)]), now: now).count, 1)
    }

    func testTheResetDropBoundary() {
        // 0.20 exactly is a reset; a shade under it is usage going backwards.
        let atThreshold = series([(25, 0.9), (20, 0.7), (10, 0.72), (0, 0.74)])
        XCTAssertEqual(UsageForecast.trimmed(atThreshold, now: now).count, 3)

        let underThreshold = series([(25, 0.9), (20, 0.71), (10, 0.72), (0, 0.74)])
        XCTAssertEqual(UsageForecast.trimmed(underThreshold, now: now).count, 4)
    }

    // MARK: - Refusals

    func testTooFewSamplesGiveNoProjection() {
        XCTAssertNil(UsageForecast.project([], now: now, resetAt: nil))
        XCTAssertNil(UsageForecast.project(series([(10, 0.4)]), now: now, resetAt: nil))
        XCTAssertNil(
            UsageForecast.project(series([(10, 0.4), (0, 0.6)]), now: now, resetAt: nil),
            "two readings are a line through anything"
        )
    }

    func testASpanTooShortToFitGivesNoProjection() {
        XCTAssertNil(
            UsageForecast.project(series([(4, 0.40), (2, 0.55), (0, 0.70)]), now: now, resetAt: nil),
            "four minutes of samples would read a pause for coffee as a slope"
        )
    }

    /// Three samples over exactly five minutes is the smallest fit allowed, and
    /// it has to be allowed or the boundary is off by one refusal.
    func testTheMinimumFitIsAccepted() throws {
        let samples = series([(5, 0.40), (2.5, 0.45), (0, 0.50)])
        let projection = try XCTUnwrap(UsageForecast.project(samples, now: now, resetAt: nil))
        XCTAssertEqual(projection.sampleCount, 3)
        XCTAssertEqual(projection.span, 300, accuracy: 0.001)
    }

    /// The mac slept. The slope through those samples is real but it describes a
    /// session that has already ended.
    func testAStaleTailGivesNoProjectionHoweverSteepItIs() {
        let asleep = series([(29, 0.20), (25, 0.50), (20, 0.80)])
        XCTAssertNil(UsageForecast.project(asleep, now: now, resetAt: nil))
    }

    func testEverythingOlderThanTheWindowGivesNoProjection() {
        let old = series([(70, 0.2), (60, 0.3), (50, 0.4), (40, 0.5)])
        XCTAssertNil(UsageForecast.project(old, now: now, resetAt: nil), "nothing survives the trim, so there is nothing to fit")
    }

    func testTheStalenessBoundary() throws {
        let justFresh = series([(27, 0.30), (21, 0.40), (15, 0.50)])
        XCTAssertNotNil(UsageForecast.project(justFresh, now: now, resetAt: nil), "15 minutes old is still inside the limit")

        let justStale = series([(28, 0.30), (22, 0.40), (16, 0.50)])
        XCTAssertNil(UsageForecast.project(justStale, now: now, resetAt: nil))
    }

    /// Every sample landing on one instant leaves no slope to measure, and the
    /// interesting part is that it comes back empty-handed instead of dividing
    /// by zero.
    func testIdenticalTimestampsGiveNoProjection() {
        let stacked = (0..<5).map { _ in UsageSample(at: now, percent: 0.5) }
        XCTAssertNil(UsageForecast.project(stacked, now: now, resetAt: nil))
    }

    func testDuplicateTimestampsAreSurvivable() throws {
        let samples = series([(20, 0.30), (20, 0.31), (20, 0.32), (10, 0.40), (0, 0.50)])
        let projection = try XCTUnwrap(UsageForecast.project(samples, now: now, resetAt: nil))
        XCTAssertTrue(projection.pointsPerHour.isFinite)
        XCTAssertGreaterThan(projection.pointsPerHour, 0)
    }

    func testNonFiniteInputCannotPoisonTheFit() throws {
        let poisoned = series([(30, .nan), (20, .infinity), (10, 0.5), (0, 0.9)])
        let projection = try XCTUnwrap(UsageForecast.project(poisoned, now: now, resetAt: nil))
        XCTAssertTrue(projection.pointsPerHour.isFinite, "the clamp has to hold all the way through the fit")

        // Nothing but NaNs is a flat line at zero, which is a parked account.
        let allNaN = series([(30, .nan), (20, .nan), (10, .nan), (0, .nan)])
        let flat = try XCTUnwrap(UsageForecast.project(allNaN, now: now, resetAt: nil))
        XCTAssertEqual(flat.outcome, .idle)
        XCTAssertEqual(flat.pointsPerHour, 0, accuracy: 1e-9)
    }

    // MARK: - Outcomes

    func testAParkedAccountClaimsNoTrajectory() throws {
        let flat = series((0...8).map { (minutesAgo: Double($0) * 5, percent: 0.42) })
        let projection = try XCTUnwrap(UsageForecast.project(flat, now: now, resetAt: nil))

        XCTAssertEqual(projection.outcome, .idle)
        XCTAssertEqual(projection.pointsPerHour, 0, accuracy: 1e-9)
        XCTAssertNil(UsageForecast.phrase(for: projection, now: now), "an idle meter has nothing to say")
        XCTAssertNil(UsageForecast.shortPhrase(for: projection, now: now))
    }

    func testASteadyClimbArrivesWhenTheArithmeticSaysItDoes() throws {
        // 50% left at 10 points an hour is five hours.
        let samples = climb(endingAt: 0.5, pointsPerHour: 10, spanMinutes: 30)
        let projection = try XCTUnwrap(UsageForecast.project(samples, now: now, resetAt: nil))

        XCTAssertEqual(projection.pointsPerHour, 10, accuracy: 0.01)
        let eta = try XCTUnwrap(capDate(projection.outcome))
        XCTAssertEqual(eta.timeIntervalSince(now), 5 * 3600, accuracy: 60)
        XCTAssertEqual(projection.sampleCount, 7)
        XCTAssertEqual(projection.span, 1800, accuracy: 0.001)
    }

    /// The whole reason the reset scan exists: a rolling window that has just
    /// turned over looks like usage falling off a cliff, and fitting through it
    /// reads a fresh window as a recovery.
    func testAWindowResetDiscardsEveryPreDropSample() throws {
        let samples = series([
            (30, 0.88), (25, 0.885), (20, 0.89),
            (15, 0.04), (10, 0.05), (5, 0.06), (0, 0.07),
        ])
        let projection = try XCTUnwrap(UsageForecast.project(samples, now: now, resetAt: nil))

        XCTAssertEqual(projection.sampleCount, 4, "only the post-reset leg is allowed into the fit")
        XCTAssertEqual(projection.span, 900, accuracy: 0.001)
        XCTAssertEqual(projection.pointsPerHour, 12, accuracy: 0.01)

        // 93 points left at 12 an hour. Fitting the whole series would have read
        // the drop as a steep fall and reported no arrival at all.
        let eta = try XCTUnwrap(capDate(projection.outcome))
        XCTAssertEqual(eta.timeIntervalSince(now), 7.75 * 3600, accuracy: 60)
        XCTAssertGreaterThan(eta.timeIntervalSince(now), 3 * 3600, "this is not the pre-reset arrival date")
    }

    /// A burst that started eight minutes ago has to move the estimate, or the
    /// forecast is always half an hour behind the person using the app.
    func testRecencyWeightingProjectsSoonerThanAFlatFit() throws {
        let samples = series([
            (28, 0.30), (24, 0.30), (20, 0.30), (16, 0.30), (12, 0.30), (8, 0.30),
            (4, 0.40), (0, 0.50),
        ])
        let projection = try XCTUnwrap(UsageForecast.project(samples, now: now, resetAt: nil))
        let weightedEta = try XCTUnwrap(capDate(projection.outcome))

        let flat = unweightedSlope(samples)
        XCTAssertGreaterThan(flat, 0)
        let unweightedEta = now.addingTimeInterval((1 - 0.5) / flat)

        XCTAssertLessThan(
            weightedEta, unweightedEta,
            "the last eight minutes have to count for more than the twenty flat ones before them"
        )
        XCTAssertGreaterThan(projection.pointsPerHour, flat * 3600 * 100)
    }

    func testAFallingSeriesReportsNoArrival() throws {
        // Steps of four points, well under the drop that would read as a reset.
        let samples = series([(30, 0.90), (24, 0.86), (18, 0.82), (12, 0.78), (6, 0.74), (0, 0.70)])
        let projection = try XCTUnwrap(UsageForecast.project(samples, now: now, resetAt: nil))

        XCTAssertEqual(projection.outcome, .falling)
        XCTAssertEqual(projection.pointsPerHour, -40, accuracy: 0.01)
        XCTAssertNil(UsageForecast.phrase(for: projection, now: now))
    }

    /// Either side of the point where the slope stops being noise. Both answers
    /// are silent to the user; they are not the same answer.
    func testTheNoiseFloorBoundary() throws {
        let creeping = climb(endingAt: 0.5, pointsPerHour: 0.04, spanMinutes: 30)
        XCTAssertEqual(try XCTUnwrap(UsageForecast.project(creeping, now: now, resetAt: nil)).outcome, .idle)

        let rising = climb(endingAt: 0.5, pointsPerHour: 0.06, spanMinutes: 30)
        XCTAssertEqual(try XCTUnwrap(UsageForecast.project(rising, now: now, resetAt: nil)).outcome, .beyondHorizon)

        let drifting = climb(endingAt: 0.5, pointsPerHour: -0.04, spanMinutes: 30)
        XCTAssertEqual(try XCTUnwrap(UsageForecast.project(drifting, now: now, resetAt: nil)).outcome, .idle)

        let receding = climb(endingAt: 0.5, pointsPerHour: -0.06, spanMinutes: 30)
        XCTAssertEqual(try XCTUnwrap(UsageForecast.project(receding, now: now, resetAt: nil)).outcome, .falling)
    }

    func testAnArrivalPastTheHorizonIsNotClaimed() throws {
        let samples = climb(endingAt: 0.1, pointsPerHour: 0.1, spanMinutes: 30)
        let projection = try XCTUnwrap(UsageForecast.project(samples, now: now, resetAt: nil))

        XCTAssertEqual(projection.outcome, .beyondHorizon, "900 hours out is arithmetic, not a forecast")
        XCTAssertGreaterThan(projection.pointsPerHour, 0)
        XCTAssertNil(UsageForecast.phrase(for: projection, now: now))
        XCTAssertNil(UsageForecast.shortPhrase(for: projection, now: now))
    }

    /// Already at the cap: the arrival date is the reading, not a date in the
    /// future, and there is nothing left to divide by the slope.
    func testAMeterAlreadyAtTheCapReportsTheReading() throws {
        let samples = series([(20, 0.94), (10, 0.97), (0, 1.0)])
        let projection = try XCTUnwrap(UsageForecast.project(samples, now: now, resetAt: nil))

        XCTAssertEqual(capDate(projection.outcome), now)
        XCTAssertNil(UsageForecast.phrase(for: projection, now: now), "a cap already reached is not a forecast")
    }

    // MARK: - Resets

    func testAResetThatLandsFirstWinsOverTheArrivalDate() throws {
        let samples = climb(endingAt: 0.25, pointsPerHour: 10, spanMinutes: 30)
        let reset = now.addingTimeInterval(30 * 60)
        let projection = try XCTUnwrap(UsageForecast.project(samples, now: now, resetAt: reset))

        XCTAssertEqual(resetDate(projection.outcome), reset)
    }

    func testAResetAfterTheArrivalDateIsIgnored() throws {
        let samples = climb(endingAt: 0.5, pointsPerHour: 10, spanMinutes: 30)
        let projection = try XCTUnwrap(
            UsageForecast.project(samples, now: now, resetAt: now.addingTimeInterval(9 * 3600))
        )
        XCTAssertNotNil(capDate(projection.outcome), "you cap in five hours; the reset in nine is not the news")
    }

    func testAResetInThePastIsIgnored() throws {
        let samples = climb(endingAt: 0.5, pointsPerHour: 10, spanMinutes: 30)
        let stale = try XCTUnwrap(
            UsageForecast.project(samples, now: now, resetAt: now.addingTimeInterval(-60))
        )
        XCTAssertNotNil(capDate(stale.outcome))

        let onTheDot = try XCTUnwrap(UsageForecast.project(samples, now: now, resetAt: now))
        XCTAssertNotNil(capDate(onTheDot.outcome), "a reset happening exactly now is behind us, not ahead")
    }

    /// A reset beats an arrival date days away, but only if the reset itself is
    /// inside the horizon — otherwise both dates are guesses and neither is told.
    func testAResetBeyondTheHorizonDoesNotRescueAFarArrival() throws {
        let samples = climb(endingAt: 0.1, pointsPerHour: 0.1, spanMinutes: 30)
        let projection = try XCTUnwrap(
            UsageForecast.project(samples, now: now, resetAt: now.addingTimeInterval(13 * 3600))
        )
        XCTAssertEqual(projection.outcome, .beyondHorizon)
    }

    func testAResetInsideTheHorizonBeatsAnArrivalOutsideIt() throws {
        let samples = climb(endingAt: 0.1, pointsPerHour: 0.1, spanMinutes: 30)
        let reset = now.addingTimeInterval(2 * 3600)
        let projection = try XCTUnwrap(UsageForecast.project(samples, now: now, resetAt: reset))
        XCTAssertEqual(resetDate(projection.outcome), reset)
    }

    // MARK: - Copy

    private func projection(_ outcome: Outcome) -> UsageProjection {
        UsageProjection(outcome: outcome, pointsPerHour: 12, sampleCount: 6, span: 1800)
    }

    private func capsIn(_ seconds: TimeInterval) -> String? {
        UsageForecast.phrase(for: projection(.capsAt(now.addingTimeInterval(seconds))), now: now)
    }

    func testDurationsReadTheWayAPersonWouldSayThem() {
        XCTAssertEqual(capsIn(90 * 60), "on pace to cap in 1h 30m")
        XCTAssertEqual(capsIn(3600), "on pace to cap in 1h", "an exact hour drops the empty minutes")
        XCTAssertEqual(capsIn(45 * 60), "on pace to cap in 45m")
        XCTAssertEqual(capsIn(11 * 3600 + 59 * 60), "on pace to cap in 11h 59m")
    }

    /// "in 0m" is the one output that makes the whole feature look broken.
    func testAlmostThereFloorsAtUnderAMinute() {
        XCTAssertEqual(capsIn(1), "on pace to cap in under a minute")
        XCTAssertEqual(capsIn(29), "on pace to cap in under a minute")
        XCTAssertEqual(capsIn(31), "on pace to cap in 1m")
        XCTAssertEqual(capsIn(59 * 60 + 40), "on pace to cap in 1h", "rounding up to sixty minutes is an hour, not 0m")

        for seconds in stride(from: 1.0, through: 12 * 3600, by: 37) {
            guard let phrase = capsIn(seconds) else { return XCTFail("no phrase at \(seconds)s") }
            XCTAssertFalse(phrase.contains("0m,"), phrase)
            XCTAssertFalse(phrase.hasSuffix(" 0m"), phrase)
            XCTAssertFalse(phrase.contains("in 0m"), phrase)
        }
    }

    func testADateThatHasPassedSaysNothing() {
        XCTAssertNil(capsIn(-60))
        XCTAssertNil(capsIn(0), "a cap arriving exactly now is not something to warn about")
        XCTAssertNil(UsageForecast.phrase(for: projection(.resetsFirst(now)), now: now))
        XCTAssertNil(UsageForecast.shortPhrase(for: projection(.resetsFirst(now.addingTimeInterval(-1))), now: now))
    }

    func testTheSilentOutcomesStaySilentInBothLengths() {
        for outcome in [Outcome.idle, .falling, .beyondHorizon] {
            XCTAssertNil(UsageForecast.phrase(for: projection(outcome), now: now), "\(outcome)")
            XCTAssertNil(UsageForecast.shortPhrase(for: projection(outcome), now: now), "\(outcome)")
        }
    }

    func testAResetIsAlwaysNamedWhenItLandsFirst() throws {
        let long = try XCTUnwrap(
            UsageForecast.phrase(for: projection(.resetsFirst(now.addingTimeInterval(25 * 60))), now: now)
        )
        XCTAssertEqual(long, "resets in 25m, you'll finish under")

        let short = try XCTUnwrap(
            UsageForecast.shortPhrase(for: projection(.resetsFirst(now.addingTimeInterval(25 * 60))), now: now)
        )
        XCTAssertEqual(short, "won't cap before reset")
        XCTAssertTrue(short.contains("reset"), "the short form still has to say why it is not capping")
    }

    func testTheShortFormFits() throws {
        let short = try XCTUnwrap(
            UsageForecast.shortPhrase(for: projection(.capsAt(now.addingTimeInterval(2 * 3600 + 5 * 60))), now: now)
        )
        XCTAssertEqual(short, "caps in 2h 5m")
        XCTAssertLessThan(short.count, 24, "this goes in the header, where there is room for a verdict and no more")
    }

    /// The app's voice: lower case, no decoration, no shouting.
    func testCopyMatchesTheHouseVoice() {
        let outcomes: [Outcome] = [
            .capsAt(now.addingTimeInterval(20)),
            .capsAt(now.addingTimeInterval(45 * 60)),
            .capsAt(now.addingTimeInterval(3 * 3600 + 7 * 60)),
            .resetsFirst(now.addingTimeInterval(90 * 60)),
        ]
        for outcome in outcomes {
            for phrase in [
                UsageForecast.phrase(for: projection(outcome), now: now),
                UsageForecast.shortPhrase(for: projection(outcome), now: now),
            ].compactMap({ $0 }) {
                XCTAssertEqual(phrase, phrase.lowercased(), phrase)
                XCTAssertFalse(phrase.contains("!"), phrase)
                XCTAssertFalse(phrase.contains("."), phrase)
                // Printable ASCII only, which is the cheapest way to say "no
                // emoji" without asking Unicode, where the digit 4 is an emoji.
                XCTAssertTrue(
                    phrase.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) },
                    "\(phrase) carries something that is not plain text"
                )
                XCTAssertEqual(phrase.trimmingCharacters(in: .whitespaces), phrase)
            }
        }
    }

    // MARK: - End to end

    /// The path the row actually takes: samples in, sentence out.
    func testSamplesBecomeASentence() throws {
        let samples = climb(endingAt: 0.6, pointsPerHour: 20, spanMinutes: 30)
        let projection = try XCTUnwrap(UsageForecast.project(samples, now: now, resetAt: nil))
        XCTAssertEqual(UsageForecast.phrase(for: projection, now: now), "on pace to cap in 2h")
        XCTAssertEqual(UsageForecast.shortPhrase(for: projection, now: now), "caps in 2h")
    }
}
