import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// Where the pace notch lands, asserted rather than eyeballed.
///
/// This is the arithmetic half of the meter's signature mark, and the reason it
/// was pulled out of `ProviderRow` in the first place: a fraction on a track is
/// four numbers, and four numbers can be checked. The refusals matter more than
/// the fractions do — a provider that does not describe its window must get no
/// notch at all, and a window it describes badly must not be divided by.
final class PaceGeometryElapsedTests: XCTestCase {
    /// Fixed, because every case here is stated as an offset from it. `Date()`
    /// would make "a full window away" drift by however long the test took.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func elapsed(reset: TimeInterval?, window: TimeInterval?) -> Double? {
        PaceGeometry.elapsed(
            resetDate: reset.map { now.addingTimeInterval($0) },
            windowDuration: window,
            now: now
        )
    }

    // MARK: - The no-notch case

    /// Nil, never 0. The two say different things — "this window is not
    /// measured" against "this window just started" — and the second one draws a
    /// tick at the left edge of every row the first applies to.
    func testAMissingDurationOrResetMeansNoNotchAtAll() {
        XCTAssertNil(elapsed(reset: 3600, window: nil), "a row with no window length still placed a notch")
        XCTAssertNil(elapsed(reset: nil, window: 18000), "a row with no reset date still placed a notch")
        XCTAssertNil(elapsed(reset: nil, window: nil))
    }

    /// A duration that cannot be divided by is the same refusal, and a NaN one
    /// is the one that has to be caught here: it survives `>` as false, which is
    /// the answer we want, but only because the guard is written that way round.
    func testAWindowThatCannotBeDividedByIsRefused() {
        let lengths: [TimeInterval] = [0, -1, -18000, .nan, .infinity, -.infinity]
        for length in lengths {
            XCTAssertNil(
                elapsed(reset: 900, window: length),
                "a window of \(length) was treated as a real duration"
            )
        }
    }

    /// Reset dates arrive from provider JSON and from the snapshot store on
    /// disk, so both are untrusted. A date built from a non-finite interval
    /// hands back a non-finite `timeIntervalSince`, which would otherwise reach
    /// the clamp and then a frame width.
    func testAMalformedResetDateIsRefused() {
        let intervals: [TimeInterval] = [.infinity, -.infinity, .nan]
        for interval in intervals {
            XCTAssertNil(
                PaceGeometry.elapsed(
                    resetDate: Date(timeIntervalSince1970: interval),
                    windowDuration: 18000,
                    now: now
                ),
                "a reset date at \(interval) produced a notch position"
            )
        }
    }

    // MARK: - The fractions

    func testAQuarterOfTheWayThroughAFiveHourWindow() throws {
        let fraction = try XCTUnwrap(elapsed(reset: 13500, window: 18000))
        XCTAssertEqual(fraction, 0.25, accuracy: 0.0001)
    }

    /// Both ends of the window it describes, and the middle. A reset exactly now
    /// is the window's last instant, not its first.
    func testTheEndsOfTheWindowReadAsZeroAndOne() throws {
        XCTAssertEqual(try XCTUnwrap(elapsed(reset: 18000, window: 18000)), 0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(elapsed(reset: 9000, window: 18000)), 0.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(elapsed(reset: 0, window: 18000)), 1, accuracy: 0.0001)
    }

    /// A reset that has already gone by means the window ran out and nothing has
    /// refreshed it yet. That is a full window, not an overdue one, and the
    /// notch belongs at the far end rather than off the track.
    func testAResetInThePastClampsToFull() throws {
        for offset: TimeInterval in [-0.5, -1, -3600, -86400] {
            XCTAssertEqual(
                try XCTUnwrap(elapsed(reset: offset, window: 18000)), 1, accuracy: 0.0001,
                "a reset \(-offset)s ago did not clamp to a full window"
            )
        }
        XCTAssertEqual(
            try XCTUnwrap(PaceGeometry.elapsed(resetDate: .distantPast, windowDuration: 18000, now: now)),
            1, accuracy: 0.0001
        )
    }

    /// And one further away than the window is long is a provider quoting a
    /// reset for some other window. It reads as "nothing of this one is gone".
    func testAResetBeyondAFullWindowClampsToZero() throws {
        for offset: TimeInterval in [18001, 27000, 86400] {
            XCTAssertEqual(
                try XCTUnwrap(elapsed(reset: offset, window: 18000)), 0, accuracy: 0.0001,
                "a reset \(offset)s away did not clamp to an empty window"
            )
        }
        XCTAssertEqual(
            try XCTUnwrap(PaceGeometry.elapsed(resetDate: .distantFuture, windowDuration: 18000, now: now)),
            0, accuracy: 0.0001
        )
    }

    /// Finite but absurd durations still divide, and the division can overflow
    /// to an infinity that a naive clamp would pass straight through. Whatever
    /// the answer is, it has to be a number in 0...1.
    func testAnExtremeButFiniteWindowStillAnswersInRange() throws {
        let lengths: [TimeInterval] = [.leastNormalMagnitude, .leastNonzeroMagnitude, 1, .greatestFiniteMagnitude]
        for length in lengths {
            let fraction = try XCTUnwrap(elapsed(reset: 60, window: length), "a window of \(length) was refused")
            XCTAssertTrue(fraction.isFinite, "a window of \(length) produced \(fraction)")
            XCTAssertTrue((0...1).contains(fraction), "a window of \(length) produced \(fraction)")
        }
    }

    /// The sweep the row actually walks through as a window elapses, either side
    /// of both ends of it.
    func testEveryPointOfASweepStaysInRange() throws {
        for step in stride(from: -6000.0, through: 24000.0, by: 250) {
            let fraction = try XCTUnwrap(elapsed(reset: step, window: 18000))
            XCTAssertTrue((0...1).contains(fraction), "reset \(step)s away produced \(fraction)")
        }
    }
}

