import XCTest
import AppKit
@testable import aibarsCore

/// The width contract.
///
/// The bug this file exists to close: the status item drew each figure at its
/// natural width, so one service crossing 99 into 100 widened the item by a
/// whole cell and shoved every icon to its left sideways. `StripFit.width` is
/// therefore a function of the segment *count* and the style's own cell, and that
/// is a claim about a signature as much as about arithmetic — so most of what
/// follows measures the same strip with two different readings in it and
/// insists the answer does not move.
///
/// Stated here at the shipped `markAndFigure`, which `StripFit` takes as its
/// default: this file owns the *fitting* rules — the count, the cap, the ranking —
/// and they are one set of rules however the segments are drawn.
/// `StripStyleWidthTests` is where the same invariant is run across all six.
///
/// It is all pure, so none of it needs a menu bar to look at. The one exception
/// is the cell-holds-the-figure test, which really does have to ask AppKit how
/// wide "100" is.
final class StripFitWidthTests: XCTestCase {
    /// The shipped `menuBarGlyphHeight`, and the height everything below is
    /// stated at unless it is testing a bound.
    private let shipped: CGFloat = 13

    /// The ends of `menuBarGlyphHeight`'s clamp: the narrowest and widest marks
    /// the settings can ask for.
    private let glyphHeights = Array(stride(from: CGFloat(10), through: 16, by: 1))

    private func entry(_ id: String, _ percent: Double?) -> MenuBarEntry {
        MenuBarEntry(serviceID: id, displayName: id.capitalized, percent: percent)
    }

    // MARK: - The bug

    /// Three services reading 92 and the same three reading 100 are the same
    /// strip. If this ever fails the item has gone back to measuring its
    /// content, and every icon to the left of it moves when a quota fills.
    func testWidthDoesNotMoveWhenAReadingCrossesOneHundred() {
        let ninetyTwo = ["claude", "gemini", "grok"].map { entry($0, 0.92) }
        let hundred = ["claude", "gemini", "grok"].map { entry($0, 1) }

        // The premise: these really are the two readings whose drawn widths
        // differ, so the assertion below is about the reservation rather than
        // about two strings that happen to measure the same.
        XCTAssertEqual(ninetyTwo.map(\.figure), ["92", "92", "92"])
        XCTAssertEqual(hundred.map(\.figure), ["100", "100", "100"])

        XCTAssertEqual(
            StripFit.width(segments: ninetyTwo.count, height: shipped),
            StripFit.width(segments: hundred.count, height: shipped),
            "the strip changed width when a service crossed 100"
        )
    }

    /// A service that reports no quota still occupies its cell. Collapsing the
    /// dash to its own width would make the strip breathe every time a
    /// status-only service came and went, which is the same jitter arriving by
    /// another door.
    func testWidthDoesNotMoveWhenAServiceReportsNoQuota() {
        let measured = [entry("claude", 0.92), entry("gemini", 0.4), entry("grok", 0.07)]
        let withDash = [entry("claude", 0.92), entry("chatgpt", nil), entry("grok", 0.07)]

        XCTAssertEqual(withDash[1].figure, MenuBarEntry.noFigure)
        XCTAssertEqual(
            StripFit.width(segments: measured.count, height: shipped),
            StripFit.width(segments: withDash.count, height: shipped),
            "an em dash reserved less than a reading"
        )
    }

    /// Every figure the strip can print, at every glyph height the setting
    /// allows, against one width. The loop is the point: a one-character
    /// reading, a three-character one and the dash are three different strings
    /// and none of them may reach the number.
    func testWidthIsTheSameForEveryReadingAtEveryGlyphHeight() {
        let readings: [Double?] = [nil, 0, 0.004, 0.5, 0.92, 0.999, 1]
        for height in glyphHeights {
            let reference = StripFit.width(segments: 3, height: height)
            for reading in readings {
                let entries = (0..<3).map { entry("s\($0)", reading) }
                XCTAssertEqual(
                    StripFit.width(segments: entries.count, height: height), reference,
                    "\(entries[0].figure) at \(height)pt measured differently"
                )
            }
        }
    }

