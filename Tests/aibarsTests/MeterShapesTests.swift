import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

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

/// Where a reading becomes a length.
///
/// The bar and the dial draw the same number, so the arithmetic that turns a
/// percentage into a length is shared — and these are about the one property
/// that makes it worth sharing: what the eye measures has to be what the figure
/// on the same line says.
final class MeterGeometryTests: XCTestCase {

    // MARK: - The bar

    /// A reading of nothing draws nothing. An empty track is how the panel says
    /// 0%, and a floor applied blindly would leave a stub behind on it.
    func testAZeroReadingDrawsNoFill() {
        XCTAssertEqual(MeterGeometry.fillWidth(percent: 0, track: 278, thickness: 5), 0)
    }

    /// The floor is two thicknesses, so the shortest fill is a stub with a
    /// direction rather than the round-capped dot one thickness produced — and a
    /// dot is identical at 0.5% and at 1%, which is a meter that has stopped
    /// measuring.
    func testTheShortestFillIsTwoThicknessesAndNeverACircle() {
        for percent in [0.001, 0.005, 0.01, 0.02] {
            XCTAssertEqual(
                MeterGeometry.fillWidth(percent: percent, track: 278, thickness: 5),
                10,
                accuracy: 0.001,
                "\(percent) should sit on the floor"
            )
        }
    }

    /// Above the floor the fill is the reading, and nothing else.
    func testAboveTheFloorTheBarIsTheReading() {
        XCTAssertEqual(
            MeterGeometry.fillWidth(percent: 0.5, track: 278, thickness: 5),
            139,
            accuracy: 0.001
        )
    }

    /// A budget can be walked past; a fill cannot walk past its track.
    func testTheFillIsClampedToTheTrack() {
        XCTAssertEqual(
            MeterGeometry.fillWidth(percent: 2.11, track: 278, thickness: 5),
            278,
            accuracy: 0.001
        )
    }

    // MARK: - How long the track is

    /// The track's length at every panel the width slider offers, recorded rather
    /// than bounded.
    ///
    /// The columns are the arithmetic `RowGeometry` does — panel less two 12pt
    /// gutters less the 28pt leading column at the shipped logo size and no dial —
    /// so these are the four widths a user can actually put the panel at and the
    /// lengths they produce. Recorded because both ends of the clamp are load
    /// bearing and each fails differently: the floor keeps the shipped panel's bar
    /// exactly where it was, and the ceiling is where the bar starts out-resolving
    /// the figure it illustrates.
    func testTheTrackGrowsWithTheColumnBetweenItsFloorAndItsCeiling() {
        let expected: [(panel: CGFloat, column: CGFloat, track: CGFloat)] = [
            (300, 248, 160),
            (356, 304, 160),
            (420, 368, 184),
            (520, 468, 200)
        ]
        for row in expected {
            XCTAssertEqual(
                MeterGeometry.trackWidth(in: row.column), row.track, accuracy: 0.001,
                "a \(row.panel)pt panel has a \(row.column)pt column and draws "
                    + "\(MeterGeometry.trackWidth(in: row.column))pt of track"
            )
        }
    }

    /// The shipped panel's bar did not move, and that is the half of this change
    /// that has to be asserted rather than eyeballed.
    ///
    /// The whole argument for a growing track is that capping it flat at 160 "was
    /// right at the default width and wrong above it", so a change that also moved
    /// the default would have answered a different complaint. Half the column
    /// reaches the floor at 320pt of column — a 376pt panel — so every width from
    /// the slider's bottom up past the shipped 356 draws the same 160 it always
    /// did.
    func testEveryPanelUpToTheDefaultDrawsTheSameSixtyPointTrackItAlwaysDid() {
        for column in stride(from: 200.0, through: 320.0, by: 4) {
            XCTAssertEqual(
                MeterGeometry.trackWidth(in: CGFloat(column)), MeterGeometry.trackFloor,
                "a \(column)pt column moved the shipped bar"
            )
        }
        // And the first column that does not: 322 is over twice the floor, so the
        // bar starts growing at 161 rather than jumping.
        XCTAssertEqual(MeterGeometry.trackWidth(in: 322), 161, accuracy: 0.001)
    }

    /// The ceiling is the resolution bound, and it is stated as arithmetic rather
    /// than as a constant so that moving one moves the other.
    ///
    /// The figure two columns from the bar prints whole percent. `trackFloor`'s
    /// third argument is that the bar must not resolve more than twice as finely
    /// as that — 160pt moves 1.6pt per point of reading, and the 304pt bar this
    /// replaced moved 3.04, "three times finer than the reading it illustrates".
    /// At the ceiling the bar moves exactly 2pt per point, which is the factor of
    /// two exactly, so this is the widest a track can be and still be honest.
    func testTheCeilingIsWhereTheBarWouldStartOutResolvingItsOwnFigure() {
        let ceiling = MeterGeometry.trackWidth(in: 10_000)
        XCTAssertEqual(ceiling, MeterGeometry.trackCeiling)
        // One point of reading, in points of bar.
        XCTAssertEqual(ceiling / 100, 2, accuracy: 0.001)
        // Which is the factor of two the floor's own doc claims for 160.
        XCTAssertEqual(MeterGeometry.trackFloor / 100, 1.6, accuracy: 0.001)
    }