/// The marks the fraction turns into: where the tick sits, how far it stands
/// proud of the bar, and whether the fill has got past it.
final class PaceGeometryMarkTests: XCTestCase {

    // MARK: - notchX

    func testTheNotchSitsAtItsFractionOfTheWidth() {
        XCTAssertEqual(PaceGeometry.notchX(elapsed: 0.25, width: 200), 50, accuracy: 0.0001)
        XCTAssertEqual(PaceGeometry.notchX(elapsed: 0, width: 200), 0, accuracy: 0.0001)
        XCTAssertEqual(PaceGeometry.notchX(elapsed: 1, width: 200), 200, accuracy: 0.0001)
    }

    /// Not rounded to a whole point, on purpose: a tick that snapped a point at
    /// a time would twitch every few minutes on a five-hour window, and the fill
    /// it is being compared against is fractional too.
    func testTheNotchIsNotSnappedToWholePoints() {
        XCTAssertEqual(PaceGeometry.notchX(elapsed: 0.333, width: 197), 65.601, accuracy: 0.0001)
    }

    /// A fraction outside 0...1 cannot reach the layout: the track is the whole
    /// of the coordinate space the notch is allowed in, and a tick drawn past
    /// its trailing edge would be a mark with no meter under it.
    func testTheNotchStaysInsideTheTrackWhateverItIsGiven() {
        let width: CGFloat = 120
        let fractions: [Double] = [-3, -0.0001, 0, 1, 1.0001, 4, .nan, .infinity, -.infinity]
        for fraction in fractions {
            let x = PaceGeometry.notchX(elapsed: fraction, width: width)
            XCTAssertTrue(x.isFinite, "an elapsed fraction of \(fraction) produced \(x)")
            XCTAssertTrue((0...width).contains(x), "an elapsed fraction of \(fraction) put the notch at \(x)")
        }
    }

    /// A track with no width is a row mid-layout, before SwiftUI has proposed
    /// anything. It gets a position rather than a crash, and the position is the
    /// leading edge.
    func testATrackWithNoWidthPutsTheNotchAtTheOrigin() {
        let widths: [CGFloat] = [0, -1, -200, .nan]
        for width in widths {
            XCTAssertEqual(
                PaceGeometry.notchX(elapsed: 0.5, width: width), 0,
                "a \(width)pt track placed a notch somewhere"
            )
        }
    }

    // MARK: - overhang

    /// The three the design fixes. 2 is a cap, not a coincidence: the smallest
    /// `contentSpacing` is 3pt, and anything taller stops fitting in the gap
    /// that already exists between the title line and the bar — at which point
    /// every row in the panel grows, nine times over.
    func testTheOverhangFitsTheSmallestContentSpacing() {
        XCTAssertEqual(PaceGeometry.overhang(barHeight: 3), 1)
        XCTAssertEqual(PaceGeometry.overhang(barHeight: 5), 2)
        XCTAssertEqual(PaceGeometry.overhang(barHeight: 12), 2)
    }

    /// Either side of the step, which lands where 0.3 of the bar rounds to 2.
    func testTheOverhangStepsAtTheRoundingBoundary() {
        XCTAssertEqual(PaceGeometry.overhang(barHeight: 4.9), 1)
        XCTAssertEqual(PaceGeometry.overhang(barHeight: 5), 2)
    }

