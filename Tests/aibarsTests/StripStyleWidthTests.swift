import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// The width invariant, once per style.
///
/// `StripFitWidthTests` proved it for the one strip the app used to draw: a
/// service crossing 99 into 100 must not widen the status item and shove every
/// icon to its left sideways. Six styles is six fresh chances to size a cell from
/// the string in hand — and one of them, `worstOnly`, draws a *word*, which
/// changes when one service overtakes another and is the 99 → 100 bug arriving
/// through a wider door.
///
/// So the loop is the point rather than an economy: every style, every whole-point
/// height the settings allow, every segment count, every reading from 0 to 100 and
/// the no-quota case — against one number per (style, height, count).
final class StripStyleWidthTests: XCTestCase {
    /// The ends of `menuBarGlyphHeight`'s clamp. Whole points only, because the
    /// tuner steps by one and `normalize()` rounds anything a previous build left
    /// in the store.
    private let heights: [CGFloat] = Array(stride(from: CGFloat(10), through: 16, by: 1))
    private let styles = AppearanceSettings.MenuBarStyle.allCases
    private let counts = Array(MenuBarStripContent.range)

    /// 0…100 as the percentages the strip can be handed, plus the shape that has
    /// no percentage at all.
    private var readings: [Double?] { (0...100).map { Double($0) / 100 } + [nil] }

    private func entries(_ count: Int, _ percent: Double?) -> [MenuBarEntry] {
        (0..<count).map {
            MenuBarEntry(serviceID: "s\($0)", displayName: "Service \($0)", percent: percent)
        }
    }

    private func box(_ style: AppearanceSettings.MenuBarStyle) -> StripStyleBox {
        StripStyleBox.box(for: style)
    }

    // MARK: - T1, the invariant

    /// 6 styles × 7 heights × 3 counts × 102 readings = 12,852 measurements
    /// against 126 reference widths. All pure, so it costs milliseconds.
    func testWidthIsTheSameForEveryReadingOfEveryStyleAtEveryHeight() {
        for style in styles {
            let box = box(style)
            for height in heights {
                for count in counts {
                    let reference = StripFit.width(segments: count, style: box, height: height)
                    for reading in readings {
                        let entries = entries(count, reading)
                        XCTAssertEqual(
                            StripFit.width(segments: entries.count, style: box, height: height),
                            reference,
                            """
                            \(style.rawValue) at \(height)pt × \(count) measured differently \
                            for \(entries[0].figure)
                            """
                        )
                    }
                }
            }
        }
    }

    // MARK: - T2, the premise

