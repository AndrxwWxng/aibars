import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// The strip is the one part of the app the user cannot dismiss, so the things
/// that would make it useless are the things worth asserting: a blank image, a
/// blurred one on a retina display, an item that changes width as a reading
/// ticks, a template flag that throws away AppKit's light/dark treatment, and a
/// status item that says nothing out loud.
///
/// `StripFitTests` owns the width arithmetic, which is pure. This file owns the
/// image, because arithmetic that the rasteriser then ignores is worth nothing:
/// the width assertions below are all about what came out of AppKit rather than
/// about what `StripFit` said should.
final class MenuBarStripRendererTests: XCTestCase {
    private let claude = MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: 0.924)
    private let gemini = MenuBarEntry(serviceID: "gemini", displayName: "Gemini", percent: 0.64)
    private let cursor = MenuBarEntry(serviceID: "cursor", displayName: "Cursor", percent: 0.12)
    /// ChatGPT reports a subscription, not a quota. It is the shape that must
    /// never acquire a percentage on its way through the renderer.
    private let statusOnly = MenuBarEntry(serviceID: "chatgpt", displayName: "ChatGPT", percent: nil)

    /// The shipped `menuBarGlyphHeight`: the height the strip is drawn at unless
    /// a test is about a bound, and the height the width assertions ask
    /// `StripFit` about. Named rather than written twice, because those two have
    /// to be the same number and two thirteens would only agree by luck.
    private static let shipped: CGFloat = 13

    // MARK: - It draws something

    @MainActor
    func testStripHasVisiblePixelsForEveryEntryCount() {
        let strips: [[MenuBarEntry]] = [
            [claude],
            [claude, gemini],
            [claude, gemini, cursor],
            [statusOnly],
            [claude, statusOnly]
        ]
        for entries in strips {
            let image = image(entries)
            XCTAssertGreaterThan(image.size.width, 0, "zero-width strip for \(names(entries))")
            XCTAssertGreaterThan(image.size.height, 0, "zero-height strip for \(names(entries))")
            XCTAssertGreaterThan(
                opaquePixels(in: image), 20,
                "the strip for \(names(entries)) is effectively blank"
            )
        }
    }

    /// The status item shares a 22pt bar with everyone else's, so height is a
    /// hard ceiling and width is the thing that must stay proportional to what
    /// is actually being said.
    @MainActor
    func testStripFitsTheMenuBarAndGrowsWithTheEntryCount() {
        let one = image([claude]).size
        let two = image([claude, gemini]).size
        let three = image([claude, gemini, cursor]).size

        for size in [one, two, three] {
            XCTAssertLessThanOrEqual(size.height, 16, "taller than the status bar allows")
        }
        XCTAssertEqual(one.height, 13, accuracy: 0.001, "the requested height is not the drawn height")
        XCTAssertGreaterThan(two.width, one.width, "a second service did not widen the strip")
        XCTAssertGreaterThan(three.width, two.width, "a third service did not widen the strip")
        XCTAssertEqual(one.width, one.width.rounded(.up), "a fractional width gets scaled into a smear")
    }

    // MARK: - The width contract

    /// The bug, on the drawn side.
    ///
    /// The item measured each figure at its natural width, so one service
    /// crossing 99 into 100 widened it by a whole cell and shoved every icon to
    /// its left sideways: the jitter tabular figures were adopted to prevent,
    /// an order of magnitude larger. Nothing asserted the drawn width, which is
    /// how it shipped.
    @MainActor
    func testTheStripKeepsItsWidthWhenAReadingCrossesOneHundred() {
        let services = ["claude", "gemini", "cursor"]
        let ninetyTwo = services.map { MenuBarEntry(serviceID: $0, displayName: $0.capitalized, percent: 0.92) }
        let hundred = services.map { MenuBarEntry(serviceID: $0, displayName: $0.capitalized, percent: 1) }

        // The premise: these are the two readings whose drawn strings really do
        // differ in length, so what follows is about the reserved cell and not
        // about two strings that happen to measure the same.
        XCTAssertEqual(ninetyTwo.map(\.figure), ["92", "92", "92"])
        XCTAssertEqual(hundred.map(\.figure), ["100", "100", "100"])

        XCTAssertEqual(
            image(ninetyTwo).size.width, image(hundred).size.width, accuracy: 0.001,
            "the strip changed width when three services crossed 100"
        )
        // And one crossing on its own, which is how it actually happens: the
        // other two hold their readings while Claude fills up.
        XCTAssertEqual(
            image([ninetyTwo[0], gemini, cursor]).size.width,
            image([hundred[0], gemini, cursor]).size.width,
            accuracy: 0.001,
            "the strip changed width when one service crossed 100"
        )
    }

    /// The general form of it: the drawn width is a function of the segment
    /// count and the mark's height, and of nothing else. A figure measured from
    /// the string in hand is the jitter arriving by another door, so the
    /// reservation is asserted against every reading a segment can carry —
    /// including the em dash, which is a segment with no figure at all.
    @MainActor
    func testWidthIsAFunctionOfTheSegmentCountAndTheHeightAlone() {
        let readings: [Double?] = [nil, 0, 0.07, 0.5, 0.924, 0.996, 1]
        for count in MenuBarStripContent.range {
            let widths = Set(readings.map { image(strip(count: count, reading: $0)).size.width })
            XCTAssertEqual(
                widths.count, 1,
                "\(count) segments measured \(widths.sorted()) across the readings they can carry"
            )
            // Against `StripFit` rather than against itself: the view that draws
            // the strip and the function that measures it have to be adding up
            // the same strip, and a rasteriser that reserved its own cell would
            // put the width contract in two places.
            XCTAssertEqual(
                widths.first, StripFit.width(segments: count, height: Self.shipped).rounded(.up),
                "the drawn strip is not the one StripFit measured"
            )
        }
    }

    /// Past its cap the item stops being an indicator and starts pushing other
    /// people's status items off the right of a notched laptop, which is not
    /// ours to spend.
    @MainActor
    func testTheStripNeverOutgrowsTheWidthItIsAllowed() {
        for height in stride(from: CGFloat(10), through: 16, by: 1) {
            for count in MenuBarStripContent.range {
                let drawn = image(strip(count: count, reading: 1), height: height)
                XCTAssertLessThanOrEqual(
                    drawn.size.width, Tokens.Strip.maxWidth,
                    "\(count) segments at a \(height)pt mark drew \(drawn.size.width)pt"
                )
            }
        }

        // Sixteen points is the widest mark the settings allow and three is the
        // most services they allow, and the two together do not fit. So the cap
        // is not decoration at the ends of the range, and the strip drawn there
        // has to be narrower than three segments measure — whether that is one
        // segment fewer or a strip held to the cap is the renderer's to decide.
        let crowded = image(strip(count: 3, reading: 1), height: 16)
        XCTAssertGreaterThan(crowded.size.width, 0, "the cap left nothing to click")
        XCTAssertLessThan(
            crowded.size.width, StripFit.width(segments: 3, height: 16),
            "three 16pt segments drew at their full width, which overflows the bar's budget"
        )
    }

    /// A service with no quota still takes its cell. Collapsing the dash to its
    /// own width would make the strip breathe every time a status-only service
    /// came and went, and drawing nothing there would read as a service that
    /// failed to report — which is a different statement from one that has no
    /// quota to report.
    @MainActor
    func testAServiceThatReportsNoQuotaStillOccupiesItsFigureCell() {
        XCTAssertEqual(statusOnly.figure, MenuBarEntry.noFigure)

        let dash = image([statusOnly])
        XCTAssertEqual(
            dash.size.width, image([claude]).size.width, accuracy: 0.001,
            "the dash was measured rather than reserved"
        )
        XCTAssertEqual(
            image([statusOnly, claude]).size.width, image([gemini, claude]).size.width, accuracy: 0.001,
            "a status-only service beside a measured one took a narrower cell"
        )
        XCTAssertGreaterThan(
            opaquePixels(in: dash, xRange: figureCell(0)), 3,
            "the reserved cell came out empty, so the dash is not being drawn in it"
        )
    }

    /// Where the reading sits inside the cell it reserved.
    ///
    /// Two token doc comments used to call the cell trailing-aligned "like every
    /// other rail in the app" while the drawing had been leading for as long as
    /// there had been a drawing, and nothing anywhere asserted it — so the prose
    /// was free to be wrong and the alignment was free to be changed back. This is
    /// what makes it a fact.
    ///
    /// The failure it prevents is not clipping. Trailing-aligned, a one-digit
    /// reading sits `markGap` from the NEXT service's logo and two digit-widths
    /// from the logo it belongs to, so the strip reads "0 ChatGPT" instead of
    /// "Claude 0" — a pairing error, which pixels can see and a width assertion
    /// never could.
    @MainActor
    func testAOneDigitReadingIsDrawnAtTheLeadingEdgeOfItsCell() {
        let cell = figureCell(0)
        let middle = cell.lowerBound + (cell.upperBound - cell.lowerBound) / 2

        // "0" measures 7.418pt in SF Mono semibold at 12pt, inside a 23pt cell, so
        // the leading half (11.5pt) holds the whole glyph with 4pt to spare and the
        // trailing half must be empty.
        let zero = MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: 0)
        let one = image([zero, gemini])
        XCTAssertGreaterThan(
            opaquePixels(in: one, xRange: cell.lowerBound..<middle), 3,
            "the reading is not at the leading edge of its cell"
        )
        XCTAssertEqual(
            opaquePixels(in: one, xRange: middle..<cell.upperBound), 0,
            "a one-digit reading reached the trailing half, so the slack is falling in front of it"
        )

        // The premise: the cell really is wider than one digit, and the widest
        // reading really does use the half that just came back empty. Without this
        // the assertion above would also pass on a cell that draws nothing past its
        // midpoint for any reading at all.
        let hundred = MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: 1)
        XCTAssertEqual(hundred.figure, "100")
        XCTAssertGreaterThan(
            opaquePixels(in: image([hundred, gemini]), xRange: middle..<cell.upperBound), 3,
            "the widest reading does not reach the trailing half, so the cell is not the one being tested"
        )
    }

    // MARK: - The retina fix

    /// `ImageRenderer.scale` does not reach `nsImage`, so a strip built that way
    /// is one fixed bitmap and looks soft on a retina display. The fix is a
    /// drawing-handler image, and the only way to know it is still in place is
    /// to look at what kind of representation came back.
    @MainActor
    func testStripIsBackedByADrawingHandlerRepresentation() throws {
        let rep = try XCTUnwrap(image([claude, gemini]).representations.first)
        XCTAssertTrue(
            rep is NSCustomImageRep,
            "the strip is a \(type(of: rep)) — a fixed bitmap cannot redraw at the display's scale"
        )
        let fallbackRep = try XCTUnwrap(MenuBarStripRenderer.fallbackImage(height: 13).representations.first)
        XCTAssertTrue(fallbackRep is NSCustomImageRep, "the fallback is a \(type(of: fallbackRep))")
    }

    /// The point of the custom rep: one image object rasterises to as many
    /// pixels as the destination context asks for.
    @MainActor
    func testOneImageRasterisesAtWhateverScaleItIsDrawnAt() throws {
        let strip = image([claude, gemini])
        let sizes = try [1, 2, 3].map { try XCTUnwrap(pixelSize(of: strip, contextScale: CGFloat($0))) }

        XCTAssertEqual(Set(sizes.map(\.width)).count, 3, "the same bitmap came back at every scale: \(sizes)")
        for (scale, size) in zip([1, 2, 3], sizes) {
            XCTAssertEqual(
                size.height, Int((strip.size.height * CGFloat(scale)).rounded()),
                "at \(scale)x the strip rasterised to \(size.height) pixels tall"
            )
        }
    }

    // MARK: - Template versus colour

    /// A coloured image is not a template, so AppKit stops giving it the menu
    /// bar's own treatment. That trade is only worth making when the colour is
    /// carrying a reading.
    @MainActor
    func testMonochromeIsATemplateAndPerServiceColourIsNot() {
        XCTAssertTrue(image([claude, gemini], colour: .monochrome).isTemplate)
        XCTAssertFalse(image([claude, gemini], colour: .perBar).isTemplate)
    }

    /// A strip of status-only services has no number to colour, so it stays a
    /// template even under `.perBar`. This is the render-side half of "never
    /// invent a percentage": an invented 0 would have coloured it.
    @MainActor
    func testStatusOnlyServicesNeverTurnTheStripIntoAColouredImage() {
        XCTAssertTrue(image([statusOnly], colour: .perBar).isTemplate)
        XCTAssertTrue(image([statusOnly], colour: .alertOnly).isTemplate)
        // One measured service among them is enough to spend the template on.
        XCTAssertFalse(image([statusOnly, cursor], colour: .perBar).isTemplate)
    }

    /// `.alertOnly` means what it says, and the boundary is inclusive on both
    /// sides of the comparison the renderer actually makes.
    @MainActor
    func testAlertOnlyTakesColourOnlyAtOrAboveTheThreshold() {
        let under = MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: 0.8499)
        let at = MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: 0.85)
        let over = MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: 0.8501)

        XCTAssertTrue(image([under], colour: .alertOnly).isTemplate, "coloured below the warning")
        XCTAssertFalse(image([at], colour: .alertOnly).isTemplate, "not coloured at the warning")
        XCTAssertFalse(image([over], colour: .alertOnly).isTemplate, "not coloured above the warning")
    }

    /// The template flag says colour was not spent; this says none arrived. A
    /// monochrome strip carries no hue at any level, which is what the setting
    /// is for: someone who asked for a menu bar that matches every other item in
    /// it does not get a red figure when a quota fills.
    @MainActor
    func testMonochromeCarriesNoColourAtAnyLevel() {
        let levels: [Double?] = [nil, 0, 0.4, 0.8499, 0.85, 0.924, 1]
        for level in levels {
            let drawn = image(strip(count: 3, reading: level), colour: .monochrome)
            XCTAssertEqual(
                colouredPixels(in: drawn), 0,
                "a reading of \(String(describing: level)) coloured a monochrome strip"
            )
            XCTAssertGreaterThan(opaquePixels(in: drawn), 20, "the monochrome strip drew nothing at all")
        }
    }

    /// Under `.alertOnly` the colour is the news, so it goes on the one figure
    /// that crossed the warning and nowhere else. The marks in particular stay
    /// neutral: a brand colour in the strip would make every service look like it
    /// was saying something.
    ///
    /// Positional, and the positions come from `StripFit` rather than from
    /// measured ink, because "the mark stayed neutral" is a claim about which
    /// column the colour landed in.
    @MainActor
    func testAlertOnlyColoursTheFigureThatCrossedAndNothingElse() {
        XCTAssertEqual(
            colouredPixels(in: image([cursor, gemini], colour: .alertOnly)), 0,
            "nothing had crossed the warning and the strip took colour anyway"
        )

        let drawn = image([cursor, claude], colour: .alertOnly)
        XCTAssertGreaterThan(
            colouredPixels(in: drawn, xRange: figureCell(1)), 0,
            "the figure that crossed the warning was left neutral"
        )
        XCTAssertEqual(
            colouredPixels(in: drawn, xRange: figureCell(0)), 0,
            "a figure below the warning took the ramp"
        )
        for index in 0...1 {
            XCTAssertEqual(
                colouredPixels(in: drawn, xRange: markBox(index)), 0,
                "the brand mark at position \(index) took a colour under .alertOnly"
            )
        }
    }

    // MARK: - The memo

    /// AppKit compares the status item's image by identity and skips the update
    /// when it is unchanged, which is most refreshes. An equal-but-new image
    /// would repaint the menu bar every few seconds.
    @MainActor
    func testIdenticalInputsReturnTheIdenticalInstance() {
        XCTAssertIdentical(image([claude, gemini]), image([claude, gemini]), "the same strip was rasterised twice")
    }

    /// The memo compares its segments by value, and the reserved cell is the
    /// newest thing standing between the entries and the image — so this is
    /// where a fit computed after the memo was consulted, or an array rebuilt on
    /// every call, would show up as a menu bar that repaints on every refresh.
    @MainActor
    func testEqualContentReturnsTheIdenticalImageIncludingWhenTheCapHasBitten() {
        // Built twice rather than reused: equal segments, and no shared object
        // for an identity comparison to pass on by accident.
        func entries() -> [MenuBarEntry] {
            [
                MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: 0.924),
                MenuBarEntry(serviceID: "chatgpt", displayName: "ChatGPT", percent: nil)
            ]
        }
        let first = image(entries())
        XCTAssertIdentical(image(entries()), first, "two equal strips rasterised to two images")
        // Across a refresh cadence rather than once, because a memo that held
        // for one call and not the next would still pass a single comparison.
        for _ in 0..<20 {
            XCTAssertIdentical(image(entries()), first, "the strip was re-rasterised on an unchanged refresh")
        }

        // Three 16pt segments is the configuration the width cap cuts down, so
        // it is the one where fitting happens on the way to the image.
        XCTAssertIdentical(
            image(strip(count: 3, reading: 0.5), height: 16),
            image(strip(count: 3, reading: 0.5), height: 16),
            "a strip the cap had cut down was rasterised twice"
        )
    }

    /// Everything the drawing depends on has to be in the key, or a change goes
    /// unnoticed and the menu bar shows the previous reading.
    @MainActor
    func testEveryInputThatChangesTheDrawingInvalidatesTheMemo() {
        XCTAssertNotIdentical(image([claude, gemini]), image([claude], colour: .perBar), "the entry list is not in the key")
        XCTAssertNotIdentical(image([claude, gemini]), image([claude, gemini], height: 14), "height is not in the key")
        XCTAssertNotIdentical(
            image([claude, gemini]), image([claude, gemini], colour: .monochrome),
            "the colour mode is not in the key"
        )
        XCTAssertNotIdentical(
            image([claude, gemini]), image([claude, gemini], warningThreshold: 0.5),
            "the warning threshold is not in the key"
        )

        // The figure is what the strip prints, so two readings that round to the
        // same whole number are genuinely the same drawing — but the ones that
        // do not must not share an image.
        let ticked = MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: 0.95)
        XCTAssertNotIdentical(image([claude, gemini]), image([ticked, gemini]), "the figure is not in the key")

        // And the name only reaches the image through VoiceOver, which is
        // exactly why it is easy to leave out of the key.
        let renamed = MenuBarEntry(serviceID: "claude", displayName: "Claude Max", percent: 0.924)
        XCTAssertNotIdentical(image([claude]), image([renamed]), "the display name is not in the key")
    }

    /// The worst shape this bug can take, and the reason it gets its own test.
    ///
    /// If `style` reaches the signature but not `Memo.matches`, the user picks a
    /// style, the Appearance pane's preview updates — it builds the view directly
    /// and never consults the memo — and the menu bar keeps the previous bitmap,
    /// because AppKit compares the status item's image by identity and this hands
    /// back the same instance. The setting appears broken while the preview says
    /// it worked.
    ///
    /// Identity, not equality: two styles can draw the same pixels at one segment
    /// (`markOnly` and `microBars` measure identically by construction) and an
    /// equality assertion would pass on the stale image.
    @MainActor
    func testTheMemoMissesWhenTheStyleChanges() {
        let entries = [claude, gemini]
        let reference = image(entries, style: .markAndFigure)
        for style in AppearanceSettings.MenuBarStyle.allCases where style != .markAndFigure {
            XCTAssertNotIdentical(
                reference, image(entries, style: style),
                "\(style.rawValue) returned the mark-and-figure bitmap — the style is not in the key"
            )
        }
    }

    /// The brand-mark switch, same failure. It is not a colour mode and not a
    /// reading: `.perBar` still colours every figure with it off, so nothing else
    /// in the key moves and the memo is the only thing between the switch and a
    /// menu bar that ignores it.
    @MainActor
    func testTheMemoMissesWhenBrandMarkColourFlips() {
        XCTAssertNotIdentical(
            image([claude, gemini], coloursMarks: true),
            image([claude, gemini], coloursMarks: false),
            "turning brand hue off returned the coloured bitmap"
        )
        // And the flip really does change the drawing, or the assertion above is
        // about a key rather than about a picture. Under `.perBar` the mark is the
        // only brand-coloured thing in the strip, so switching it off must take
        // colour out of the mark box while leaving the figure's alone.
        let on = image([claude], colour: .perBar, coloursMarks: true)
        let off = image([claude], colour: .perBar, coloursMarks: false)
        XCTAssertGreaterThan(
            colouredPixels(in: on, xRange: markBox(0)), 0,
            "the mark carried no brand hue with the switch on"
        )
        XCTAssertEqual(
            colouredPixels(in: off, xRange: markBox(0)), 0,
            "the mark kept its brand hue with the switch off"
        )
        XCTAssertGreaterThan(
            colouredPixels(in: off, xRange: figureCell(0)), 0,
            "the switch took the reading's colour with it"
        )
    }

    /// Nothing reporting is a state the app spends its first seconds in, and the
    /// fallback is keyed on the mark's own box because a template has no colour to
    /// go stale — the box is the whole key.
    @MainActor
    func testAnEmptyStripIsTheFallbackImage() {
        let empty = image([])
        XCTAssertIdentical(empty, MenuBarStripRenderer.fallbackImage(height: 13), "the empty strip is not the fallback")
        XCTAssertTrue(empty.isTemplate, "the fallback must inherit the menu bar's treatment")
        XCTAssertGreaterThan(opaquePixels(in: empty), 20, "the fallback is an unclickable blank slot")
        XCTAssertLessThanOrEqual(empty.size.height, 16)
        XCTAssertNotIdentical(
            MenuBarStripRenderer.fallbackImage(height: 13), MenuBarStripRenderer.fallbackImage(height: 15),
            "two heights shared one fallback"
        )
    }

    /// The canvas is the mark's box and not the height that was asked for.
    ///
    /// `AppMark` draws in the largest even whole point that fits, so the shipped 13
    /// is a 12pt mark 15pt wide. A 13pt canvas would hold 12pt of ink and then
    /// hang on a half point: (22 − 13) / 2 = 4.5, which at 1× splits the baseline
    /// and all four bar tops across two device rows each. Written as the size the
    /// image actually carries rather than as an inequality, because the pair of
    /// numbers *is* the fix.
    @MainActor
    func testTheFallbackIsSizedToTheMarksOwnBox() {
        XCTAssertEqual(MenuBarStripRenderer.fallbackImage(height: 13).size, CGSize(width: 15, height: 12))
        XCTAssertEqual(
            MenuBarStripRenderer.fallbackImage(height: 13).size,
            AppMarkGeometry(size: 13).drawn,
            "the canvas and the mark disagree about how big the mark is"
        )
        let origin = (MenuBarIcon.barHeight - MenuBarStripRenderer.fallbackImage(height: 13).size.height) / 2
        XCTAssertEqual(origin, origin.rounded(), "the fallback hangs at y = \(origin) in the bar")
    }

    /// And the memo keys on that box, not on the request: 13 and 12 are one mark,
    /// so they are one bitmap rather than two identical ones. The half point is
    /// there because the height tuner shipped with `step: 0.5` and a defaults
    /// domain can still hold what it wrote.
    @MainActor
    func testHeightsThatDrawTheSameMarkShareOneFallback() {
        XCTAssertIdentical(
            MenuBarStripRenderer.fallbackImage(height: 13), MenuBarStripRenderer.fallbackImage(height: 12),
            "one mark was rasterised twice"
        )
        XCTAssertIdentical(
            MenuBarStripRenderer.fallbackImage(height: 13), MenuBarStripRenderer.fallbackImage(height: 13.5),
            "a half point minted a second bitmap of the same mark"
        )
        // The other half of the claim, or "one bitmap" would be satisfied by never
        // redrawing at all: two boxes are still two images.
        XCTAssertNotIdentical(
            MenuBarStripRenderer.fallbackImage(height: 13), MenuBarStripRenderer.fallbackImage(height: 14),
            "12 and 14 are different marks and must be different images"
        )
    }

    // MARK: - What it says out loud

    @MainActor
    func testAccessibilityDescriptionNamesTheServicesItDrew() throws {
        let spoken = try XCTUnwrap(image([claude, statusOnly]).accessibilityDescription)
        XCTAssertTrue(spoken.contains("Claude"), "\(spoken) does not name Claude")
        XCTAssertTrue(spoken.contains("92%"), "\(spoken) does not read Claude's figure")
        XCTAssertTrue(spoken.contains("ChatGPT"), "\(spoken) does not name ChatGPT")
        // Never "ChatGPT 0%": a dash read aloud as a number is a claim the
        // provider did not make.
        XCTAssertFalse(spoken.contains("ChatGPT 0"), "a status-only service was given a figure: \(spoken)")
        XCTAssertFalse(spoken.contains(MenuBarEntry.noFigure), "the em dash reached VoiceOver: \(spoken)")

        let empty = try XCTUnwrap(image([]).accessibilityDescription)
        XCTAssertFalse(empty.isEmpty, "an unlabelled status item is unreachable")
    }

    // MARK: - Legibility on both menu bars

    /// A coloured strip is not a template, so nothing recolours it after the
    /// fact and both the ramp and the neutral have to resolve against the menu
    /// bar's own appearance while it is being drawn. If they did not, one of the
    /// two menu bars would get near-black figures on near-black.
    @MainActor
    func testThirteenPointStripInksDifferentlyOnEachAppearance() throws {
        let light = try XCTUnwrap(meanInk(dark: false))
        let dark = try XCTUnwrap(meanInk(dark: true))
        XCTAssertGreaterThan(
            max(abs(light.red - dark.red), abs(light.green - dark.green), abs(light.blue - dark.blue)),
            0.05,
            "the strip inked identically on both appearances: \(light) and \(dark)"
        )
    }

    /// The neutral is a parameter precisely so the caller can resolve it, and
    /// the failure it exists to prevent is black figures on a dark menu bar.
    @MainActor
    func testTheNeutralIsWhatKeepsAnUnmeasuredFigureVisible() throws {
        let onDark = try XCTUnwrap(meanInk(dark: true, entries: [statusOnly], neutral: .white))
        let onLight = try XCTUnwrap(meanInk(dark: false, entries: [statusOnly], neutral: .black))
        XCTAssertGreaterThan(onDark.red, 0.6, "the dark menu bar's strip inked at \(onDark) — too dark to see")
        XCTAssertLessThan(onLight.red, 0.4, "the light menu bar's strip inked at \(onLight) — too light to see")
    }

    /// The same failure, asserted of the renderer rather than of the view.
    ///
    /// The test above hands the view the neutral it wants, so it proves the view
    /// spends one and not that the rasteriser picks the right one — a renderer
    /// that baked black on a dark bar passes it. This drives
    /// `MenuBarIcon.isDarkMenuBar`, which is what the renderer actually reads,
    /// and then looks at what came out.
    ///
    /// With no status item in a test bundle that reading falls back to the
    /// application's own appearance, which is the one seam it has here. The rest
    /// of the suite resolves colours inside
    /// `performAsCurrentDrawingAppearance` and never reads the ambient one, so
    /// what this borrows is nothing anything else looks at — and it is put back
    /// exactly as it was found.
    @MainActor
    func testTheRendererBakesTheNeutralADarkMenuBarNeedsRatherThanBlack() throws {
        let app = NSApplication.shared
        let original = app.appearance
        defer { app.appearance = original }

        // `.alertOnly` with one service over the line is the mixed case: the
        // figure that crossed takes the ramp and everything else — both marks
        // and the calm figure — is drawn in the neutral. So the neutral is most
        // of the ink, and the mean says which one was baked in.
        let entries = [claude, cursor]

        app.appearance = NSAppearance(named: .darkAqua)
        try XCTSkipUnless(
            MenuBarIcon.isDarkMenuBar,
            "the menu bar's appearance no longer comes from the application, so this cannot reach it"
        )
        let onDark = try XCTUnwrap(meanInk(of: image(entries, colour: .alertOnly)))

        app.appearance = NSAppearance(named: .aqua)
        XCTAssertFalse(MenuBarIcon.isDarkMenuBar, "the light appearance read as a dark menu bar")
        let onLight = try XCTUnwrap(meanInk(of: image(entries, colour: .alertOnly)))

        XCTAssertGreaterThan(
            lightness(onDark), 0.6,
            "the strip for a dark menu bar inked at \(onDark) — near-black on near-black"
        )
        XCTAssertLessThan(
            lightness(onLight), 0.4,
            "the strip for a light menu bar inked at \(onLight) — near-white on near-white"
        )
    }

    // MARK: - Input the renderer does not get to trust

    /// Percentages arrive from parsed provider JSON and thresholds from
    /// `UserDefaults`; neither is validated at the point it is stored. None of
    /// these may crash, and none may silently become a different reading.
    @MainActor
    func testDegenerateReadingsRenderWithoutInventingANumber() throws {
        let cases: [(Double, String)] = [
            (0, "0%"),
            (-0.5, "0%"),          // clamped up, not read as a negative
            (1, "100%"),
            (2, "100%"),           // clamped down, not read as 200%
            (0.996, "99%"),        // never rounded up into the cap
            (0.999999, "99%")
        ]
        for (percent, expected) in cases {
            let entry = MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: percent)
            let spoken = try XCTUnwrap(image([entry]).accessibilityDescription)
            XCTAssertTrue(spoken.contains(expected), "\(percent) was announced as \(spoken)")
            XCTAssertGreaterThan(opaquePixels(in: image([entry])), 20, "blank strip for \(percent)")
        }

        // Non-finite is not a reading of anything, so it has to come out as the
        // same "no quota" the status-only services get.
        for percent in [Double.nan, .infinity, -.infinity, .signalingNaN] {
            let entry = MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: percent)
            let spoken = try XCTUnwrap(image([entry]).accessibilityDescription)
            XCTAssertTrue(spoken.contains("reports no quota"), "\(percent) was announced as \(spoken)")
            XCTAssertTrue(image([entry], colour: .perBar).isTemplate, "\(percent) was coloured as a reading")
        }
    }

    @MainActor
    func testMalformedThresholdsDoNotColourOrCrash() {
        let entries = [claude, gemini]
        // A NaN threshold fails every comparison, so nothing is near its cap.
        XCTAssertTrue(image(entries, colour: .alertOnly, warningThreshold: .nan).isTemplate)
        // A negative one is crossed by everything, including a service at 0.
        XCTAssertFalse(image(entries, colour: .alertOnly, warningThreshold: -1).isTemplate)
        // And one past the cap is crossed by nothing.
        XCTAssertTrue(image(entries, colour: .alertOnly, warningThreshold: 2).isTemplate)
        for threshold in [Double.nan, -1, 2, .infinity] {
            XCTAssertGreaterThan(
                opaquePixels(in: image(entries, colour: .perBar, warningThreshold: threshold)), 20,
                "a threshold of \(threshold) blanked the strip"
            )
        }
    }

    /// Service ids and display names come from provider adapters and from
    /// persisted account records, so the renderer has to survive ones it has no
    /// mark for, no letter for, and far too much of.
    @MainActor
    func testUnknownAndMalformedServicesStillDraw() {
        let unknown = MenuBarEntry(serviceID: "not-a-service", displayName: "Zed", percent: 0.4)
        let nameless = MenuBarEntry(serviceID: "", displayName: "", percent: 0.4)
        let shouty = MenuBarEntry(serviceID: "claude", displayName: String(repeating: "Claude ", count: 60), percent: 0.4)
        let emoji = MenuBarEntry(serviceID: "\u{1F600}", displayName: "\u{1F600} Grinning", percent: 0.4)

        for entry in [unknown, nameless, shouty, emoji] {
            let drawn = image([entry])
            XCTAssertGreaterThan(opaquePixels(in: drawn), 5, "blank strip for \(entry.serviceID)")
            XCTAssertLessThanOrEqual(drawn.size.height, 16, "\(entry.serviceID) grew the strip vertically")
            XCTAssertNotNil(drawn.accessibilityDescription)
            // The name is not drawn, so 420 characters of it may not widen the
            // item either: the cell is reserved from the figure and the mark
            // stands in its own square whatever it is a mark of.
            XCTAssertEqual(
                drawn.size.width, image([claude]).size.width, accuracy: 0.001,
                "\(entry.serviceID) drew at a width of its own"
            )
        }

        // Two accounts of one service reach the renderer as two segments; it
        // draws both rather than deduplicating, because which entries survive is
        // the strip model's decision and not this one's.
        let twice = image([claude, MenuBarEntry(serviceID: "claude", displayName: "Claude work", percent: 0.3)])
        XCTAssertGreaterThan(twice.size.width, image([claude]).size.width)
    }

    /// The height is a stored setting. It is clamped where it is stored, but a
    /// renderer that traps on the value it is handed is a renderer that trusts
    /// the store.
    @MainActor
    func testDegenerateHeightsProduceAnImageRatherThanATrap() {
        for height in [0.5, 1, 100] as [CGFloat] {
            let drawn = image([claude], height: height)
            XCTAssertEqual(drawn.size.height, height, accuracy: 0.001, "height \(height) was not honoured")
            XCTAssertGreaterThan(drawn.size.width, 0, "height \(height) produced a zero-width strip")
        }
        // AppKit will not carry a size with a zero or negative dimension, so
        // these come back empty rather than drawn. That is the right end state:
        // what this asserts is that the renderer hands the stored value to
        // AppKit rather than trapping on it on the way, since the clamp that
        // keeps it in 10...16 lives in the settings store and not here.
        for height in [0, -5] as [CGFloat] {
            XCTAssertGreaterThanOrEqual(image([claude], height: height).size.width, 0)
        }
    }

    // MARK: - The view builds

    @MainActor
    func testTheStripViewRendersOnItsOwn() {
        // The Appearance pane draws this view directly rather than through the
        // renderer, so it has to stand up outside the rasteriser too — in every
        // style, because the pane's chooser draws a sample of each one beside its
        // own name.
        for style in AppearanceSettings.MenuBarStyle.allCases {
            let renderer = ImageRenderer(
                content: MenuBarStripView(
                    entries: [claude, statusOnly],
                    style: StripStyleBox.box(for: style),
                    height: 13,
                    colour: .perBar,
                    warningThreshold: 0.85
                )
            )
            let drawn = renderer.nsImage
            XCTAssertNotNil(drawn, "\(style.rawValue) rendered nothing outside the rasteriser")
            // And it measures what the status item reserves for it, or the pane's
            // preview and the bar disagree about the thing the preview is for.
            let box = StripStyleBox.box(for: style)
            let fitted = StripFit.fit([claude, statusOnly], limit: 2, style: box, height: 13).count
            XCTAssertEqual(
                drawn?.size.width, StripFit.width(segments: fitted, style: box, height: 13),
                "\(style.rawValue)'s preview is not the width the bar reserves"
            )
        }
    }

    // MARK: - Helpers

    /// `.markAndFigure` and coloured marks are the shipped configuration, so
    /// every test that is not about the style itself measures the strip the app
    /// actually draws. The two are parameters rather than fixed because both are
    /// in the memo key, and the memo tests are the ones that have to vary them.
    @MainActor
    private func image(
        _ entries: [MenuBarEntry],
        height: CGFloat = shipped,
        colour: AppearanceSettings.MenuBarColour = .perBar,
        warningThreshold: Double = 0.85,
        style: AppearanceSettings.MenuBarStyle = .markAndFigure,
        coloursMarks: Bool = true
    ) -> NSImage {
        MenuBarStripRenderer.image(
            entries: entries, height: height, colour: colour,
            warningThreshold: warningThreshold, style: style, coloursMarks: coloursMarks
        )
    }

    /// `count` distinct services, all reading the same thing. Distinct because
    /// the renderer draws what it is given and two marks the same would make a
    /// positional assertion ambiguous to read back.
    private func strip(count: Int, reading: Double?) -> [MenuBarEntry] {
        ["claude", "gemini", "cursor"]
            .prefix(count)
            .map { MenuBarEntry(serviceID: $0, displayName: $0.capitalized, percent: reading) }
    }

    private func names(_ entries: [MenuBarEntry]) -> String {
        entries.isEmpty ? "an empty strip" : entries.map(\.displayName).joined(separator: " + ")
    }

    // MARK: - Where the ink is allowed to be

    /// One segment's mark box, in points from the strip's leading edge.
    ///
    /// Reconstructed from the style's own arithmetic rather than from measured
    /// ink: the claim being tested is which column a colour landed in, so the
    /// columns have to come from the type that decides them. The mark is drawn in
    /// a box as wide as it is tall, which is what keeps a wide logo and a narrow
    /// one in the same column.
    private func markBox(_ index: Int, height: CGFloat = shipped) -> Range<CGFloat> {
        let start = CGFloat(index) * pitch(height)
        return start..<(start + Tokens.Strip.markBox(height: height))
    }

    /// The reserved figure cell of the segment at `index`.
    private func figureCell(_ index: Int, height: CGFloat = shipped) -> Range<CGFloat> {
        let start = CGFloat(index) * pitch(height)
            + Tokens.Strip.markBox(height: height) + StripFit.markGap
        return start..<(start + StripFit.figureCell(height: height))
    }

    /// One segment's leading edge to the next one's. Off `MarkAndFigureStyle`
    /// rather than added up here, so the columns this file reads pixels out of are
    /// the ones the drawing actually laid down.
    private func pitch(_ height: CGFloat) -> CGFloat {
        MarkAndFigureStyle.cellWidth(height: height) + StripFit.segmentGap
    }

    // MARK: - Reading the pixels

    private func opaquePixels(in image: NSImage, xRange: Range<CGFloat>? = nil) -> Int {
        inkedColours(in: image, xRange: xRange, minimumAlpha: 0.05).count
    }

    /// Pixels carrying a hue rather than a shade of the neutral.
    ///
    /// Fully-inked pixels only, and a generous spread. Grayscale antialiasing
    /// blends a neutral glyph towards transparency and cannot separate the
    /// channels at all, and the narrowest gap the ramp produces is the resting
    /// teal's fifth — so 0.15 answers "did a colour arrive here" with nothing an
    /// edge can do about it.
    private func colouredPixels(in image: NSImage, xRange: Range<CGFloat>? = nil) -> Int {
        inkedColours(in: image, xRange: xRange, minimumAlpha: 0.9).filter { colour in
            let channels = [colour.redComponent, colour.greenComponent, colour.blueComponent]
            guard let low = channels.min(), let high = channels.max() else { return false }
            return high - low > 0.15
        }.count
    }

    /// Mean colour of the ink in a strip drawn under one appearance. Rendered
    /// through the view rather than the renderer because this is asserting what
    /// the view does with the neutral it is handed;
    /// `testTheRendererBakesTheNeutralADarkMenuBarNeedsRatherThanBlack` is the
    /// one that goes through the renderer and its own choice of neutral.
    @MainActor
    private func meanInk(
        dark: Bool,
        entries: [MenuBarEntry]? = nil,
        neutral: Color? = nil
    ) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        let strip = MenuBarStripView(
            entries: entries ?? [claude],
            height: 13,
            colour: .perBar,
            warningThreshold: 0.85,
            neutral: neutral ?? (dark ? .white : .black)
        )
        .environment(\.colorScheme, dark ? .dark : .light)

        let renderer = ImageRenderer(content: strip)
        renderer.scale = 2
        guard let image = renderer.nsImage else { return nil }
        return meanInk(of: image)
    }

    /// Mean colour of the fully-inked pixels of a finished image. The
    /// antialiased edges are left out because they are a blend with whatever is
    /// behind them, which would pull two means towards each other.
    private func meanInk(of image: NSImage) -> (red: CGFloat, green: CGFloat, blue: CGFloat)? {
        let inked = inkedColours(in: image, minimumAlpha: 0.9)
        guard !inked.isEmpty else { return nil }

        var total = (red: CGFloat(0), green: CGFloat(0), blue: CGFloat(0))
        for colour in inked {
            total.red += colour.redComponent
            total.green += colour.greenComponent
            total.blue += colour.blueComponent
        }
        let divisor = CGFloat(inked.count)
        return (total.red / divisor, total.green / divisor, total.blue / divisor)
    }

    /// How light a mean reads, which is the whole question when the failure is
    /// near-black ink on a near-black bar.
    private func lightness(_ ink: (red: CGFloat, green: CGFloat, blue: CGFloat)) -> CGFloat {
        (ink.red + ink.green + ink.blue) / 3
    }

    /// Every pixel of `image` inside `xRange`, in sRGB.
    ///
    /// The range is in points because that is what `StripFit` measures in, while
    /// the bitmap comes back at whatever scale AppKit cached it at — so the two
    /// are related by the width rather than assumed to be the same.
    private func inkedColours(
        in image: NSImage,
        xRange: Range<CGFloat>? = nil,
        minimumAlpha: CGFloat
    ) -> [NSColor] {
        guard image.size.width > 0, let bitmap = bitmap(of: image) else { return [] }
        let scale = CGFloat(bitmap.pixelsWide) / image.size.width

        var found: [NSColor] = []
        for x in 0..<bitmap.pixelsWide {
            if let xRange {
                // The pixel's own centre, so a cell boundary falling inside a
                // pixel does not count it on both sides.
                guard xRange.contains((CGFloat(x) + 0.5) / scale) else { continue }
            }
            for y in 0..<bitmap.pixelsHigh {
                guard let colour = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                      colour.alphaComponent > minimumAlpha else { continue }
                found.append(colour)
            }
        }
        return found
    }

    /// Pixel dimensions the image rasterises to when it is asked for a bitmap by
    /// a context at `contextScale`.
    private func pixelSize(of image: NSImage, contextScale: CGFloat) -> (width: Int, height: Int)? {
        let wide = Int((image.size.width * contextScale).rounded(.up))
        let high = Int((image.size.height * contextScale).rounded(.up))
        guard wide > 0, high > 0,
              let target = NSBitmapImageRep(
                bitmapDataPlanes: nil,
                pixelsWide: wide, pixelsHigh: high,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
              ),
              let context = NSGraphicsContext(bitmapImageRep: target) else { return nil }
        context.cgContext.scaleBy(x: contextScale, y: contextScale)

        var rect = NSRect(origin: .zero, size: image.size)
        guard let drawn = image.cgImage(forProposedRect: &rect, context: context, hints: nil) else { return nil }
        return (drawn.width, drawn.height)
    }

    private func bitmap(of image: NSImage) -> NSBitmapImageRep? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }
}