    // MARK: - The reserved cell

    /// Stated against `Tokens.figureWidth` rather than against a literal, so the
    /// strip's cell and the column every other figure in the app is set in
    /// cannot drift apart. Three digits because "100" is the widest thing
    /// `MenuBarEntry.figure` produces, and one point under the mark because SF
    /// Mono's digits sit inside their line box and otherwise out-measure the
    /// logo beside them.
    func testFigureCellIsThreeMonospacedDigitsAtOneUnderTheMark() {
        for height in glyphHeights {
            XCTAssertEqual(
                StripFit.figureCell(height: height),
                Tokens.figureWidth(height - 1, digits: 3),
                "the strip's cell and Tokens' column disagree at \(height)pt"
            )
        }
        // The shipped height, spelled out: three tabular semibold digits at 12pt,
        // rounded up. It was 23 against SF Mono's single advance.
        XCTAssertEqual(StripFit.figureCell(height: shipped), 24)
    }

    /// The one thing arithmetic cannot settle: whether the cell actually holds
    /// the glyphs. A cell narrower than its string clips or ellipsises, and no
    /// amount of reserving fixes that. Measured at the weight and size the
    /// renderer draws at — semibold, one point under the mark — because a cell
    /// that fits a lighter face is not a cell that fits this one.
    func testTheReservedCellHoldsTheWidestFigureTheStripCanPrint() {
        for height in glyphHeights {
            let font = NSFont.monospacedSystemFont(ofSize: height - 1, weight: .semibold)
            let cell = StripFit.figureCell(height: height)
            for figure in ["100", "92", "0", MenuBarEntry.noFigure] {
                let drawn = (figure as NSString).size(withAttributes: [.font: font]).width
                XCTAssertGreaterThanOrEqual(
                    cell, drawn,
                    "\(figure) measures \(drawn) in a \(cell)pt cell at \(height)pt"
                )
            }
        }
    }

    /// A taller mark never buys a narrower cell, and a height the settings could
    /// never produce still yields something a layout can use.
    func testTheCellIsPositiveAndNeverShrinksAsTheMarkGrows() {
        var previous: CGFloat = 0
        for height in glyphHeights {
            let cell = StripFit.figureCell(height: height)
            XCTAssertGreaterThanOrEqual(cell, previous, "the cell narrowed at \(height)pt")
            previous = cell
        }
        for height in [CGFloat.nan, .infinity, -.infinity, .signalingNaN, 0, -1] {
            let cell = StripFit.figureCell(height: height)
            XCTAssertTrue(cell.isFinite, "height \(height) produced a cell of \(cell)")
            XCTAssertGreaterThan(cell, 0, "height \(height) reserved nothing")
        }
    }

    // MARK: - Growing

    func testWidthIsStrictlyMonotonicInTheSegmentCount() {
        for height in glyphHeights {
            for count in 1..<12 {
                XCTAssertGreaterThan(
                    StripFit.width(segments: count + 1, height: height),
                    StripFit.width(segments: count, height: height),
                    "segment \(count + 1) did not widen the strip at \(height)pt"
                )
            }
        }
    }

    /// One segment costs the same wherever it lands, which is what makes the cap
    /// solvable rather than something to accumulate towards.
    func testEachExtraSegmentCostsTheSame() {
        let pitch = StripFit.width(segments: 2, height: shipped)
            - StripFit.width(segments: 1, height: shipped)
        for count in 1..<12 {
            XCTAssertEqual(
                StripFit.width(segments: count + 1, height: shipped)
                    - StripFit.width(segments: count, height: shipped),
                pitch, accuracy: 0.0001,
                "segment \(count + 1) cost a different amount from segment 2"
            )
        }
    }