    /// T1 is about the reservation and not about a hundred strings that happen to
    /// measure the same, so the strings it varies really do have to differ.
    func testTheReadingsTheInvariantIsAssertedOverReallyDoDiffer() {
        XCTAssertEqual(entries(1, 0.99).first?.figure, "99")
        XCTAssertEqual(entries(1, 1).first?.figure, "100")
        XCTAssertEqual(entries(1, nil).first?.figure, MenuBarEntry.noFigure)

        // Three strings, three different drawn widths, one reserved cell: 7.418pt
        // for the em dash, 14.836 for "99" and 22.254 for "100", all inside the
        // 23pt `figureCell` at the shipped height. A third of the cell separates
        // the narrowest from the widest, which is the size of the jitter the
        // reservation is standing in the way of.
        let font = NSFont.monospacedSystemFont(
            ofSize: Tokens.Strip.figureSize(height: 13), weight: .semibold
        )
        let widths = [MenuBarEntry.noFigure, "99", "100"].map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }
        XCTAssertEqual(
            Set(widths.map { ($0 * 100).rounded() }).count, 3,
            "the three drawn strings measure \(widths) — three distinct widths were expected"
        )
        XCTAssertEqual(widths, widths.sorted(), "the dash is no longer the narrowest of the three")
        XCTAssertGreaterThanOrEqual(
            Tokens.Strip.figureCell(height: 13), widths.last ?? 0,
            "the widest of the three does not fit the cell they share"
        )
    }

    // MARK: - T3, the drawn width

    /// The arithmetic is worth nothing if the rasteriser then ignores it.
    ///
    /// Every style, every height and every count — but the readings are sampled
    /// rather than exhaustive: the digit-count boundaries plus both ends. 102
    /// readings would be 12,852 rasterisations for coverage T1 already has purely,
    /// and this side only has to prove the rasteriser honours the arithmetic.
    @MainActor
    func testTheRasterisedWidthIsTheArithmeticRoundedUp() {
        let sampled: [Double?] = [0, 0.01, 0.09, 0.10, 0.5, 0.89, 0.90, 0.99, 1, nil]
        for style in styles {
            for height in heights {
                for count in counts {
                    let widths = Set(sampled.map { reading -> CGFloat in
                        MenuBarStripRenderer.image(
                            entries: entries(count, reading), height: height,
                            colour: .perBar, warningThreshold: 0.85,
                            style: style, coloursMarks: true
                        ).size.width
                    })
                    XCTAssertEqual(
                        widths.count, 1,
                        """
                        \(style.rawValue) at \(height)pt × \(count) rasterised at \
                        \(widths.sorted()) across its readings
                        """
                    )
                    // What the strip actually draws, which the style's ceiling and
                    // the width cap may both have cut down — the image is measured
                    // against the number `StripFit` predicts for the *fitted*
                    // count, not for the count that was asked for.
                    let drawn = StripFit.fit(
                        entries(count, 0.5), limit: count, style: box(style), height: height
                    ).count
                    XCTAssertEqual(
                        widths.first,
                        StripFit.width(segments: drawn, style: box(style), height: height)
                            .rounded(.up),
                        """
                        \(style.rawValue) at \(height)pt × \(count) drew \
                        \(widths.first ?? -1) for \(drawn) segments
                        """
                    )
                }
            }
        }
    }

    // MARK: - T4, the reserved cells hold their content

    /// `worstOnly` is the one style whose rail holds a word, so it is the one
    /// where "reserved" and "wide enough" are separate claims. Measured at the
    /// face and weight the style draws — SF Pro semibold, one point under the mark
    /// — because a rail that fits a lighter face is not a rail that fits this one.
    ///
    /// One documented exception, and it is why `nameDigits` is twelve rather than
    /// thirteen: thirteen measures 121 + 3 + 28 = 152pt at a 16pt mark and
    /// overflows the 148pt cap by four. The cost of twelve is one name at one
    /// height, and it takes a tail ellipsis rather than clipping.
    func testTheNameRailHoldsEveryShippedServiceName() {
        let names = [
            "ChatGPT", "Claude Code", "Claude", "Codex", "GitHub Copilot", "DeepSeek",
            "Cursor", "Grok", "Gemini", "MiniMax", "Mistral", "OpenRouter", "OpenCode",
            "Perplexity", "Z.ai"
        ]
        for height in heights {
            let font = NSFont.systemFont(
                ofSize: Tokens.Strip.figureSize(height: height), weight: .semibold
            )
            let rail = Tokens.Strip.nameCell(height: height)
            for name in names {
                let drawn = (name as NSString).size(withAttributes: [.font: font]).width
                // No exception any more. "GitHub Copilot" at a 10pt mark used to
                // be the one shipped name that overflowed its rail — by under a
                // point, documented at `Strip.nameDigits` as a tail ellipsis —
                // and the face change widened the cell past it. Every name clears
                // every rail now, so the case that used to be carved out is
                // asserted like the rest.
                XCTAssertGreaterThanOrEqual(
                    rail, drawn, "\(name) measures \(drawn) in a \(rail)pt rail at \(height)pt"
                )
            }
        }
    }

    /// The same claim for the figure cell, at every style that prints one. Three
    /// digits because "100" is the widest thing `MenuBarEntry.figure` produces.
    func testTheFigureCellHoldsTheWidestReadingAtEveryHeight() {
        for height in heights {
            let font = NSFont.monospacedSystemFont(
                ofSize: Tokens.Strip.figureSize(height: height), weight: .semibold
            )
            let cell = Tokens.Strip.figureCell(height: height)
            for figure in ["100", "92", "0", MenuBarEntry.noFigure] {
                let drawn = (figure as NSString).size(withAttributes: [.font: font]).width
                XCTAssertGreaterThanOrEqual(
                    cell, drawn, "\(figure) measures \(drawn) in a \(cell)pt cell at \(height)pt"
                )
            }
        }
    }

    // MARK: - T5, the cap

    /// Past 148pt the item stops being an indicator and starts pushing other
    /// people's status items off the right of a notched laptop. This is the test
    /// that fails if `nameDigits` is ever raised to thirteen.
    func testNoStyleOverflowsTheCapAtTheCountItWillActuallyDraw() {
        for style in styles {
            let box = box(style)
            for height in heights {
                let drawn = StripFit.fit(
                    entries(3, 0.5), limit: 3, style: box, height: height
                ).count
                XCTAssertLessThanOrEqual(
                    StripFit.width(segments: drawn, style: box, height: height),
                    Tokens.Strip.maxWidth,
                    "\(style.rawValue) drew \(drawn) segments at \(height)pt and overflowed the bar"
                )
            }
        }
    }

    // MARK: - T6, the ceilings

    /// Two styles speak for one service by construction, and the ceiling is what
    /// makes that a property of the style rather than a thing each preset has to
    /// remember to set.
    func testTheSingleServiceStylesNeverDrawASecond() {
        for style in [AppearanceSettings.MenuBarStyle.figureOnly, .worstOnly] {
            XCTAssertEqual(box(style).segmentCeiling, 1)
            for height in heights {
                XCTAssertEqual(
                    StripFit.fit(entries(3, 0.5), limit: 3, style: box(style), height: height).count,
                    1,
                    "\(style.rawValue) drew more than one service at \(height)pt"
                )
            }
        }
        for style in [AppearanceSettings.MenuBarStyle.markAndFigure, .markOnly, .microBars, .markAndMeter] {
            XCTAssertEqual(box(style).segmentCeiling, 3, "\(style.rawValue)")
        }
    }

    /// And the one it keeps is the one nearest its cap — the whole promise of the
    /// style's name. `StripFit` ranks and then restores arrival order, so the
    /// survivor being second in the list is the case worth feeding it.
    func testTheOneServiceKeptIsTheOneNearestItsCap() {
        let candidates = [
            MenuBarEntry(serviceID: "gemini", displayName: "Gemini", percent: 0.10),
            MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: 0.92),
            MenuBarEntry(serviceID: "grok", displayName: "Grok", percent: 0.40)
        ]
        for height in heights {
            XCTAssertEqual(
                StripFit.fit(candidates, limit: 3, style: box(.worstOnly), height: height)
                    .map(\.serviceID),
                ["claude"],
                "worstOnly kept the wrong service at \(height)pt"
            )
        }
    }

    // MARK: - T7, the two mark-box styles

    /// The claim the shared `segmentGap` was chosen to make true: switching
    /// between marks and micro bars moves no neighbouring status item. An earlier
    /// draft gave the bars a tighter gap and the two would have disagreed by 4pt
    /// at three services.
    func testMarksOnlyAndMicroBarsMeasureIdentically() {
        for height in heights {
            for count in counts {
                XCTAssertEqual(
                    StripFit.width(segments: count, style: box(.markOnly), height: height),
                    StripFit.width(segments: count, style: box(.microBars), height: height),
                    "the two mark-box styles disagree at \(height)pt × \(count)"
                )
            }
        }
    }

    // MARK: - T8, whole points

    /// The 1×/2× guarantee, stated as an assertion rather than as a paragraph.
    /// Every quantity in the strip is the output of a rounding on a `CGFloat`, the
    /// gaps are the integers 3 and 5, and a width is a sum of those — so every
    /// boundary in every style lands on one device pixel at 1× and two at 2×.
    func testEveryQuantityInEveryStyleIsAWholePoint() {
        for height in heights {
            let quantities: [(String, CGFloat)] = [
                ("markBox", Tokens.Strip.markBox(height: height)),
                ("figureSize", Tokens.Strip.figureSize(height: height)),
                ("figureCell", Tokens.Strip.figureCell(height: height)),
                ("nameCell", Tokens.Strip.nameCell(height: height)),
                ("meterColumn", Tokens.Strip.meterColumn(height: height)),
                ("barePlot", Tokens.Strip.barePlot(height: height)),
                ("meterPlot.baseline", Tokens.Strip.meterPlot(height: height).baseline),
                ("meterPlot.gap", Tokens.Strip.meterPlot(height: height).gap),
                ("meterPlot.plot", Tokens.Strip.meterPlot(height: height).plot)
            ]
            for (name, value) in quantities {
                XCTAssertEqual(value, value.rounded(), "\(name) is \(value) at \(height)pt")
            }
            // The plot fills the box exactly, which is what lets `microBars`
            // bottom-pad its column by baseline + gap and land on the box's top.
            let plot = Tokens.Strip.meterPlot(height: height)
            XCTAssertEqual(
                plot.baseline + plot.gap + plot.plot, Tokens.Strip.markBox(height: height),
                "the micro-bar plot does not fill its box at \(height)pt"
            )
            for style in styles {
                for count in counts {
                    let width = StripFit.width(segments: count, style: box(style), height: height)
                    XCTAssertEqual(
                        width, width.rounded(),
                        "\(style.rawValue) measures \(width) at \(height)pt × \(count)"
                    )
                }
            }
        }
    }

    /// The shipped height, written out, so a change to `Tokens.Strip` that keeps
    /// every quantity whole but moves them all still fails something. Both halves
    /// of each sum, per the rule the geometry tests in this suite follow.
    func testTheShippedHeightMeasuresWhatTheTableSays() {
        let h: CGFloat = 13
        XCTAssertEqual(Tokens.Strip.markBox(height: h), 13)
        // Three and twelve tabular semibold digits at 12pt, measured off the
        // face rather than off a ratio. 23 and 90 while the figures were SF Mono.
        XCTAssertEqual(Tokens.Strip.figureCell(height: h), 24)
        XCTAssertEqual(Tokens.Strip.nameCell(height: h), 95)
        XCTAssertEqual(Tokens.Strip.meterColumn(height: h), 5)   // (13 * 0.38).rounded() = 5
        XCTAssertEqual(Tokens.Strip.barePlot(height: h), 11)     // 13 - 2

        XCTAssertEqual(MarkAndFigureStyle.cellWidth(height: h), 40)  // 13 + 3 + 24
        XCTAssertEqual(FigureOnlyStyle.cellWidth(height: h), 24)
        XCTAssertEqual(MarkOnlyStyle.cellWidth(height: h), 13)
        XCTAssertEqual(MicroBarsStyle.cellWidth(height: h), 13)
        XCTAssertEqual(MarkAndMeterStyle.cellWidth(height: h), 21)   // 13 + 3 + 5
        XCTAssertEqual(WorstOnlyStyle.cellWidth(height: h), 122)     // 95 + 3 + 24

        // Three services, which is the configuration the strip was designed
        // around: 3 * 40 + 2 * 5 = 130, and 3 * 13 + 2 * 5 = 49.
        XCTAssertEqual(StripFit.width(segments: 3, style: box(.markAndFigure), height: h), 130)
        XCTAssertEqual(StripFit.width(segments: 3, style: box(.markOnly), height: h), 49)
        XCTAssertEqual(StripFit.width(segments: 3, style: box(.markAndMeter), height: h), 73)
    }

    // MARK: - T9, untrusted heights

    /// `menuBarGlyphHeight` is clamped to 10…16 by the settings object, but every
    /// one of these functions is public and pure and does not get to assume the
    /// settings are its only caller — the value reaches them from a store, which
    /// can hold whatever was last written to it. A non-finite height survives
    /// every `max` in the arithmetic and then traps in the rounding inside
    /// `figureWidth`, so it has to be turned away at the door of each style.
    func testAHeightNoSettingCouldProduceStillMeasuresInEveryStyle() {
        let hostile: [CGFloat] = [
            .nan, .infinity, -.infinity, .signalingNaN, 0, -1, -1000, .leastNonzeroMagnitude
        ]
        for style in styles {
            for height in hostile {
                let width = StripFit.width(segments: 3, style: box(style), height: height)
                XCTAssertTrue(width.isFinite, "\(style.rawValue) produced \(width) at height \(height)")
                XCTAssertGreaterThan(
                    width, 0, "\(style.rawValue) collapsed to nothing at height \(height)"
                )
                XCTAssertTrue(
                    MenuBarStripContent.range.contains(
                        StripFit.fit(entries(3, 0.5), limit: 3, style: box(style), height: height).count
                    ),
                    "\(style.rawValue) fitted an impossible count at height \(height)"
                )
            }
        }
    }

    // MARK: - T10, the sentence names what is drawn

    /// Defect 14 as a regression test.
    ///
    /// At a 16pt mark `markAndFigure` is 47pt a segment and 52 of pitch, so
    /// `Int(153 / 52) = 2`: the strip draws two services and the third is dropped.
    /// The status item used to be labelled from the list that went *in*, so it
    /// announced three. There is one fit and one sentence now, and the sentence is
    /// read back off the image the view is drawing.
    @MainActor
    func testTheAnnouncedSentenceNamesOnlyTheServicesTheStripDrew() throws {
        let candidates = [
            MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: 0.92),
            MenuBarEntry(serviceID: "gemini", displayName: "Gemini", percent: 0.64),
            MenuBarEntry(serviceID: "cursor", displayName: "Cursor", percent: 0.12)
        ]
        let fitted = StripFit.fit(candidates, limit: 3, style: box(.markAndFigure), height: 16)
        XCTAssertEqual(fitted.count, 2, "the premise failed: three 16pt segments now fit the cap")

        let spoken = try XCTUnwrap(
            MenuBarStripRenderer.image(
                entries: candidates, height: 16, colour: .perBar, warningThreshold: 0.85,
                style: .markAndFigure, coloursMarks: true
            ).accessibilityDescription
        )
        XCTAssertEqual(spoken, "AI usage: Claude 92%, Gemini 64%")
        XCTAssertFalse(spoken.contains("Cursor"), "\(spoken) announced a service the strip dropped")
    }

    /// And the shape follows the style, which is the other half of the same
    /// promise: `markOnly` draws its reading as a tint, so a sentence that only
    /// read the figures would leave a VoiceOver user with a number and no way to
    /// know the strip had turned amber.
    @MainActor
    func testEachStyleAnnouncesInItsOwnShape() throws {
        let entries = [
            MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: 0.92),
            MenuBarEntry(serviceID: "gemini", displayName: "Gemini", percent: 0.64)
        ]
        func spoken(_ style: AppearanceSettings.MenuBarStyle) throws -> String {
            try XCTUnwrap(
                MenuBarStripRenderer.image(
                    entries: entries, height: 13, colour: .perBar, warningThreshold: 0.85,
                    style: style, coloursMarks: true
                ).accessibilityDescription
            )
        }
        XCTAssertEqual(try spoken(.markAndFigure), "AI usage: Claude 92%, Gemini 64%")
        XCTAssertEqual(
            try spoken(.markOnly), "AI usage: Claude 92%, near limit, Gemini 64%, in use"
        )
        XCTAssertEqual(
            try spoken(.microBars), "AI usage: Claude 92%, near limit, Gemini 64%, in use"
        )
        XCTAssertEqual(
            try spoken(.markAndMeter), "AI usage: Claude 92%, near limit, Gemini 64%, in use"
        )
        // Both ceilings are one, so both name a single service — the figures shape
        // for one bare number, and the worst shape with its clause.
        XCTAssertEqual(try spoken(.figureOnly), "AI usage: Claude 92%")
        XCTAssertEqual(try spoken(.worstOnly), "AI usage: Claude 92%, closest to its cap")
    }

    // MARK: - The registry

    /// The table and the types have to agree, or `box(for:)` is a lookup that can
    /// return the wrong drawing for a stored preference — and the preference is
    /// the one thing in this feature that survives a relaunch.
    func testEveryStyleResolvesToTheTypeThatClaimsIt() {
        for style in styles {
            XCTAssertEqual(box(style).kind, style, "the registry maps \(style.rawValue) elsewhere")
        }
        XCTAssertEqual(StripStyleBox.markAndFigure.kind, .markAndFigure)
    }

    /// Only `microBars` draws behind the run. The other five hand back an
    /// `EmptyView` through the protocol's own default, and asserting that is how a
    /// style that quietly acquires a baseline gets noticed — a rule under
    /// `markAndMeter`'s columns would bind them into one chart and undo the whole
    /// reason that style exists.
    ///
    /// Counted in ink rather than measured as a size: an `EmptyView` handed to
    /// `ImageRenderer` comes back as a 10×10 image with nothing in it, so the size
    /// says only that SwiftUI has a default and not whether anything was drawn.
    @MainActor
    func testOnlyTheMicroBarsDrawBehindTheRun() {
        let ink = StripInk(
            neutral: .black, colour: .perBar, warningThreshold: 0.85,
            isDark: false, coloursMarks: true, carriesColour: true
        )
        let run: CGFloat = 49
        for style in styles {
            let renderer = ImageRenderer(
                content: box(style).underlay(run, 13, ink).frame(width: run, height: 13)
            )
            renderer.scale = 1
            let inked = opaquePixels(of: renderer.nsImage)
            if style == .microBars {
                // A 49pt rule one point tall, so about one pixel row of the 49×13
                // canvas carries ink. Asserted loosely because the rounded ends are
                // antialiased and the exact count is the rasteriser's business.
                XCTAssertGreaterThan(inked, 20, "the micro bars lost the baseline under their run")
                XCTAssertLessThan(inked, 49 * 3, "the baseline is drawing more than a rule")
            } else {
                XCTAssertEqual(inked, 0, "\(style.rawValue) drew something behind the run")
            }
        }
    }

    /// Pixels of `image` carrying any ink at all.
    private func opaquePixels(of image: NSImage?) -> Int {
        guard let tiff = image?.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return 0 }
        var found = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      colour.alphaComponent > 0.05 else { continue }
                found += 1
            }
        }
        return found
    }
}