    /// Every bar height the appearance settings can hand it, plus the ones only
    /// a bug can: it is 1 or 2 and never anything else.
    func testTheOverhangIsNeverOutsideOneToTwo() {
        var heights: [CGFloat] = [0, -1, -40, .nan, .infinity, -CGFloat.infinity, .greatestFiniteMagnitude]
        heights += stride(from: 0.5, through: 40, by: 0.25).map { CGFloat($0) }
        for height in heights {
            let overhang = PaceGeometry.overhang(barHeight: height)
            XCTAssertTrue(overhang.isFinite, "a \(height)pt bar gave an overhang of \(overhang)")
            XCTAssertTrue((1...2).contains(overhang), "a \(height)pt bar gave an overhang of \(overhang)")
        }
    }

    // MARK: - fillHasPassedNotch

    /// Strict. Exactly on pace has *reached* the notch, not passed it: the whole
    /// point of the mark is the comparison, and the honest answer at the
    /// boundary is "not yet".
    func testTheFillHasPassedTheNotchOnlyWhenItIsAhead() {
        XCTAssertTrue(PaceGeometry.fillHasPassedNotch(percent: 0.92, elapsed: 0.60))
        XCTAssertTrue(PaceGeometry.fillHasPassedNotch(percent: 0.5001, elapsed: 0.5))
        XCTAssertFalse(PaceGeometry.fillHasPassedNotch(percent: 0.5, elapsed: 0.5))
        XCTAssertFalse(PaceGeometry.fillHasPassedNotch(percent: 0.4999, elapsed: 0.5))
        XCTAssertFalse(PaceGeometry.fillHasPassedNotch(percent: 0.25, elapsed: 0.60))
    }

    /// Both ends are clamped before the comparison, so a provider reporting 140%
    /// against a window already over does not read as "ahead of pace" — both
    /// sides are at the end of the track and neither is in front.
    func testBothSidesAreClampedBeforeTheyAreCompared() {
        XCTAssertFalse(PaceGeometry.fillHasPassedNotch(percent: 1.4, elapsed: 1.2))
        XCTAssertFalse(PaceGeometry.fillHasPassedNotch(percent: -0.5, elapsed: -2))
        XCTAssertTrue(PaceGeometry.fillHasPassedNotch(percent: 1.4, elapsed: 0.5))
        XCTAssertFalse(PaceGeometry.fillHasPassedNotch(percent: 0.5, elapsed: 1.4))
    }

    /// A NaN loses every comparison silently, so the row would quietly draw the
    /// notch in the wrong ink rather than fail. It answers "not passed", which
    /// is the reading that claims least.
    func testANonFinitePairNeverClaimsToHavePassed() {
        let values: [Double] = [.nan, .infinity, -.infinity]
        for value in values {
            XCTAssertFalse(PaceGeometry.fillHasPassedNotch(percent: value, elapsed: 0.5), "percent \(value)")
            XCTAssertFalse(PaceGeometry.fillHasPassedNotch(percent: 0.5, elapsed: value), "elapsed \(value)")
            XCTAssertFalse(PaceGeometry.fillHasPassedNotch(percent: value, elapsed: value), "both \(value)")
        }
    }
}

/// The fill's outline.
///
/// The square trailing end is the shape channel of the near-cap contract — the
/// one that survives greyscale and `ColorRamp.mono` — so "is this end square"
/// has to be a fact about the geometry rather than about how it looks. These
/// probe the path directly: `Path.contains` is the only way to ask a shape what
/// it covers without rendering it.
final class MeterFillShapeTests: XCTestCase {
    private let bar = CGRect(x: 0, y: 0, width: 100, height: 8)

    private func path(_ squareTrailing: Bool, in rect: CGRect) -> Path {
        MeterFill(squareTrailing: squareTrailing).path(in: rect)
    }

    private func assertFills(
        _ rect: CGRect,
        squareTrailing: Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let bounds = path(squareTrailing, in: rect).boundingRect
        XCTAssertEqual(bounds.minX, rect.minX, accuracy: 0.01, "leading edge", file: file, line: line)
        XCTAssertEqual(bounds.minY, rect.minY, accuracy: 0.01, "top edge", file: file, line: line)
        XCTAssertEqual(bounds.width, rect.width, accuracy: 0.01, "width", file: file, line: line)
        XCTAssertEqual(bounds.height, rect.height, accuracy: 0.01, "height", file: file, line: line)
    }

    // MARK: - Extent

    /// Both cap styles occupy exactly the rect they were proposed. A fill that
    /// came up short would read as a lower percentage than the row states, and
    /// one that overhung would spill outside the track it sits in.
    func testTheFillOccupiesTheWholeRect() {
        assertFills(bar, squareTrailing: true)
        assertFills(bar, squareTrailing: false)
    }