    /// Gaps go between segments, not around them. A strip that paid for a
    /// trailing gap would sit off-centre against its neighbours in the bar, and
    /// `(count - 1)` is exactly the sort of arithmetic that gets written as
    /// `count`.
    func testGapsGoBetweenSegmentsAndNotAroundThem() {
        let one = StripFit.width(segments: 1, height: shipped)
        XCTAssertEqual(
            StripFit.width(segments: 2, height: shipped),
            2 * one + StripFit.segmentGap, accuracy: 0.0001
        )
        XCTAssertEqual(
            StripFit.width(segments: 3, height: shipped),
            3 * one + 2 * StripFit.segmentGap, accuracy: 0.0001
        )
    }

    /// The gaps are what decide whether the strip reads as "mark, number, mark,
    /// number" or as one run of debris: a mark has to bind to its own figure
    /// before it binds to the neighbour's.
    func testAMarkBindsToItsOwnFigureBeforeItsNeighbour() {
        XCTAssertGreaterThan(StripFit.markGap, 0)
        XCTAssertGreaterThan(StripFit.segmentGap, StripFit.markGap)
    }

    // MARK: - Nothing, and less than nothing

    /// No segments is no strip, not one gap's worth of it. The negative cases
    /// are the arithmetic in `width` run backwards — `(count - 1) * gap` on a
    /// count of zero is where a missing guard shows up as a negative width, and
    /// `Int.min` is where converting the count first would trap.
    func testNoSegmentsMeasureNothing() {
        for count in [0, -1, -3, Int.min] {
            XCTAssertEqual(
                StripFit.width(segments: count, height: shipped), 0,
                "\(count) segments measured something"
            )
        }
    }

    // MARK: - The glyph-height bounds

    /// 10 and 16 are the ends of `menuBarGlyphHeight`'s clamp, so they are the
    /// narrowest and widest strips the settings can ask for.
    func testWidthAtBothGlyphHeightBoundsIsFinitePositiveAndOrdered() {
        let small = StripFit.width(segments: 3, height: 10)
        let large = StripFit.width(segments: 3, height: 16)
        for width in [small, large] {
            XCTAssertTrue(width.isFinite, "\(width) is not a width")
            XCTAssertGreaterThan(width, 0)
        }
        XCTAssertLessThan(small, large, "a taller mark did not widen the strip")
    }

    /// Three services at the shipped height is the configuration the strip was
    /// designed around, and the cap is only worth stating if the intended case
    /// clears it.
    func testThreeSegmentsFitTheBarAtTheShippedHeight() {
        XCTAssertGreaterThan(Tokens.Strip.maxWidth, 0)
        XCTAssertLessThanOrEqual(
            StripFit.width(segments: 3, height: shipped), Tokens.Strip.maxWidth,
            "the strip's own default configuration overflows its cap"
        )
        // Not asserted at every glyph height: a user who asks for a 16pt mark
        // and three services may legitimately lose the third to the cap, and
        // pinning that here would be pinning a preference rather than a
        // contract.
    }

    // MARK: - Untrusted heights

    /// `menuBarGlyphHeight` is clamped to 10…16 by the settings object, but
    /// `width` is public and pure and does not get to assume the settings are
    /// its only caller — the value reaches them from a store, which can hold
    /// whatever was last written to it. A non-finite height survives every `max`
    /// in the arithmetic and then traps in the rounding inside `figureWidth`, so
    /// it has to be turned away at the door.
    func testAHeightNoSettingCouldProduceStillMeasures() {
        for height in [CGFloat.nan, .infinity, -.infinity, .signalingNaN, 0, -1, -1000, .leastNonzeroMagnitude] {
            let width = StripFit.width(segments: 3, height: height)
            XCTAssertTrue(width.isFinite, "height \(height) produced \(width)")
            XCTAssertGreaterThan(width, 0, "height \(height) collapsed the strip to nothing")
        }
    }

    /// A height near the top of `Double` overflows the multiplication to
    /// infinity rather than trapping, which is harmless: it is still ordered,
    /// still not a NaN, and `fit` turns it into one segment. Recorded because
    /// "finite in, finite out" is not true here and a future reader should not
    /// have to rediscover why.
    func testAnEnormousHeightOverflowsRatherThanTraps() {
        let width = StripFit.width(segments: 1, height: .greatestFiniteMagnitude)
        XCTAssertFalse(width.isNaN)
        XCTAssertGreaterThan(width, Tokens.Strip.maxWidth)
    }