    /// A column narrower than the floor draws the column, not the floor.
    ///
    /// The floor is a floor for the *bar* and not a claim about the row it is in,
    /// and the case is reachable: a 300pt panel at 130% type with a 40pt logo and a
    /// dial beside it leaves under 160pt of column. A bar that insisted on its
    /// floor there would be the overhang `PanelWidthContractTests` exists to stop.
    func testTheTrackNeverOutgrowsTheColumnItIsIn() {
        for column in [1.0, 40.0, 120.0, 159.0] {
            XCTAssertEqual(
                MeterGeometry.trackWidth(in: CGFloat(column)), CGFloat(column), accuracy: 0.001,
                "a \(column)pt column drew more track than it has"
            )
        }
    }

    /// A length that is not a length draws nothing, rather than surviving into a
    /// frame width. The same guard `fillWidth` and `ringTrim` keep, and for the
    /// same reason: this one is read off a `GeometryReader`, so a view laid out
    /// before its container has resolved can propose anything at all.
    func testANonFiniteColumnDrawsNoTrack() {
        for column in [CGFloat.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertEqual(MeterGeometry.trackWidth(in: column), 0)
        }
    }

    // MARK: - The dial

    /// What `ringTrim` returns is what gets *painted*, and that is the whole
    /// point of it: a round cap adds half a stroke of paint past each end of a
    /// trim, so a dial that trimmed to its reading painted a full stroke more
    /// than it said — 9.4 points of a 22pt dial at the shipped 5pt bar. The
    /// figure two columns away was printing the truth the whole time, and a
    /// meter may not disagree with the number beside it.
    func testAboveTheFloorTheDialIsTheReading() {
        for reading in [0.25, 0.5, 0.75, 0.9] {
            XCTAssertEqual(
                MeterGeometry.ringTrim(percent: reading, diameter: 22, stroke: 5),
                reading,
                accuracy: 0.0001,
                "\(reading) should be painted as itself"
            )
        }
    }

    /// The dial's floor is the bar's floor: two strokes of painted arc, which is
    /// exactly the mark it drew before — a one-stroke trim between two caps — so
    /// the smallest reading looks as it did.
    func testTheDialsFloorIsTwoStrokesOfPaintedArc() {
        let cap = MeterGeometry.ringCapFraction(diameter: 22, stroke: 5)
        XCTAssertEqual(cap, 5 / (Double.pi * 17), accuracy: 0.0001)
        for reading in [0.001, 0.01, 0.07] {
            XCTAssertEqual(
                MeterGeometry.ringTrim(percent: reading, diameter: 22, stroke: 5),
                2 * cap,
                accuracy: 0.0001,
                "\(reading) should sit on the floor"
            )
        }
    }

    /// Zero draws no arc at all: the caller checks for it, and the track alone
    /// says nothing has been used.
    func testAZeroReadingDrawsNoArc() {
        XCTAssertEqual(MeterGeometry.ringTrim(percent: 0, diameter: 22, stroke: 5), 0)
        XCTAssertEqual(MeterGeometry.ringTrim(percent: -1, diameter: 22, stroke: 5), 0)
    }

    /// Neither meter may be taken down by a NaN, an infinity or a zero
    /// dimension: a percentage over a zero limit is exactly where one comes
    /// from, and `min`/`max` both lose to a NaN.
    func testNeitherMeterSurvivesANonFiniteReadingAsALength() {
        for bad in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(MeterGeometry.fillWidth(percent: bad, track: 278, thickness: 5), 0)
            XCTAssertEqual(MeterGeometry.ringTrim(percent: bad, diameter: 22, stroke: 5), 0)
        }
        XCTAssertEqual(MeterGeometry.fillWidth(percent: 0.5, track: .nan, thickness: 5), 0)
        XCTAssertEqual(MeterGeometry.ringTrim(percent: 0.5, diameter: .nan, stroke: 5), 0)
        XCTAssertEqual(MeterGeometry.ringCapFraction(diameter: 22, stroke: .nan), 0)
    }

    /// A dial cannot be filled past full, however far past its line a budget is.
    func testTheDialIsClampedToFull() {
        XCTAssertEqual(MeterGeometry.ringTrim(percent: 2.11, diameter: 22, stroke: 5), 1)
    }
}