    /// The track is not at the window's origin — it sits inside a row, inside a
    /// list — so the shape has to be written in the rect's own coordinates
    /// rather than assuming (0, 0).
    func testTheFillHonoursTheRectsOrigin() {
        assertFills(CGRect(x: 12, y: 7, width: 40, height: 6), squareTrailing: true)
        assertFills(CGRect(x: -40, y: -12, width: 60, height: 6), squareTrailing: false)
    }

    /// A fill narrower than its own cap is a real state: 2pt on a 6pt bar is
    /// what 1% looks like. The radii shrink to fit rather than overhanging the
    /// width they were given.
    func testANarrowFillNeverOverhangsTheWidthItWasGiven() {
        let widths: [CGFloat] = [0.5, 1, 2, 4, 8, 16]
        for width in widths {
            let rect = CGRect(x: 0, y: 0, width: width, height: 8)
            assertFills(rect, squareTrailing: true)
            assertFills(rect, squareTrailing: false)
        }
    }

    // MARK: - The cap styles

    /// The probe sits half a point inside the corner rather than on it: a point
    /// exactly on a `CGPath` boundary is outside it under the fill rule, so the
    /// exact corner answers false for both styles and would prove nothing.
    private var trailingCornerProbe: CGPoint { CGPoint(x: bar.maxX - 0.5, y: bar.minY + 0.5) }

    func testASquareTrailingEndCoversItsCorner() {
        XCTAssertTrue(
            path(true, in: bar).contains(trailingCornerProbe),
            "the trailing corner is empty — the near-cap shape channel is not being drawn"
        )
        XCTAssertTrue(path(true, in: bar).contains(CGPoint(x: bar.maxX - 0.5, y: bar.maxY - 0.5)))
    }

    func testARoundTrailingEndDoesNot() {
        XCTAssertFalse(
            path(false, in: bar).contains(trailingCornerProbe),
            "the trailing corner is filled — a below-warning row is wearing the near-cap shape"
        )
        XCTAssertFalse(path(false, in: bar).contains(CGPoint(x: bar.maxX - 0.5, y: bar.maxY - 0.5)))
    }

    /// The leading end never changes. It is pinned to the start of the track and
    /// has nothing to report, so it stays round under both styles — which is
    /// also what lets the fill sit inside a capsule track without a seam.
    func testTheLeadingEndIsRoundUnderBothStyles() {
        for squareTrailing in [true, false] {
            XCTAssertFalse(
                path(squareTrailing, in: bar).contains(CGPoint(x: bar.minX + 0.5, y: bar.minY + 0.5)),
                "the leading corner is filled with squareTrailing = \(squareTrailing)"
            )
            XCTAssertTrue(
                path(squareTrailing, in: bar).contains(CGPoint(x: bar.minX + 4, y: bar.midY)),
                "the fill is missing behind its own leading cap"
            )
        }
    }

    /// Both styles are the same shape everywhere except that corner, so the body
    /// of the bar cannot be used to tell them apart.
    func testTheBodyOfTheBarIsFilledEitherWay() {
        for squareTrailing in [true, false] {
            XCTAssertTrue(path(squareTrailing, in: bar).contains(CGPoint(x: bar.midX, y: bar.midY)))
        }
    }

    // MARK: - Degenerate proposals

    /// 0% is a rect with no width, and it must draw nothing rather than the
    /// sliver a cap on a zero-width rect would leave behind. Same for the zero
    /// height a row is proposed mid-layout.
    func testAnEmptyRectProducesNoPath() {
        let empties: [CGRect] = [
            CGRect(x: 0, y: 0, width: 0, height: 8),
            CGRect(x: 0, y: 0, width: 100, height: 0),
            CGRect(x: 12, y: 7, width: 0, height: 0),
            .zero
        ]
        for rect in empties {
            for squareTrailing in [true, false] {
                XCTAssertTrue(
                    path(squareTrailing, in: rect).isEmpty,
                    "\(rect) with squareTrailing = \(squareTrailing) drew a sliver"
                )
            }
        }
    }