    /// The count is ours rather than a store's, but the multiplication is the
    /// same one and an overflow here would be a trap rather than a wide strip.
    func testAnEnormousSegmentCountDoesNotTrap() {
        let width = StripFit.width(segments: .max, height: shipped)
        XCTAssertFalse(width.isNaN)
        XCTAssertGreaterThan(width, StripFit.width(segments: 3, height: shipped))
    }
}

/// Which segments survive the cap.
///
/// Three things can cost a segment — the user's count, the style's own ceiling
/// and the width cap — and the count goes first, because it is a preference and
/// the other two are constraints. What comes back is a subsequence of what went
/// in: the least urgent are dropped, and the survivors keep the order they
/// arrived in, because a strip that reshuffled as one reading crossed a
/// neighbour's would be its own kind of jitter.
///
/// The ceiling is asserted in `StripStyleWidthTests`, where the styles that have
/// one live. Everything here runs at the shipped `markAndFigure`, whose ceiling is
/// three and therefore never the binding constraint — so what these measure is
/// the count and the cap, one at a time.
final class StripFitFittingTests: XCTestCase {
    private let shipped: CGFloat = 13

    private func entry(_ id: String, _ percent: Double?) -> MenuBarEntry {
        MenuBarEntry(serviceID: id, displayName: id.capitalized, percent: percent)
    }

    private func ids(_ entries: [MenuBarEntry]) -> [String] {
        entries.map(\.serviceID)
    }

    /// How many segments the cap leaves room for at `height`, counted from the
    /// public width rather than read off the private solver, so the two have to
    /// agree. Never fewer than one, which is the floor `fit` itself keeps.
    private func room(at height: CGFloat) -> Int {
        var count = 0
        while count < 64, StripFit.width(segments: count + 1, height: height) <= Tokens.Strip.maxWidth {
            count += 1
        }
        return max(1, count)
    }

    /// A glyph height at which the cap leaves room for exactly `count` segments.
    /// Width grows with the mark, so room falls as the scan climbs.
    private func height(withRoomFor count: Int) throws -> CGFloat {
        for height in stride(from: CGFloat(1), through: 600, by: 0.5) where room(at: height) == count {
            return height
        }
        throw XCTSkip("no glyph height leaves room for exactly \(count) segments")
    }

    // MARK: - The user's count

    func testFitNeverReturnsMoreThanTheLimit() {
        let candidates = ["claude", "gemini", "grok", "mistral"].map { entry($0, 0.5) }
        // The shipped height has room for three, pinned by
        // testThreeSegmentsFitTheBarAtTheShippedHeight.
        XCTAssertEqual(StripFit.fit(candidates, limit: 1, height: shipped).count, 1)
        XCTAssertEqual(StripFit.fit(candidates, limit: 2, height: shipped).count, 2)
        XCTAssertEqual(StripFit.fit(candidates, limit: 3, height: shipped).count, 3)
    }

    /// The limit reaches here from a settings store, which is untrusted: it can
    /// hold anything an `Int` can, and both ends are where a clamp written with
    /// the wrong comparison overflows instead of clamping.
    func testAnAbsurdLimitFromAStoreIsClampedToTheStripsRange() {
        let candidates = ["claude", "gemini", "grok", "mistral"].map { entry($0, 0.5) }
        for limit in [Int.min, -1, 0, 4, 99, Int.max] {
            let count = StripFit.fit(candidates, limit: limit, height: shipped).count
            XCTAssertTrue(
                MenuBarStripContent.range.contains(count),
                "limit \(limit) produced \(count) segments"
            )
        }
        // Zero must not produce an empty item: a status item with nothing in it
        // is one the user can neither find nor click.
        XCTAssertEqual(StripFit.fit(candidates, limit: 0, height: shipped).count, 1)
        XCTAssertEqual(StripFit.fit(candidates, limit: Int.max, height: shipped).count, 3)
        // The strip and the model that feeds it apply the same range, so a limit
        // at either end of it survives both unchanged.
        for limit in MenuBarStripContent.range {
            XCTAssertEqual(StripFit.fit(candidates, limit: limit, height: shipped).count, limit)
        }
    }

