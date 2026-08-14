import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// Where the marks go.
///
/// `HistoryChartLayout` is the whole of the chart's arithmetic — every sample,
/// gridline, threshold rule and hover dot is placed by one of these four
/// functions — so pinning them pins the picture without hosting anything. The
/// rect used here has a non-zero origin on purpose: a plot area starts after the
/// axis gutter, and an implementation that forgot that would still pass every
/// assertion written against a rect at 0,0.
final class HistoryChartLayoutTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)
    private var end: Date { start.addingTimeInterval(5 * 3600) }
    private var range: ClosedRange<Date> { start...end }

    /// A five-hour window over a 200pt rail, so an hour is 40pt and every
    /// expected x below is a whole number.
    private let rect = CGRect(x: 31, y: 0, width: 200, height: 100)

    private func sample(_ percent: Double, hours: Double = 0) -> HistorySample {
        HistorySample(at: start.addingTimeInterval(hours * 3600), percent: percent)
    }

    private func point(_ percent: Double, hours: Double) -> CGPoint {
        HistoryChartLayout.point(for: sample(percent, hours: hours), in: rect, range: range)
    }

    // MARK: - The rail

    func testTheStartOfTheRangeLandsOnTheLeadingEdge() {
        XCTAssertEqual(point(0.5, hours: 0).x, rect.minX, accuracy: 0.0001)
    }

    func testTheEndOfTheRangeLandsOnTheTrailingEdge() {
        XCTAssertEqual(point(0.5, hours: 5).x, rect.maxX, accuracy: 0.0001)
    }

    func testTheRailIsDividedEvenlyAcrossTheWindow() {
        for hour in 0...5 {
            XCTAssertEqual(
                point(0.5, hours: Double(hour)).x,
                rect.minX + CGFloat(hour) * 40,
                accuracy: 0.0001,
                "hour \(hour) of five did not land on its own fifth of the rail"
            )
        }
    }

    /// A store handed a wider window than the chart is showing must not draw
    /// outside the plot. Held on the rail rather than dropped: the caller chose
    /// the range, and clipping is this function's job, not the caller's.
    func testASampleOutsideTheWindowIsHeldOnTheRail() {
        XCTAssertEqual(point(0.5, hours: -12).x, rect.minX, accuracy: 0.0001)
        XCTAssertEqual(point(0.5, hours: 400).x, rect.maxX, accuracy: 0.0001)
    }

    /// The one range that has no rail in it. Everything in it lands on the
    /// leading edge rather than on a division by zero, so a chart opened on a
    /// window that has not aged yet still draws.
    func testAWindowOfOneInstantDividesNothing() {
        let instant = start...start
        for hours in [-1.0, 0, 1] {
            let x = HistoryChartLayout.point(
                for: sample(0.5, hours: hours), in: rect, range: instant
            ).x
            XCTAssertTrue(x.isFinite, "a window of one instant produced \(x)")
            XCTAssertEqual(x, rect.minX, accuracy: 0.0001)
        }
    }

    // MARK: - The height

    /// Flipped, because the view's y grows downward and a percentage does not.
    func testZeroIsTheFloorAndTheCapIsTheCeiling() {
        XCTAssertEqual(HistoryChartLayout.y(for: 0, in: rect), rect.maxY, accuracy: 0.0001)
        XCTAssertEqual(HistoryChartLayout.y(for: 1, in: rect), rect.minY, accuracy: 0.0001)
        XCTAssertEqual(HistoryChartLayout.y(for: 0.5, in: rect), rect.midY, accuracy: 0.0001)
    }

    func testHeightRisesAsTheReadingRises() {
        let stops: [Double] = [0, 0.25, 0.5, 0.75, 1]
        let heights = stops.map { HistoryChartLayout.y(for: $0, in: rect) }
        for (lower, higher) in zip(heights, heights.dropFirst()) {
            XCTAssertGreaterThan(lower, higher, "a larger reading did not sit higher up the plot")
        }
    }

    /// An overage a provider reports is drawn at the cap rather than above the
    /// plot, and a negative reading on the floor rather than under it.
    func testAReadingOutsideZeroToOneIsDrawnAtTheEdgeItPassed() {
        XCTAssertEqual(HistoryChartLayout.y(for: 1.4, in: rect), rect.minY, accuracy: 0.0001)
        XCTAssertEqual(HistoryChartLayout.y(for: -0.4, in: rect), rect.maxY, accuracy: 0.0001)
    }

    /// A ratio that is not a number cannot be compared, so it survives `min` and
    /// `max` and would place a mark at NaN — which SwiftUI draws nowhere and
    /// logs about. It is put on the floor instead.
    func testANonFiniteReadingIsPutOnTheFloorRatherThanNowhere() {
        for ratio in [Double.nan, .infinity, -.infinity] {
            let y = HistoryChartLayout.y(for: ratio, in: rect)
            XCTAssertTrue(y.isFinite, "\(ratio) produced a y of \(y)")
            XCTAssertEqual(y, rect.maxY, accuracy: 0.0001, "\(ratio) was not put on the floor")
        }
    }

    func testAPlotWithNoHeightStillPlacesEveryReading() {
        let flat = CGRect(x: 31, y: 20, width: 200, height: 0)
        for ratio in [0.0, 0.5, 1, .nan] {
            XCTAssertEqual(HistoryChartLayout.y(for: ratio, in: flat), 20, accuracy: 0.0001)
        }
    }

    // MARK: - The pointer

    func testThePointerOffEitherEndOfThePlotReadsNothing() {
        XCTAssertNil(HistoryChartLayout.index(atX: rect.minX - 0.01, in: rect, count: 5))
        XCTAssertNil(HistoryChartLayout.index(atX: rect.maxX + 0.01, in: rect, count: 5))
    }

    func testTheEdgesReadTheFirstAndLastBucket() {
        XCTAssertEqual(HistoryChartLayout.index(atX: rect.minX, in: rect, count: 5), 0)
        XCTAssertEqual(HistoryChartLayout.index(atX: rect.maxX, in: rect, count: 5), 4)
    }

    func testTheMiddleOfTheRailReadsTheMiddleBucket() {
        XCTAssertEqual(HistoryChartLayout.index(atX: rect.midX, in: rect, count: 5), 2)
    }

    /// Each bucket owns half a division either side of itself, so the pointer
    /// snaps to the nearest sample rather than to the one it has just passed.
    /// Five buckets over 200pt divide at 50pt, so the first hand-over is 25pt
    /// along.
    func testABucketOwnsHalfADivisionEitherSideOfItself() {
        XCTAssertEqual(HistoryChartLayout.index(atX: rect.minX + 24.9, in: rect, count: 5), 0)
        XCTAssertEqual(HistoryChartLayout.index(atX: rect.minX + 25, in: rect, count: 5), 1)
        XCTAssertEqual(HistoryChartLayout.index(atX: rect.maxX - 25, in: rect, count: 5), 4)
        XCTAssertEqual(HistoryChartLayout.index(atX: rect.maxX - 25.1, in: rect, count: 5), 3)
    }

    /// One sample owns the whole rail. `count - 1` divisions would be no
    /// divisions at all.
    func testOneBucketOwnsTheWholeRail() {
        for x in [rect.minX, rect.midX, rect.maxX] {
            XCTAssertEqual(HistoryChartLayout.index(atX: x, in: rect, count: 1), 0)
        }
        XCTAssertNil(HistoryChartLayout.index(atX: rect.minX - 1, in: rect, count: 1))
    }

    func testASeriesWithNoBucketsReadsNothing() {
        XCTAssertNil(HistoryChartLayout.index(atX: rect.midX, in: rect, count: 0))
        XCTAssertNil(HistoryChartLayout.index(atX: rect.midX, in: rect, count: -3))
    }

    /// A pane narrower than its own gutter hands this a plot with no width. It
    /// reads nothing rather than dividing by it.
    func testAPlotWithNoWidthReadsNothing() {
        let sliver = CGRect(x: 31, y: 0, width: 0, height: 100)
        XCTAssertNil(HistoryChartLayout.index(atX: 31, in: sliver, count: 5))
        XCTAssertNil(HistoryChartLayout.index(atX: 0, in: sliver, count: 5))
    }

    /// The index is never outside the array it is about to subscript. Walked at
    /// a fine step across the rail and a little way off both ends, because this
    /// one is a crash rather than a wrong reading.
    func testEveryIndexItReturnsIsInsideTheSeries() {
        let counts = [1, 2, 3, 7, 96]
        for count in counts {
            for step in stride(from: -20.0, through: 220.0, by: 0.5) {
                guard let index = HistoryChartLayout.index(
                    atX: rect.minX + CGFloat(step), in: rect, count: count
                ) else { continue }
                XCTAssertTrue(
                    (0..<count).contains(index),
                    "\(count) buckets returned index \(index) at \(step)pt along the rail"
                )
            }
        }
    }

    /// The hover fraction is resolved against a 0...1 rect rather than against
    /// the plot, so the readout and the dots inside the `GeometryReader` round
    /// the same way. The unit rail has to behave exactly like the real one.
    func testTheUnitRailBehavesLikeTheRealOne() {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertEqual(HistoryChartLayout.index(atX: 0, in: unit, count: 3), 0)
        XCTAssertEqual(HistoryChartLayout.index(atX: 0.24, in: unit, count: 3), 0)
        XCTAssertEqual(HistoryChartLayout.index(atX: 0.25, in: unit, count: 3), 1)
        XCTAssertEqual(HistoryChartLayout.index(atX: 1, in: unit, count: 3), 2)
        XCTAssertNil(HistoryChartLayout.index(atX: -0.01, in: unit, count: 3))
        XCTAssertNil(HistoryChartLayout.index(atX: 1.01, in: unit, count: 3))
    }

    // MARK: - The threshold rule

    /// The rule is drawn at `y(for: warningThreshold)` and nowhere else, so what
    /// is worth pinning is that the threshold the panel warns at lands where a
    /// reading of the same size would.
    func testTheWarningRuleSitsWhereAReadingOfTheSameSizeWould() {
        let y = HistoryChartLayout.y(for: 0.85, in: rect)
        XCTAssertEqual(y, rect.maxY - rect.height * 0.85, accuracy: 0.0001)
        XCTAssertEqual(y, 15, accuracy: 0.0001)
        XCTAssertTrue((rect.minY...rect.maxY).contains(y), "the rule is outside the plot")
    }

    /// Either side of the threshold, so a series at 84.9% is drawn under its own
    /// rule and one at 85.1% over it. A chart that put a warning row below the
    /// warning line would contradict the panel it sits behind.
    func testAReadingEitherSideOfTheThresholdIsDrawnEitherSideOfTheRule() {
        let rule = HistoryChartLayout.y(for: 0.85, in: rect)
        XCTAssertGreaterThan(HistoryChartLayout.y(for: 0.849, in: rect), rule)
        XCTAssertEqual(HistoryChartLayout.y(for: 0.85, in: rect), rule, accuracy: 0.0001)
        XCTAssertLessThan(HistoryChartLayout.y(for: 0.851, in: rect), rule)
    }

    /// The thresholds a settings pane can be dragged to, and the ones nobody
    /// should reach it with. The threshold is a caller's number rather than this
    /// view's, so every one of them has to draw its rule inside the plot.
    func testEveryThresholdACallerCanPassStaysInThePlot() {
        for threshold in [0.0, 0.5, 0.85, 0.99, 1.0, -1.0, 4.0, Double.nan] {
            let y = HistoryChartLayout.y(for: threshold, in: rect)
            XCTAssertTrue(y.isFinite, "a threshold of \(threshold) produced \(y)")
            XCTAssertTrue(
                (rect.minY...rect.maxY).contains(y),
                "a threshold of \(threshold) drew its rule outside the plot"
            )
        }
    }

    // MARK: - The plot area

    func testThePlotStartsAfterTheGutterAndStopsAboveTheAxisStrip() {
        let size = CGSize(width: 320, height: 160)
        let plot = HistoryChart.plotRect(in: size)
        XCTAssertGreaterThan(plot.minX, 0, "nothing was reserved for the axis figures")
        XCTAssertEqual(plot.maxX, size.width, accuracy: 0.0001)
        XCTAssertLessThan(plot.maxY, size.height, "nothing was reserved for the time labels")
        XCTAssertEqual(plot.minY, 0, accuracy: 0.0001)
    }

    /// A pointer in the axis gutter is not reading a bucket, and the plot rect is
    /// what refuses it. The two functions are checked together because a gutter
    /// that shrank to nothing would leave `index(atX:)` accepting x = 0.
    func testThePointerInTheAxisGutterReadsNothing() {
        let plot = HistoryChart.plotRect(in: CGSize(width: 320, height: 160))
        XCTAssertNil(HistoryChartLayout.index(atX: 0, in: plot, count: 24))
        XCTAssertNil(HistoryChartLayout.index(atX: plot.minX - 0.5, in: plot, count: 24))
        XCTAssertEqual(HistoryChartLayout.index(atX: plot.minX, in: plot, count: 24), 0)
    }

    /// A pane narrower or shorter than the chrome it has to draw would otherwise
    /// hand every layout function an inverted rect, and an inverted rect places
    /// marks outside itself rather than failing.
    func testAPaneTooSmallForItsOwnChromeNeverInvertsThePlot() {
        let sizes = [
            CGSize.zero,
            CGSize(width: 1, height: 1),
            CGSize(width: 10, height: 4),
            CGSize(width: -50, height: -20)
        ]
        for size in sizes {
            let plot = HistoryChart.plotRect(in: size)
            XCTAssertGreaterThanOrEqual(plot.width, 0, "\(size) inverted the plot horizontally")
            XCTAssertGreaterThanOrEqual(plot.height, 0, "\(size) inverted the plot vertically")
            XCTAssertFalse(plot.isNull, "\(size) produced a null plot")
        }
    }

    func testThePlotGrowsWithThePane() {
        let narrow = HistoryChart.plotRect(in: CGSize(width: 300, height: 160))
        let wide = HistoryChart.plotRect(in: CGSize(width: 400, height: 160))
        XCTAssertEqual(wide.width - narrow.width, 100, accuracy: 0.0001)
        XCTAssertEqual(wide.minX, narrow.minX, accuracy: 0.0001, "the gutter moved with the width")

        let tall = HistoryChart.plotRect(in: CGSize(width: 300, height: 200))
        XCTAssertEqual(tall.height - narrow.height, 40, accuracy: 0.0001)
    }

    // MARK: - The axis rail

    /// The gutter is the panel's own rail arithmetic — three reserved cells, a
    /// hairline and one more for the unit — plus the gap to the plot, and the
    /// number is worth pinning because the labels drawn in it do not need the
    /// whole of it: the stops are 0, 50 and 100, so three cells hold every digit
    /// that ever appears. A gutter measured over the widest label the chart
    /// currently draws would come out narrower and would still look right until
    /// the day something set a fourth cell in it. This is the chart's line of
    /// the spec's rail table, and the plot's leading edge is the only place it
    /// is observable from outside.
    func testTheAxisRailIsFourReservedCellsRatherThanTheWidthOfTheLabelsInIt() {
        // Each term at the weight the axis label draws it in, and the unit as a
        // unit cell rather than a fourth digit: the `%` is about 1.47 times a
        // digit in this face where SF Mono's was exactly one. 27 before the face
        // changed, 31 now.
        let rail = Tokens.figureWidth(Tokens.Ramp.caption, digits: 3, weight: Tokens.Ramp.titleWeight)
            + Tokens.Space.hairline
            + Tokens.unitWidth(Tokens.Ramp.caption, weight: .regular)
        XCTAssertEqual(rail, 31, accuracy: 0.0001, "the axis rail is no longer three cells, a hairline and a unit")

        let plot = HistoryChart.plotRect(in: CGSize(width: 320, height: 160))
        XCTAssertEqual(
            plot.minX, rail + Tokens.Space.small, accuracy: 0.0001,
            "the plot does not start after a four-cell rail and its gap"
        )
        XCTAssertGreaterThan(
            plot.minX,
            Tokens.figureWidth(Tokens.Ramp.caption, digits: 3) + Tokens.Space.small,
            "the gutter is only as wide as the labels drawn in it today, so it is measured and not reserved"
        )
    }

    /// A label going from one cell to four cannot move the plot, and the reason
    /// is structural rather than careful: `plotRect(in:)` is handed a size and
    /// nothing else — no series, no range, no threshold — so there is no path
    /// from a label's value to the geometry. What is left to check is that the
    /// rail is also the same width at every size the pane can be dragged to,
    /// including the ones too small to draw it in.
    func testTheRailIsTheSameWidthAtEverySizeThePaneCanBe() {
        let expected = Tokens.figureWidth(Tokens.Ramp.caption, digits: 3, weight: Tokens.Ramp.titleWeight)
            + Tokens.Space.hairline
            + Tokens.unitWidth(Tokens.Ramp.caption, weight: .regular)
            + Tokens.Space.small
        let sizes = [
            CGSize(width: 240, height: 120),
            CGSize(width: 320, height: 160),
            CGSize(width: 900, height: 160),
            CGSize(width: 320, height: 400),
            CGSize(width: 20, height: 8),
            CGSize.zero,
            CGSize(width: -50, height: -20)
        ]
        for size in sizes {
            XCTAssertEqual(
                HistoryChart.plotRect(in: size).minX, expected, accuracy: 0.0001,
                "\(size) drew its axis figures in a rail of its own"
            )
        }
    }
}