    /// A NaN dimension is what a percentage divided by a zero limit turns into
    /// further up. `NaN > 0` is false, so the same guard catches it — but only
    /// because it is written as a positive test rather than as `!(width <= 0)`.
    func testANonFiniteRectDrawsNothingOrNothingHarmful() {
        for squareTrailing in [true, false] {
            XCTAssertTrue(path(squareTrailing, in: CGRect(x: 0, y: 0, width: CGFloat.nan, height: 8)).isEmpty)
            XCTAssertTrue(path(squareTrailing, in: CGRect(x: 0, y: 0, width: 100, height: CGFloat.nan)).isEmpty)
            // An infinite proposal is not something SwiftUI hands a shape, and
            // CoreGraphics saturates it rather than refusing it. The only thing
            // worth pinning is that it neither traps nor leaks a NaN into a
            // frame the layout would then be sized from.
            let huge = path(squareTrailing, in: CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 8)).boundingRect
            XCTAssertFalse(huge.width.isNaN, "an infinite width produced a NaN bounding box")
        }
    }

    // MARK: - As a view

    /// It is a `Shape`, so it takes the size it is given and asks for nothing of
    /// its own. Measured with `MenuBarExtra`'s habit in mind: anything in the
    /// panel that requests height requests it on every row.
    @MainActor
    func testTheShapeBuildsAndTakesTheSizeItIsGiven() {
        let host = NSHostingView(
            rootView: AnyView(MeterFill(squareTrailing: true).frame(width: 100, height: 8))
        )
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(host.fittingSize.width, 100, accuracy: 0.5)
        XCTAssertEqual(host.fittingSize.height, 8, accuracy: 0.5)
    }
}

/// Whether the fill is cut, which is the only question in the meter with two
/// separate ways of answering "no".
///
/// The refusals are the substance again. A window nobody described has no
/// boundary to overtake, and a bar too thin to hold a gap has nowhere to put
/// one — and in both cases the riser goes back to being drawn in
/// `Surface.onFill` where the fill covers it, which is a reading a thin bar can
/// still carry. Everything that is not a refusal is `fillHasPassedNotch`, and
/// that it is *literally* that comparison rather than a second one that agrees
/// with it today is the thing worth pinning: the track's two tones, the riser
/// and the cut are three channels of one instrument, and three channels drawn
/// from two comparisons is how they come to disagree at a boundary.
final class MeterCutDecisionTests: XCTestCase {
    /// The thinnest bar that is cut at all. Read from the token rather than
    /// written down, because every case below is stated as an offset from it.
    private let floorHeight = Tokens.Meter.cutMinBarHeight

    private func isCut(
        percent: Double = 1,
        elapsed: Double? = 0.5,
        barHeight: CGFloat = 8
    ) -> Bool {
        MeterCut.isCut(percent: percent, elapsed: elapsed, barHeight: barHeight)
    }

    // MARK: - The two refusals

    /// A window the provider declines to describe gets a uniform track and no
    /// riser, so there is nothing for the fill to have overtaken. The nil comes
    /// straight from `PaceGeometry.elapsed` and is carried one step further
    /// rather than being re-derived at each call site.
    func testAWindowWithNoElapsedFractionIsNeverCut() {
        for percent in [0, 0.5, 0.999, 1, 1.4] {
            for height in [5, 8, 12, 20] as [CGFloat] {
                XCTAssertFalse(
                    isCut(percent: percent, elapsed: nil, barHeight: height),
                    "an undescribed window at \(percent) on a \(height)pt bar was cut"
                )
            }
        }
    }

    /// A gap wider than the bar is thick is not a slit, it is a bar in two
    /// pieces — which says something the user has to stop and reinterpret, on a
    /// row that is only trying to say "you are ahead of the window".
    func testABarThinnerThanTheFloorIsNotCut() {
        for height in [0.5, 1, 2, 3, 4, 4.5, 4.9] as [CGFloat] {
            XCTAssertFalse(isCut(barHeight: height), "a \(height)pt bar was cut")
        }
    }

    /// Five, and inclusive at five. The floor is a design value rather than a
    /// derived one, so it is pinned here: `meterThickness` goes down to 3, and
    /// the gap is 3pt at rest and 4pt under increased contrast.
    func testTheFloorIsFivePointsAndTakesEffectAtExactlyFive() {
        XCTAssertEqual(floorHeight, 5)
        XCTAssertFalse(isCut(barHeight: 4.99), "a bar just under the floor was cut")
        XCTAssertTrue(isCut(barHeight: floorHeight), "the floor itself was not cut")
        XCTAssertTrue(isCut(barHeight: 5.01))
    }

    /// And the floor is only defensible while it clears the widest gap the app
    /// can draw. If `cutClearance` or `notchWidth` ever grows past it, the first
    /// symptom is a snapped bar at the thinnest density rather than a failing
    /// test — so the relationship between the three tokens is asserted, not the
    /// two numbers that happen to satisfy it.
    func testTheFloorIsNeverThinnerThanTheWidestGap() {
        for increased in [false, true] {
            XCTAssertGreaterThanOrEqual(
                floorHeight, MeterCut.width(increasedContrast: increased),
                "the gap is wider than the thinnest bar allowed to carry it, increased: \(increased)"
            )
        }
    }