    func testFewerCandidatesThanTheLimitReturnsAllOfThemAndPadsNothing() {
        let chosen = StripFit.fit([entry("claude", 0.9)], limit: 3, height: shipped)
        XCTAssertEqual(ids(chosen), ["claude"])
    }

    /// The count is applied before the cap, so a fourth service is out on the
    /// preference and never gets weighed against the width — someone who asked
    /// for three does not get four because there happened to be room, and the
    /// most urgent service in the list does not walk in past the limit.
    func testTheCountIsAppliedBeforeTheWidth() {
        let candidates = [
            entry("gemini", 0.1), entry("claude", 0.92), entry("grok", 0.55), entry("mistral", 0.99)
        ]
        let chosen = StripFit.fit(candidates, limit: 3, height: shipped)
        XCTAssertEqual(ids(chosen), ["gemini", "claude", "grok"])
        XCTAssertFalse(
            ids(chosen).contains("mistral"),
            "a service past the user's count was let in on urgency"
        )
    }

    /// Two accounts of one service are the content model's problem, not this
    /// one's: `MenuBarStripContent` folds them before ranking, and duplicating
    /// that here would mean two places to change when the rule does. Stated so
    /// the silence is deliberate rather than an oversight.
    func testFitDoesNotFoldTwoAccountsOfOneService() {
        let candidates = [entry("claude", 0.92), entry("claude", 0.4)]
        XCTAssertEqual(StripFit.fit(candidates, limit: 3, height: shipped).count, 2)
        XCTAssertEqual(
            MenuBarStripContent.entries(from: candidates, limit: 3).count, 1,
            "the fold moved out of the content model without this test noticing"
        )
    }

    // MARK: - The width cap

    /// The heart of it: when the cap bites, the least urgent goes and the rest
    /// stay where they were.
    func testFitDropsTheLeastUrgentFirstAndKeepsSourceOrder() throws {
        let height = try height(withRoomFor: 2)
        let candidates = [entry("gemini", 0.1), entry("claude", 0.92), entry("grok", 0.55)]
        let chosen = StripFit.fit(candidates, limit: 3, height: height)

        XCTAssertEqual(ids(chosen), ["claude", "grok"], "the survivors were reordered by urgency")
        XCTAssertFalse(ids(chosen).contains("gemini"), "the least urgent service kept its slot")
    }

    /// Nothing is reordered when nothing has to be dropped either — the ranking
    /// is the caller's, and the panel underneath is in that order.
    func testFitLeavesTheOrderAloneWhenEverythingFits() {
        let candidates = [entry("gemini", 0.1), entry("claude", 0.92), entry("grok", 0.55)]
        XCTAssertEqual(
            ids(StripFit.fit(candidates, limit: 3, height: shipped)),
            ["gemini", "claude", "grok"]
        )
    }

    /// The cap is inclusive, and it is tight on both sides — stated as a
    /// property of what `fit` returns rather than as a number, so it holds at
    /// whatever `Tokens.Strip.maxWidth` becomes. What was drawn measures inside
    /// the cap, and what was refused would not have. The scan is fine enough to
    /// land on both sides of every transition, since a segment's cost rises with
    /// the mark by more than the step.
    func testTheCapIsInclusiveAndTightOnBothSides() {
        let candidates = [entry("gemini", 0.1), entry("claude", 0.92), entry("grok", 0.55)]
        var sawARefusal = false

        for height in stride(from: CGFloat(1), through: 600, by: 0.5) {
            let drawn = StripFit.fit(candidates, limit: 3, height: height).count
            if drawn > 1 {
                XCTAssertLessThanOrEqual(
                    StripFit.width(segments: drawn, height: height), Tokens.Strip.maxWidth,
                    "\(drawn) segments were drawn at \(height)pt and they overflow the cap"
                )
            }
            if drawn < 3 {
                sawARefusal = true
                XCTAssertGreaterThan(
                    StripFit.width(segments: drawn + 1, height: height), Tokens.Strip.maxWidth,
                    "a segment that would have fitted was refused at \(height)pt"
                )
            }
        }

        XCTAssertTrue(sawARefusal, "the cap never bit, so neither side of it was tested")
    }