/// What the chart says out loud.
///
/// The time stamps and the spoken summary are the chart's only prose, and the
/// summary is also its accessibility value — the lines themselves cannot be
/// read, so these strings are the whole of what a screen reader gets. Numbers
/// are compared against a locally formatted expectation rather than a literal,
/// because both go through a `FormatStyle` and the decimal separator is the
/// reader's.
final class HistoryChartCopyTests: XCTestCase {
    private let at = Date(timeIntervalSince1970: 1_700_000_000)
    private static let twoDays: TimeInterval = 48 * 60 * 60

    private func series(_ percents: [Double]) -> HistoryChartSeries {
        HistoryChartSeries(
            id: "claude",
            title: "Claude",
            colour: .primary,
            points: percents.enumerated().map {
                HistorySample(at: at.addingTimeInterval(Double($0.offset) * 3600), percent: $0.element)
            }
        )
    }

    private func spoken(_ percent: Double) -> String {
        percent.formatted(.number.precision(.fractionLength(1)))
    }

    // MARK: - Stamps

    /// Two days is where the same hour label starts appearing twice on one axis,
    /// so it is the last span that stays a clock time. Both sides of it, and the
    /// two forms compared so a change that collapsed them would fail here rather
    /// than pass silently.
    func testAWindowIsStampedAsAClockTimeUpToTwoDaysAndAsADateBeyond() {
        let clock = HistoryChart.stamp(for: at, span: Self.twoDays)
        let date = HistoryChart.stamp(for: at, span: Self.twoDays + 1)
        XCTAssertNotEqual(clock, date, "a long window is still stamped with a clock time")
        XCTAssertEqual(HistoryChart.stamp(for: at, span: Self.twoDays - 1), clock)
        XCTAssertEqual(HistoryChart.stamp(for: at, span: 3600), clock)
        XCTAssertEqual(HistoryChart.stamp(for: at, span: 90 * 24 * 3600), date)
    }