    /// Every thickness either side of the floor, on a fill that has certainly
    /// passed: the answer is the height test and nothing else.
    func testTheFloorIsTheOnlyThingThicknessDecides() {
        for step in stride(from: 0.5, through: 24, by: 0.25) {
            let height = CGFloat(step)
            XCTAssertEqual(
                isCut(barHeight: height), height >= floorHeight,
                "a \(height)pt bar answered \(isCut(barHeight: height))"
            )
        }
    }

    /// `NaN >= 5` is false, which is the answer wanted — but only because the
    /// guard is written as a positive test rather than as `!(barHeight < floor)`.
    /// An infinite height is not something a density setting produces; it is
    /// what a layout mid-collapse hands down.
    func testANonFiniteBarHeightIsNotCut() {
        for height in [CGFloat.nan, .infinity, -.infinity] {
            XCTAssertFalse(isCut(barHeight: height), "a \(height)pt bar was cut")
        }
    }

    // MARK: - Otherwise it is the pace comparison, exactly

    /// The whole sweep, at three thicknesses above the floor. Not "agrees with"
    /// — equals: the cut is not allowed an opinion of its own about who is
    /// ahead, because the riser it is punching clearance around is placed by
    /// that same comparison.
    func testAboveTheFloorTheCutIsTheFillHavingPassedTheRiser() {
        for step in stride(from: 0.0, through: 1.05, by: 0.05) {
            for elapsedStep in stride(from: 0.0, through: 1.05, by: 0.05) {
                let expected = PaceGeometry.fillHasPassedNotch(percent: step, elapsed: elapsedStep)
                for height in [5, 8, 20] as [CGFloat] {
                    XCTAssertEqual(
                        isCut(percent: step, elapsed: elapsedStep, barHeight: height), expected,
                        "percent \(step) against elapsed \(elapsedStep) on a \(height)pt bar"
                    )
                }
            }
        }
    }

    /// Strict at the boundary, for the reason the notch is: exactly on pace has
    /// reached the riser, not overtaken it, and a gap punched at the instant the
    /// fill arrives would claim an overspend of zero length.
    func testExactlyOnPaceIsNotCut() {
        for value in [0.0, 0.25, 0.5, 0.85, 1] {
            XCTAssertFalse(isCut(percent: value, elapsed: value), "on pace at \(value) was cut")
        }
        XCTAssertTrue(isCut(percent: 0.5.nextUp, elapsed: 0.5), "a fill past the riser was not cut")
        XCTAssertFalse(isCut(percent: 0.5.nextDown, elapsed: 0.5))
    }

    /// Both sides are clamped before they are compared, so a provider reporting
    /// 140% against a window that has already run out does not read as an
    /// overspend: both are at the end of the track and neither is in front.
    func testBothSidesAreClampedBeforeTheyAreCompared() {
        XCTAssertFalse(isCut(percent: 1.4, elapsed: 1.2))
        XCTAssertTrue(isCut(percent: 1.4, elapsed: 0.5))
        XCTAssertFalse(isCut(percent: 0.5, elapsed: 1.4))
        XCTAssertFalse(isCut(percent: -0.5, elapsed: -2))
    }

    /// A NaN loses every comparison silently, so the row would draw an
    /// overspend it was never told about rather than fail.
    func testANonFiniteReadingIsNotCut() {
        for value in [Double.nan, .infinity, -.infinity] {
            XCTAssertFalse(isCut(percent: value), "percent \(value)")
            XCTAssertFalse(isCut(elapsed: value), "elapsed \(value)")
            XCTAssertFalse(isCut(percent: value, elapsed: value), "both \(value)")
        }
    }
}

/// How wide the gap is and where it lands.
///
/// Two facts, and the second one is the one that can rot: the gap is the
/// riser's clearance rather than an event of its own, so its centre has to be
/// the riser's own x. Two functions that each compute a position from the same
/// fraction is exactly how a mark and the hole it stands in come to sit a
/// fraction of a point apart, which at 1pt is the difference between a riser in
/// a slit and a smudge.
final class MeterCutGeometryTests: XCTestCase {

    // MARK: - Width

    /// Asserted against the tokens rather than against the 3 and 4 they
    /// currently make, because both halves answer to increased contrast and the
    /// arithmetic is the contract: the riser, plus a clearance either side of it.
    func testTheGapIsTheRiserPlusAClearanceEitherSide() {
        for increased in [false, true] {
            XCTAssertEqual(
                MeterCut.width(increasedContrast: increased),
                Tokens.notchWidth(increased: increased) + 2 * Tokens.Meter.cutClearance,
                accuracy: 0.0001,
                "increasedContrast \(increased)"
            )
        }
    }