    /// An em dash tells you nothing about how close you are to a cap, so it can
    /// never take a slot from something that does — including from a service
    /// sitting at zero, which at least is a measurement. A NaN arrives from
    /// provider JSON as no reading at all and sorts with the dashes.
    func testStatusOnlyServicesAreDroppedBeforeAnyMeteredOne() throws {
        let height = try height(withRoomFor: 2)
        let candidates = [entry("chatgpt", nil), entry("gemini", 0), entry("copilot", .nan)]
        XCTAssertNil(candidates[2].percent, "a NaN was kept as a reading")

        let chosen = StripFit.fit(candidates, limit: 3, height: height)
        XCTAssertEqual(chosen.count, 2)
        XCTAssertTrue(ids(chosen).contains("gemini"), "a measurement of zero was dropped for a dash")
        XCTAssertFalse(ids(chosen).contains("copilot"), "a dash outlived the reading it was ranked under")
        // Which survives is the ranking question; where it draws is not. The dash
        // that lived through the drop still draws ahead of the reading that
        // outranked it, because survivors go back into arrival order.
        XCTAssertEqual(ids(chosen), ["chatgpt", "gemini"])
    }

    /// Status-only services do not rank against each other, so when only they
    /// are left the arrival order decides — and it has to decide the same way
    /// every refresh.
    func testTwoStatusOnlyServicesKeepTheirArrivalOrder() throws {
        let height = try height(withRoomFor: 2)
        let candidates = [entry("chatgpt", nil), entry("copilot", nil), entry("cursor", nil)]
        XCTAssertEqual(ids(StripFit.fit(candidates, limit: 3, height: height)), ["chatgpt", "copilot"])
    }

    /// Two services level with each other must not swap places between
    /// refreshes: `sorted` is not stable, so arrival order has to be the
    /// tiebreak, and repeating the call is how that becomes visible.
    func testLevelServicesKeepTheirArrivalOrderAcrossRefreshes() throws {
        let height = try height(withRoomFor: 2)
        let candidates = [entry("gemini", 0.4), entry("claude", 0.4), entry("grok", 0.4)]
        let first = ids(StripFit.fit(candidates, limit: 3, height: height))
        XCTAssertEqual(first, ["gemini", "claude"])
        for _ in 0..<50 {
            XCTAssertEqual(
                ids(StripFit.fit(candidates, limit: 3, height: height)), first,
                "the strip reshuffled between two identical refreshes"
            )
        }
    }

    /// The boundary the ranking turns on: 0.9 against 0.9000001 is a real
    /// ordering, and 0.9 against 0.9 is not one at all.
    func testTheSmallestDifferenceInAReadingStillOrdersTwoServices() throws {
        let height = try height(withRoomFor: 1)
        let nudged = 0.9.nextUp
        XCTAssertGreaterThan(nudged, 0.9, "the premise failed: the two readings are the same double")

        XCTAssertEqual(
            ids(StripFit.fit([entry("gemini", 0.9), entry("claude", nudged)], limit: 3, height: height)),
            ["claude"]
        )
        XCTAssertEqual(
            ids(StripFit.fit([entry("gemini", nudged), entry("claude", 0.9)], limit: 3, height: height)),
            ["gemini"]
        )
    }