    /// A window of nothing is not a long window. It reads as a clock time, which
    /// is the branch that also serves the shortest real range.
    func testAnEmptyOrBackwardsWindowStillProducesAStamp() {
        let clock = HistoryChart.stamp(for: at, span: 3600)
        XCTAssertEqual(HistoryChart.stamp(for: at, span: 0), clock)
        XCTAssertEqual(HistoryChart.stamp(for: at, span: -3600), clock)
        XCTAssertFalse(HistoryChart.stamp(for: at, span: 0).isEmpty)
    }

    // MARK: - The spoken summary

    /// A service with no history is not a service at zero, and the sentence a
    /// screen reader hears has to keep that difference. No figure at all, rather
    /// than a figure of nought.
    func testASeriesWithNoPointsSaysSoRatherThanReadingZero() {
        let summary = HistoryChart.summary(of: series([]))
        XCTAssertEqual(summary, "No history")
        XCTAssertFalse(
            summary.contains(where: \.isNumber),
            "an empty series was summarised with a number in it"
        )
    }

    /// The latest reading and the peak, which are the two figures anyone would
    /// read off the curve. Deliberately a series that falls, so a summary that
    /// spoke the peak twice or the last reading twice would fail.
    func testTheSummaryNamesTheLatestReadingAndThePeak() {
        XCTAssertEqual(
            HistoryChart.summary(of: series([0.4, 0.9, 0.2])),
            "latest \(spoken(20)) percent, peak \(spoken(90)) percent"
        )
    }