    /// The riser widens under increased contrast and the gap around it has to
    /// widen with it. A gap that stayed put would tighten the clearance exactly
    /// where it was already hardest to see.
    func testTheGapWidensUnderIncreasedContrast() {
        XCTAssertGreaterThan(
            MeterCut.width(increasedContrast: true),
            MeterCut.width(increasedContrast: false)
        )
    }

    /// And it always leaves at least a point of ground either side. Without
    /// that the riser is one colour drawn on a saturated fill of another, at
    /// 1pt, which reads as a rendering artefact rather than as a mark.
    func testTheGapAlwaysClearsTheRiserOnBothSides() {
        for increased in [false, true] {
            let clearance =
                (MeterCut.width(increasedContrast: increased)
                    - Tokens.notchWidth(increased: increased)) / 2
            XCTAssertGreaterThanOrEqual(
                clearance, 1,
                "the riser has \(clearance)pt of ground beside it, increasedContrast \(increased)"
            )
        }
    }

    // MARK: - Where it lands

    /// The riser's own x, at every fraction it can be handed and every width a
    /// row can propose — including the ones only a bug produces. Stated as
    /// equality with `notchX` rather than as an arithmetic of its own, so the
    /// two cannot drift: the clamping, the refusal on a zero-width track and the
    /// decision not to snap to whole points are all inherited rather than
    /// repeated.
    func testTheGapIsCentredOnTheRiserWhateverEitherIsGiven() {
        let fractions: [Double] = [-3, -0.0001, 0, 0.25, 0.333, 0.5, 1, 1.0001, 4, .nan, .infinity]
        let widths: [CGFloat] = [0, -1, 1, 120, 197, 340]
        for fraction in fractions {
            for width in widths {
                XCTAssertEqual(
                    MeterCut.centreX(elapsed: fraction, trackWidth: width),
                    PaceGeometry.notchX(elapsed: fraction, width: width),
                    "the gap and the riser disagreed at \(fraction) on a \(width)pt track"
                )
            }
        }
    }

    /// The value a caller actually offsets a rectangle by, and the only thing it
    /// is allowed to be: half a gap before the centre. Asserted both ways round,
    /// because putting the centre back is what the drawing code is trusting.
    func testTheLeadingEdgeIsHalfAGapBeforeTheCentre() {
        for increased in [false, true] {
            let half = MeterCut.width(increasedContrast: increased) / 2
            for fraction in [0.0, 0.25, 0.333, 0.6, 1] {
                for width in [120, 197, 340] as [CGFloat] {
                    let leading = MeterCut.leadingX(
                        elapsed: fraction,
                        trackWidth: width,
                        increasedContrast: increased
                    )
                    let centre = MeterCut.centreX(elapsed: fraction, trackWidth: width)
                    XCTAssertEqual(leading, centre - half, accuracy: 0.0001, "\(fraction) on \(width)pt")
                    XCTAssertEqual(leading + half, centre, accuracy: 0.0001, "\(fraction) on \(width)pt")
                }
            }
        }
    }

    /// Negative early in a window, and that is correct rather than tolerated.
    /// The caller clips the band to the fill it is punching through, so the half
    /// that falls outside the track has nothing to land on; clamping it here
    /// would walk the gap off centre and stand the riser against the fill on one
    /// side.
    func testTheGapMayStartOutsideTheTrackEarlyInAWindow() {
        for increased in [false, true] {
            let leading = MeterCut.leadingX(
                elapsed: 0,
                trackWidth: 200,
                increasedContrast: increased
            )
            XCTAssertEqual(
                leading, -MeterCut.width(increasedContrast: increased) / 2,
                accuracy: 0.0001,
                "increasedContrast \(increased)"
            )
            XCTAssertLessThan(leading, 0)
        }
    }