    /// A glyph height so large that one segment already overflows the cap. One
    /// wide item is worse than nothing only in arithmetic: an empty status item
    /// cannot be found or clicked, so the floor is one and the service closest
    /// to its cap is the one that earns it.
    func testFitReturnsOneSegmentRatherThanNoneWhenEvenOneIsTooWide() {
        let height: CGFloat = 10_000
        XCTAssertGreaterThan(
            StripFit.width(segments: 1, height: height), Tokens.Strip.maxWidth,
            "the premise failed: one segment still fits at \(height)pt"
        )
        let candidates = [entry("gemini", 0.1), entry("claude", 0.92), entry("grok", 0.55)]
        XCTAssertEqual(ids(StripFit.fit(candidates, limit: 3, height: height)), ["claude"])
    }

    // MARK: - The general property

    /// What the two rules amount to, across every height the cap can bite at:
    /// the result is a subsequence of the first `limit` entries, it is as long
    /// as the room allows, and nothing dropped was more urgent than anything
    /// kept.
    func testFitIsAlwaysTheMostUrgentSubsequenceThatFits() {
        let candidates = [
            entry("gemini", 0.1), entry("claude", 0.92), entry("grok", 0.55),
            entry("chatgpt", nil), entry("mistral", 0.7)
        ]
        for limit in MenuBarStripContent.range {
            for height in stride(from: CGFloat(10), through: 120, by: 0.5) {
                let capped = Array(candidates.prefix(limit))
                let chosen = StripFit.fit(candidates, limit: limit, height: height)
                let context = "limit \(limit) at \(height)pt"

                XCTAssertEqual(
                    chosen.count, min(limit, room(at: height)),
                    "\(context) drew \(chosen.count) segments"
                )

                // A subsequence: every survivor came from the capped input, and
                // they are still in the order they arrived in.
                var cursor = 0
                for survivor in chosen {
                    guard let index = capped[cursor...].firstIndex(of: survivor) else {
                        return XCTFail("\(context) produced \(survivor.serviceID) out of order")
                    }
                    cursor = index + 1
                }

                // Nothing dropped outranked anything kept, with arrival order as
                // the tiebreak.
                let kept = Set(chosen.map(\.serviceID))
                for (keptIndex, k) in capped.enumerated() where kept.contains(k.serviceID) {
                    for (dropIndex, d) in capped.enumerated() where !kept.contains(d.serviceID) {
                        let a = k.percent ?? -1, b = d.percent ?? -1
                        XCTAssertTrue(
                            a > b || (a == b && keptIndex < dropIndex),
                            "\(context) kept \(k.serviceID) over \(d.serviceID)"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Nothing to fit

    /// The state on first launch, before anything has answered. The floor of one
    /// applies to what the caller had, not to what it wished for: a placeholder
    /// here would draw a mark for a service that is not there.
    func testNoCandidatesReturnsNothingRatherThanTrapping() {
        for limit in [Int.min, 0, 1, 3, Int.max] {
            XCTAssertTrue(
                StripFit.fit([], limit: limit, height: shipped).isEmpty,
                "an empty strip was padded at limit \(limit)"
            )
        }
        XCTAssertTrue(StripFit.fit([], limit: 3, height: .nan).isEmpty)
        XCTAssertTrue(StripFit.fit([], limit: 3, height: 10_000).isEmpty)
    }

    // MARK: - Untrusted heights

    /// The same door `width` guards. A non-finite height must not reach the
    /// rounding inside `figureWidth`, and a height that overflows the pitch to
    /// infinity must still leave the floor of one standing rather than divide
    /// its way to zero segments.
    func testAHeightNoSettingCouldProduceStillFits() {
        let candidates = [entry("gemini", 0.1), entry("claude", 0.92), entry("grok", 0.55)]
        let heights: [CGFloat] = [
            .nan, .infinity, -.infinity, .signalingNaN, 0, -1, -1000,
            .greatestFiniteMagnitude, .leastNonzeroMagnitude
        ]
        for height in heights {
            let chosen = StripFit.fit(candidates, limit: 3, height: height)
            XCTAssertTrue(
                MenuBarStripContent.range.contains(chosen.count),
                "height \(height) produced \(chosen.count) segments"
            )
            XCTAssertTrue(
                chosen.allSatisfy { candidates.contains($0) },
                "height \(height) produced a segment nobody asked for"
            )
        }
    }
}