    func testOneReadingIsItsOwnPeak() {
        XCTAssertEqual(
            HistoryChart.summary(of: series([0.615])),
            "latest \(spoken(61.5)) percent, peak \(spoken(61.5)) percent"
        )
    }

    /// The tenth of a percent the panel drops survives here, because this is
    /// where the user asked one bucket a specific question.
    func testTheSummaryKeepsTheTenthThePanelDrops() {
        let summary = HistoryChart.summary(of: series([0.921, 0.924]))
        XCTAssertTrue(
            summary.contains(spoken(92.4)),
            "\(summary) rounded the tenth away"
        )
    }

    /// A reading that was clamped on the way in is spoken as what it became, not
    /// as what was stored. Nothing can hand a NaN this far — `HistorySample`
    /// clamps in its initialiser and in its decoder — and the summary is written
    /// so that it would still say a number if something did.
    func testAMalformedReadingIsSpokenAsANumber() {
        for percent in [Double.nan, .infinity, -.infinity, -4, 7] {
            let summary = HistoryChart.summary(of: series([percent]))
            XCTAssertFalse(summary.lowercased().contains("nan"), "\(percent) was spoken as NaN")
            XCTAssertFalse(summary.lowercased().contains("inf"), "\(percent) was spoken as infinity")
            XCTAssertTrue(summary.hasPrefix("latest "), "\(percent) produced \"\(summary)\"")
        }
        XCTAssertEqual(
            HistoryChart.summary(of: series([Double.nan])),
            "latest \(spoken(0)) percent, peak \(spoken(0)) percent"
        )
        XCTAssertEqual(
            HistoryChart.summary(of: series([7])),
            "latest \(spoken(100)) percent, peak \(spoken(100)) percent"
        )
    }