    /// Whatever it is handed, both answers reach a frame width as numbers. A
    /// NaN offset takes the row's layout with it, and the row it takes is one
    /// that was only reporting a percentage.
    ///
    /// An infinite *track* is left out on purpose, and it is the one case not
    /// claimed anywhere here: `notchX` saturates it rather than refusing it, so
    /// the gap saturates with it. That is the same concession `MeterFill` makes
    /// about an infinite proposal — SwiftUI does not hand either of them to a
    /// bar inside a row, and a guard for it would be a guard against nothing.
    /// The widths a real layout produces are these: a definite one, none yet,
    /// and the NaN a divide upstream turns into.
    func testNeitherEdgeIsEverNonFinite() {
        let fractions: [Double] = [-3, 0, 0.5, 1, 4, .nan, .infinity, -.infinity]
        let widths: [CGFloat] = [0, -1, .nan, 120, 340]
        for fraction in fractions {
            for width in widths {
                for increased in [false, true] {
                    let centre = MeterCut.centreX(elapsed: fraction, trackWidth: width)
                    let leading = MeterCut.leadingX(
                        elapsed: fraction,
                        trackWidth: width,
                        increasedContrast: increased
                    )
                    XCTAssertTrue(centre.isFinite, "centre \(centre) at \(fraction) on \(width)pt")
                    XCTAssertTrue(leading.isFinite, "leading \(leading) at \(fraction) on \(width)pt")
                }
            }
        }
    }
}

/// The riser's ink where it crosses the bar.
///
/// One function for both halves of one decision, because getting it backwards
/// is invisible in code and glaring on screen — and the wrong answer either way
/// is the same failure, a mark drawn in the colour of the thing behind it, which
/// is no mark at all. Resolved to hexes rather than compared as `Color`s: one of
/// the two answers is built fresh on each call under increased contrast, so
/// `==` would be asserting instance identity rather than colour.
final class MeterCutInkTests: XCTestCase {

    /// The only combination that takes the ground colour: the fill has covered
    /// the riser and no gap was punched for it, so the mark has to be what the
    /// fill is missing.
    func testAnUncutRiserUnderTheFillIsDrawnInTheGround() throws {
        for increased in [false, true] {
            let ink = MeterCut.markInk(
                isCut: false,
                coveredByFill: true,
                increasedContrast: increased
            )
            for dark in [false, true] {
                XCTAssertEqual(
                    try hex(ink, dark: dark), try hex(Tokens.Surface.onFill, dark: dark),
                    "increasedContrast \(increased), dark \(dark)"
                )
            }
        }
    }

    /// The other three all keep the notch colour. Inside a gap the riser stands
    /// on ground already, so drawing it in `Surface.onFill` there would be a
    /// ground-coloured mark on a ground-coloured slit.
    func testEveryOtherCombinationKeepsTheNotchColour() throws {
        let cases: [(isCut: Bool, coveredByFill: Bool)] = [
            (true, true),
            (true, false),
            (false, false)
        ]
        for increased in [false, true] {
            let expected = Tokens.notchColour(increased: increased)
            for state in cases {
                let ink = MeterCut.markInk(
                    isCut: state.isCut,
                    coveredByFill: state.coveredByFill,
                    increasedContrast: increased
                )
                for dark in [false, true] {
                    XCTAssertEqual(
                        try hex(ink, dark: dark), try hex(expected, dark: dark),
                        "isCut \(state.isCut), covered \(state.coveredByFill), dark \(dark)"
                    )
                }
            }
        }
    }

    /// Which is only a test while the two answers are different colours. If the
    /// notch ink ever resolved to the ground it is punched out of, every
    /// assertion above would pass and the mark would be invisible in both
    /// states.
    func testTheTwoInksAreNotTheSameColour() throws {
        for increased in [false, true] {
            for dark in [false, true] {
                XCTAssertNotEqual(
                    try hex(Tokens.notchColour(increased: increased), dark: dark),
                    try hex(Tokens.Surface.onFill, dark: dark),
                    "increasedContrast \(increased), dark \(dark)"
                )
            }
        }
    }

    /// And the ink follows the appearance rather than being one fixed value: the
    /// riser has to survive on both panel grounds, and the gap it stands in is
    /// the panel's own ground by definition.
    func testBothInksResolveDifferentlyInTheTwoAppearances() throws {
        for increased in [false, true] {
            XCTAssertNotEqual(
                try hex(Tokens.notchColour(increased: increased), dark: false),
                try hex(Tokens.notchColour(increased: increased), dark: true),
                "the riser is one fixed value in both appearances, increasedContrast \(increased)"
            )
        }
        XCTAssertNotEqual(
            try hex(Tokens.Surface.onFill, dark: false),
            try hex(Tokens.Surface.onFill, dark: true)
        )
    }

    // MARK: - Resolving

    /// `performAsCurrentDrawingAppearance` rather than assigning
    /// `NSAppearance.current`: the second is deprecated, and a deprecation
    /// warning is a build regression here.
    private func hex(_ color: Color, dark: Bool) throws -> UInt32 {
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        let srgb = try XCTUnwrap(resolved)
        func channel(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return channel(srgb.redComponent) << 16
             | channel(srgb.greenComponent) << 8
             | channel(srgb.blueComponent)
    }
}