    /// Each series is summarised on its own, because each one becomes its own
    /// accessibility element and a screen reader moving between two lines has to
    /// hear two different sentences.
    func testEachSeriesIsSummarisedOnItsOwn() {
        let summaries = [series([0.1, 0.2]), series([0.8, 0.9]), series([])]
            .map(HistoryChart.summary(of:))
        XCTAssertEqual(Set(summaries).count, summaries.count, "two lines read out the same sentence")
    }
}

/// History off disk is untrusted input.
///
/// Samples are kept for months, so they outlive the version that wrote them and
/// arrive as whatever an older shape, a truncated write or a corrupted default
/// left behind. The chart's contract is that a sample's percent is 0...1; these
/// pin that a decoded sample honours it, and that whatever survives decoding is
/// drawn inside the plot rather than somewhere off it.
final class HistoryChartPersistedInputTests: XCTestCase {
    private let rect = CGRect(x: 31, y: 0, width: 200, height: 100)

    private let first = Date(timeIntervalSinceReferenceDate: 700_000_000)
    private let last = Date(timeIntervalSinceReferenceDate: 700_014_400)
    private var range: ClosedRange<Date> { first...last }

    /// Dates decode `.deferredToDate`, so they are seconds since the reference
    /// date. The three markers are how a non-finite double survives a round trip
    /// through JSON at all, which is the only way one could reach a decoder.
    private func decode(_ json: String) throws -> [HistorySample] {
        let decoder = JSONDecoder()
        decoder.nonConformingFloatDecodingStrategy = .convertFromString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan"
        )
        return try decoder.decode([HistorySample].self, from: Data(json.utf8))
    }

    func testAReadingOffDiskIsClampedBeforeItReachesThePlot() throws {
        let samples = try decode("""
        [{"at": 700000000, "percent": 5},
         {"at": 700003600, "percent": -3},
         {"at": 700007200, "percent": "nan"},
         {"at": 700010800, "percent": "inf"},
         {"at": 700014400, "percent": "-inf"}]
        """)
        XCTAssertEqual(samples.count, 5)
        for sample in samples {
            XCTAssertTrue(
                (0...1).contains(sample.percent),
                "\(sample.percent) came off disk and was not clamped"
            )
            let point = HistoryChartLayout.point(for: sample, in: rect, range: range)
            XCTAssertTrue(point.x.isFinite && point.y.isFinite, "\(sample) was placed at \(point)")
            XCTAssertTrue(
                (rect.minX...rect.maxX).contains(point.x)
                    && (rect.minY...rect.maxY).contains(point.y),
                "\(sample) was drawn outside the plot at \(point)"
            )
        }
        // And the two ends specifically, so a clamp that flattened everything to
        // zero would not pass the containment check above.
        XCTAssertEqual(samples[0].percent, 1, accuracy: 0.0001)
        XCTAssertEqual(samples[1].percent, 0, accuracy: 0.0001)
        XCTAssertEqual(samples[2].percent, 0, accuracy: 0.0001)
    }

    /// A record missing a field or carrying the wrong type is rejected rather
    /// than defaulted. A sample invented to keep a decode alive is a reading the
    /// user never had, drawn as confidently as a real one.
    func testAMalformedRecordIsRefusedRatherThanFilledIn() {
        let bad = [
            #"[{"at": 700000000}]"#,
            #"[{"percent": 0.5}]"#,
            #"[{"at": "yesterday", "percent": 0.5}]"#,
            #"[{"at": 700000000, "percent": "0.5"}]"#,
            #"[{"at": 700000000, "percent": null}]"#,
            "[[700000000, 0.5]]",
            "not json at all"
        ]
        for json in bad {
            XCTAssertThrowsError(
                try JSONDecoder().decode([HistorySample].self, from: Data(json.utf8)),
                "\(json) decoded into a sample"
            )
        }
    }

    /// A store that wrote its buckets out of order, or twice at the same
    /// instant, still draws: the chart divides the rail evenly rather than
    /// searching dates, so nothing here can fail to place a point.
    func testSamplesOutOfOrderOrOnTopOfEachOtherStillPlace() throws {
        let samples = try decode("""
        [{"at": 700014400, "percent": 0.9},
         {"at": 700000000, "percent": 0.1},
         {"at": 700000000, "percent": 0.2},
         {"at": 400000000, "percent": 0.3},
         {"at": 900000000, "percent": 0.4}]
        """)
        let points = samples.map { HistoryChartLayout.point(for: $0, in: rect, range: range) }
        for point in points {
            XCTAssertTrue(
                (rect.minX...rect.maxX).contains(point.x),
                "a sample from outside the window was drawn at \(point.x)"
            )
        }
        XCTAssertEqual(points[3].x, rect.minX, accuracy: 0.0001, "an ancient sample left the rail")
        XCTAssertEqual(points[4].x, rect.maxX, accuracy: 0.0001, "a future sample left the rail")
    }
}

/// That the view builds, and that its two states are the same size.
///
/// The accessibility tree and the drawn path are not reachable from a unit test
/// without a UI harness, so what is asserted here is the part that is: the chart
/// holds one height whether or not there is anything in it. That is the whole
/// point of drawing "no history yet" *inside* the plot rather than instead of
/// it — the pane must not resize the moment the first reading arrives, and it
/// must not draw an empty window as a service sitting at zero, which a collapsed
/// plot with a line along its floor would be.
///
/// And that it builds at all, over every window the pane can ask for. Hosting is
/// the cheapest thing that runs `body` and the layout under it, which is where a
/// division by a bucket count or an index rounded past the end of a series would
/// trap rather than draw something wrong.
final class HistoryChartViewTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private func series(_ id: String, _ percents: [Double]) -> HistoryChartSeries {
        HistoryChartSeries(
            id: id,
            title: id.capitalized,
            colour: .secondary,
            points: percents.enumerated().map {
                HistorySample(at: start.addingTimeInterval(Double($0.offset) * 3600), percent: $0.element)
            }
        )
    }

    /// A series of `buckets` readings spread evenly across `span`, which is the
    /// shape the store hands over: one sample per bucket, oldest first. Written
    /// as a count and a span rather than as a list of percentages because the
    /// windows under test below have ninety and twenty thousand points in them.
    private func series(_ id: String, buckets: Int, over span: TimeInterval) -> HistoryChartSeries {
        let step = buckets > 1 ? span / Double(buckets - 1) : 0
        return HistoryChartSeries(
            id: id,
            title: id.capitalized,
            colour: .secondary,
            points: (0..<max(0, buckets)).map {
                HistorySample(
                    at: start.addingTimeInterval(Double($0) * step),
                    percent: Double($0 % 101) / 100
                )
            }
        )
    }

    @MainActor
    private func size(
        _ series: [HistoryChartSeries],
        span: TimeInterval = 5 * 3600,
        threshold: Double = 0.85
    ) -> CGSize {
        let chart = HistoryChart(
            series: series,
            range: start...start.addingTimeInterval(span),
            warningThreshold: threshold
        )
        let host = NSHostingView(rootView: AnyView(chart.frame(width: 320)))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    @MainActor
    func testTheChartAsksForARealHeight() {
        XCTAssertGreaterThan(size([series("claude", [0.2, 0.5, 0.9])]).height, 100)
    }

    /// Every shape of series the pane can hand it, including the ones that have
    /// no line in them. One bucket is drawn as a dot; none at all is dropped
    /// rather than flattened onto the floor.
    @MainActor
    func testEveryShapeOfSeriesHoldsTheSameHeight() {
        // The baseline is the chart with nothing in it, which is the state the
        // pane opens in before the first refresh lands.
        let empty = size([]).height
        let cases: [(String, [HistoryChartSeries])] = [
            ("a series with no points", [series("claude", [])]),
            ("one bucket", [series("claude", [0.4])]),
            ("two buckets", [series("claude", [0.4, 0.6])]),
            ("several series", [
                series("claude", [0.1, 0.4, 0.9]),
                series("grok", [0.2]),
                series("gemini", [])
            ])
        ]
        for (name, entries) in cases {
            XCTAssertEqual(
                size(entries).height, empty, accuracy: 0.5,
                "\(name) changed the chart's height — the pane will resize as history arrives"
            )
        }
    }

    /// Every window the pane can ask for, hosted rather than measured.
    ///
    /// The claim is only that each one builds and lays out, which is worth its
    /// own test because the arithmetic underneath is the kind that traps rather
    /// than draws wrongly when it is wrong: a rail divided by a bucket count, an
    /// index rounded into an array, a stride over a span. Zero series and one
    /// point are the two counts that have no division and no line in them, and
    /// the last case is the pane's longest span at the finest resolution the
    /// store keeps — more readings than any window has buckets, which is what a
    /// caller drawing raw samples rather than daily peaks would hand over.
    @MainActor
    func testTheChartBuildsOnEveryWindowThePaneCanAskFor() {
        let day: TimeInterval = 24 * 60 * 60
        let cases: [(String, [HistoryChartSeries], TimeInterval)] = [
            ("no series at all", [], 5 * 3600),
            ("a series with no points", [series("claude", buckets: 0, over: day)], day),
            ("one point", [series("claude", buckets: 1, over: day)], day),
            (
                "a day of quarter hours",
                [series("claude", buckets: HistoryRange.day.bucketCount, over: day)],
                day
            ),
            (
                "a quarter of daily peaks",
                [series("claude", buckets: HistoryRange.quarter.bucketCount,
                        over: Double(HistoryRange.quarter.days) * day)],
                Double(HistoryRange.quarter.days) * day
            ),
            (
                "a full retention window of readings",
                [series("claude", buckets: Int(HistoryRetention.sample / 60),
                        over: HistoryRetention.sample)],
                HistoryRetention.sample
            ),
            (
                "several series over one window",
                [
                    series("claude", buckets: HistoryRange.week.bucketCount, over: 7 * day),
                    series("grok", buckets: 1, over: 7 * day),
                    series("gemini", buckets: 0, over: 7 * day)
                ],
                7 * day
            )
        ]
        for (name, entries, span) in cases {
            let height = size(entries, span: span).height
            XCTAssertTrue(height.isFinite, "\(name) laid out at a height of \(height)")
            XCTAssertGreaterThan(height, 100, "\(name) collapsed the chart")
        }
    }

    /// A window with no width in it. The pane cannot produce one — every
    /// `HistoryRange` spans at least a day — but the range is a caller's value,
    /// and a chart that divided by it would take the settings window down with
    /// it.
    @MainActor
    func testAWindowOfOneInstantStillBuilds() {
        let chart = HistoryChart(
            series: [series("claude", buckets: 3, over: 0)],
            range: start...start,
            warningThreshold: 0.85
        )
        let host = NSHostingView(rootView: AnyView(chart.frame(width: 320)))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 100)
    }

    /// A threshold at either edge is allowed: the label flips under its own rule
    /// at the ceiling rather than being clipped in half, and neither end may
    /// change the height.
    @MainActor
    func testAThresholdAtEitherEdgeDoesNotChangeTheHeight() {
        let normal = size([series("claude", [0.4, 0.8])]).height
        for threshold in [0.0, 1.0, 4.0, -1.0, Double.nan] {
            XCTAssertEqual(
                size([series("claude", [0.4, 0.8])], threshold: threshold).height,
                normal, accuracy: 0.5,
                "a warning threshold of \(threshold) moved the chart"
            )
        }
    }
}

/// The ground the readings are drawn on, rasterised.
///
/// Two claims a bitmap is the only thing that can settle. The plot area is
/// `Surface.well` and it is opaque — the panel scrim is the only translucency in
/// the application, and this is a surface with figures on it, so a material
/// behind it would hand every contrast ratio quoted for those figures to whatever
/// wallpaper happens to be under the window. And the plot sits in the same box
/// whatever is plotted in it, which is the reserved axis rail pinned above,
/// checked here against the pixels that were actually drawn rather than against
/// the arithmetic that was meant to produce them.
///
/// Rendered through `ImageRenderer`, which is at the macOS 13 floor and is how
/// the rest of this suite rasterises a view. Which appearance the rasteriser
/// draws in is not a test bundle's to choose, so both resolutions of the token
/// are accepted and the claim is that the ground is one of them.
final class HistoryChartGroundTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    /// The width the settings pane draws the chart at, so the plot under test is
    /// the size a reader sees rather than a convenient one.
    private static let width: CGFloat = 320

    /// Tight enough to tell one ground from another: `Surface.well` and
    /// `Surface.base` are about 0.035 apart in every component, and a plot that
    /// quietly took the panel's ground instead of the well has to fail here.
    /// `testTheToleranceCanTellTheWellFromThePanelGround` holds that.
    private static let tolerance: CGFloat = 0.02

    // MARK: - The plot's ground

    func testTheToleranceCanTellTheWellFromThePanelGround() throws {
        for dark in [false, true] {
            let well = try resolve(Tokens.Surface.well, dark: dark)
            let base = try resolve(Tokens.Surface.base, dark: dark)
            XCTAssertFalse(
                same(well, base),
                "the match below cannot tell the well from the panel ground in \(dark ? "dark" : "light")"
            )
        }
    }

    /// A large, fully opaque field of the well, which is what a plot area is.
    ///
    /// The share is checked rather than the geometry because the plot's origin
    /// inside the chart is the chart's own business — padding, the readout line
    /// above it — and a test that recomputed it would be asserting the layout it
    /// was handed. What cannot be faked is that a quarter of the image comes back
    /// as one exact opaque colour: a material, an `opacity`, or the panel ground
    /// standing in for the well each land somewhere else.
    @MainActor
    func testThePlotAreaIsAnOpaqueFieldOfTheWell() throws {
        let drawn = try bitmap([series("claude", buckets: 24)])
        let ground = try self.ground(in: drawn)
        let pixels = drawn.pixelsWide * drawn.pixelsHigh
        XCTAssertGreaterThan(pixels, 0, "the chart rasterised to nothing")
        XCTAssertGreaterThan(
            Double(ground.count) / Double(max(pixels, 1)), 0.25,
            """
            only \(ground.count) of \(pixels) pixels came back as an opaque Surface.well — \
            the plot area is either a different ground or is not opaque
            """
        )
    }

    /// Nothing in the plot lets a backdrop through.
    ///
    /// The same chart over black and over white, compared only at the pixels the
    /// ground occupies — the ink, the antialiased edges of it and the rounded
    /// corners are all excluded, because they blend with the ground rather than
    /// with the backdrop and would fail for a reason that is not translucency.
    /// This is the one assertion that distinguishes "an opaque colour" from "a
    /// colour that happens to look like one over a transparent bitmap": a
    /// `.regularMaterial` or a `.opacity(0.9)` under these figures changes value
    /// when the desktop does, and here it changes value between the two renders.
    @MainActor
    func testTheGroundDoesNotLetABackdropThrough() throws {
        let entries = [series("claude", buckets: 24)]
        let clear = try bitmap(entries)
        let onBlack = try bitmap(entries, backdrop: .black)
        let onWhite = try bitmap(entries, backdrop: .white)
        // The three renders have to be the same size or the comparison below is
        // reading two different pixels.
        for other in [onBlack, onWhite] {
            XCTAssertEqual(other.pixelsWide, clear.pixelsWide)
            XCTAssertEqual(other.pixelsHigh, clear.pixelsHigh)
        }

        let wells = try self.wells()
        var compared = 0
        var differing = 0
        var first: String?
        for x in 0..<clear.pixelsWide {
            for y in 0..<clear.pixelsHigh {
                guard isWell(clear.colorAt(x: x, y: y), wells) else { continue }
                compared += 1
                let black = srgb(onBlack.colorAt(x: x, y: y))
                let white = srgb(onWhite.colorAt(x: x, y: y))
                if let black, let white, same(black, white) { continue }
                differing += 1
                if first == nil {
                    first = "\(x),\(y): \(described(black)) over black, \(described(white)) over white"
                }
            }
        }
        XCTAssertGreaterThan(compared, 1_000, "there was no ground to compare")
        XCTAssertEqual(
            differing, 0,
            "\(differing) of \(compared) ground pixels changed with the backdrop — first at \(first ?? "?")"
        )
    }

    // MARK: - The box the ground sits in

    /// Four charts whose content is as different as the pane can make it: nothing
    /// at all, one bucket, a day of quarter hours stamped as clock times, and a
    /// quarter of daily peaks stamped as dates. All four have to put the ground in
    /// the same box, which is the reserved rail and the fixed plot height stated
    /// in pixels: a gutter measured from the labels it happens to be drawing
    /// would move the leading edge here, since one cell against four is 6pt
    /// against 25.
    @MainActor
    func testThePlotSitsInTheSameBoxWhateverIsPlottedInIt() throws {
        let day: TimeInterval = 24 * 60 * 60
        let cases: [(String, [HistoryChartSeries], TimeInterval)] = [
            ("nothing at all", [], 5 * 3600),
            ("one bucket", [series("claude", buckets: 1)], 5 * 3600),
            (
                "a day of quarter hours",
                [series("claude", buckets: HistoryRange.day.bucketCount, over: day)],
                day
            ),
            (
                "a quarter of daily peaks",
                [series("claude", buckets: HistoryRange.quarter.bucketCount,
                        over: Double(HistoryRange.quarter.days) * day)],
                Double(HistoryRange.quarter.days) * day
            )
        ]

        var expected: Ground?
        for (name, entries, span) in cases {
            let ground = try self.ground(in: try bitmap(entries, span: span))
            XCTAssertGreaterThan(ground.count, 1_000, "\(name) drew no plot ground")
            guard let expected else {
                expected = ground
                continue
            }
            XCTAssertEqual(ground.minX, expected.minX, "\(name) moved the plot's leading edge")
            XCTAssertEqual(ground.maxX, expected.maxX, "\(name) moved the plot's trailing edge")
            XCTAssertEqual(ground.minY, expected.minY, "\(name) moved the top of the plot")
            XCTAssertEqual(ground.maxY, expected.maxY, "\(name) moved the floor of the plot")
        }
    }

    // MARK: - Helpers

    private func series(
        _ id: String,
        buckets: Int,
        over span: TimeInterval = 5 * 3600
    ) -> HistoryChartSeries {
        let step = buckets > 1 ? span / Double(buckets - 1) : 0
        return HistoryChartSeries(
            id: id,
            title: id.capitalized,
            colour: .secondary,
            points: (0..<max(0, buckets)).map {
                HistorySample(
                    at: start.addingTimeInterval(Double($0) * step),
                    percent: Double($0 % 101) / 100
                )
            }
        )
    }

    @MainActor
    private func bitmap(
        _ entries: [HistoryChartSeries],
        span: TimeInterval = 5 * 3600,
        backdrop: Color = .clear
    ) throws -> NSBitmapImageRep {
        let chart = HistoryChart(
            series: entries,
            range: start...start.addingTimeInterval(span),
            warningThreshold: 0.85
        )
        let renderer = ImageRenderer(
            content: chart.frame(width: Self.width).background(backdrop)
        )
        let image = try XCTUnwrap(renderer.nsImage, "the chart would not rasterise")
        let tiff = try XCTUnwrap(image.tiffRepresentation, "the chart rasterised to no data")
        return try XCTUnwrap(NSBitmapImageRep(data: tiff), "the chart's bitmap would not load")
    }

    /// Where the well is in an image, and how much of it there is.
    private struct Ground {
        var count = 0
        var minX = Int.max
        var maxX = Int.min
        var minY = Int.max
        var maxY = Int.min
    }

    private func ground(in bitmap: NSBitmapImageRep) throws -> Ground {
        let wells = try self.wells()
        var found = Ground()
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh where isWell(bitmap.colorAt(x: x, y: y), wells) {
                found.count += 1
                found.minX = min(found.minX, x)
                found.maxX = max(found.maxX, x)
                found.minY = min(found.minY, y)
                found.maxY = max(found.maxY, y)
            }
        }
        return found
    }

    /// The two resolutions of the one token the plot area is allowed to be.
    private func wells() throws -> [NSColor] {
        [
            try resolve(Tokens.Surface.well, dark: false),
            try resolve(Tokens.Surface.well, dark: true)
        ]
    }

    private func isWell(_ colour: NSColor?, _ wells: [NSColor]) -> Bool {
        guard let drawn = srgb(colour) else { return false }
        return wells.contains { same(drawn, $0) }
    }

    /// A dynamic colour has no value until something draws it, so the test stands
    /// in for the drawing. `performAsCurrentDrawingAppearance` is the supported
    /// way to do that — assigning `NSAppearance.current` is deprecated.
    private func resolve(_ color: Color, dark: Bool) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return try XCTUnwrap(resolved, "colour would not resolve in sRGB")
    }

    private func srgb(_ colour: NSColor?) -> NSColor? {
        colour?.usingColorSpace(.sRGB)
    }

    /// The same colour, and fully opaque in both. Opacity is part of the match
    /// rather than a separate assertion: a ground drawn at less than full alpha
    /// comes back as the right hue with the wrong alpha, and that is exactly the
    /// failure this file is here to catch.
    private func same(_ drawn: NSColor, _ expected: NSColor) -> Bool {
        abs(drawn.redComponent - expected.redComponent) < Self.tolerance
            && abs(drawn.greenComponent - expected.greenComponent) < Self.tolerance
            && abs(drawn.blueComponent - expected.blueComponent) < Self.tolerance
            && drawn.alphaComponent > 0.99
            && expected.alphaComponent > 0.99
    }

    private func described(_ colour: NSColor?) -> String {
        guard let drawn = srgb(colour) else { return "nothing" }
        return String(
            format: "%.3f/%.3f/%.3f at alpha %.3f",
            drawn.redComponent, drawn.greenComponent, drawn.blueComponent, drawn.alphaComponent
        )
    }
}
