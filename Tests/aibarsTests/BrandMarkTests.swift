import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

final class SVGPathTests: XCTestCase {
    func testParsesAbsoluteAndRelativeCommands() {
        // A 10x10 square drawn with a relative line-to and an implicit repeat.
        let path = SVGPath.cgPath(from: "M0 0 h10 v10 H0 Z")
        XCTAssertEqual(path.boundingBox.width, 10, accuracy: 0.001)
        XCTAssertEqual(path.boundingBox.height, 10, accuracy: 0.001)
    }

    func testImplicitLineToAfterMoveTo() {
        // Extra coordinate pairs after an `M` are line-tos, not more move-tos.
        let path = SVGPath.cgPath(from: "M0 0 5 0 5 5")
        XCTAssertFalse(path.isEmpty)
        XCTAssertEqual(path.boundingBox.maxX, 5, accuracy: 0.001)
    }

    func testOmittedSeparatorsBeforeMinusAndDecimal() {
        let path = SVGPath.cgPath(from: "M0 0l2.5.5-1.5 1")
        XCTAssertEqual(path.boundingBox.maxX, 2.5, accuracy: 0.001)
        XCTAssertEqual(path.boundingBox.maxY, 1.5, accuracy: 0.001)
    }

    func testArcProducesRoundedGeometry() {
        // Half-circle of radius 5 from (0,0) to (10,0): the sweep should bulge
        // 5 units away from the chord.
        let path = SVGPath.cgPath(from: "M0 0 A5 5 0 0 1 10 0")
        XCTAssertEqual(path.boundingBox.width, 10, accuracy: 0.01)
        XCTAssertEqual(path.boundingBox.height, 5, accuracy: 0.01)
    }

    func testPackedArcFlags() {
        // Optimisers emit flags jammed against the following number.
        let packed = SVGPath.cgPath(from: "M0 0a5 5 0 015 5")
        let spaced = SVGPath.cgPath(from: "M0 0a5 5 0 0 1 5 5")
        XCTAssertEqual(packed.boundingBox.width, spaced.boundingBox.width, accuracy: 0.001)
        XCTAssertEqual(packed.boundingBox.height, spaced.boundingBox.height, accuracy: 0.001)
    }
}

final class BrandMarkTests: XCTestCase {
    /// Services with no published logo we can render. These fall back to a
    /// lettermark, which is deliberate — better an honest initial than a
    /// hand-drawn approximation of someone's trademark.
    private static let withoutMarks: Set<String> = []

    /// The status item draws marks now, not four abstract bars, so a service
    /// registered without a glyph is no longer a cosmetic gap: it is a segment
    /// the user cannot identify. Walks `AppState.services` rather than a built
    /// `AppState` because the service list is the register — accounts are keyed
    /// "claude#2" and resolve to the family's one mark.
    @MainActor
    func testEveryRegisteredServiceHasAMarkOrIsExempt() {
        for service in AppState.services {
            if Self.withoutMarks.contains(service.id) {
                XCTAssertNil(
                    BrandMark.mark(for: service.id),
                    "\(service.id) now has a mark — drop it from the exempt list"
                )
            } else {
                XCTAssertNotNil(BrandMark.mark(for: service.id), "missing brand mark for \(service.id)")
            }
        }
    }

    /// And by the id the *provider* declares, which is a second string in a
    /// second file. `AppState.services` keys the register, every provider states
    /// its own `serviceID` literal, and the strip resolves its glyph from the
    /// literal (`MenuBarStripRenderer.brand`, via `AppState.serviceReadings`) —
    /// so a provider whose literal drifted from its registration satisfies the
    /// test above and still draws a lettermark at 13pt.
    ///
    /// Built for a second account as well. That is the branch a future
    /// `serviceID { id }` would break rather than the plain one, because the
    /// account suffix is in `id` and must not reach the mark: "claude#2" is a
    /// distinct provider and the family has one glyph.
    @MainActor
    func testEveryProviderResolvesAMarkByTheIDItDeclares() {
        for service in AppState.services {
            for accountID in [nil, "2"] as [String?] {
                let provider = service.make(accountID)
                XCTAssertEqual(
                    provider.serviceID, service.id,
                    "\(provider.id) is registered under one id and declares another"
                )
                guard !Self.withoutMarks.contains(service.id) else { continue }
                XCTAssertNotNil(
                    BrandMark.mark(for: provider.serviceID),
                    "missing brand mark for \(provider.id)"
                )
            }
        }
    }

    /// Guards against a path that silently fails to parse (empty), or one that
    /// parses into nonsense far outside its declared view box.
    func testMarksFillTheirViewBox() throws {
        for mark in BrandMark.all {
            let path = SVGPath.cgPath(from: mark.pathData)
            XCTAssertFalse(path.isEmpty, "\(mark.providerID) produced an empty path")

            let box = path.boundingBox
            XCTAssertGreaterThan(box.width, mark.viewBox.width * 0.5, "\(mark.providerID) is too narrow")
            XCTAssertGreaterThan(box.height, mark.viewBox.height * 0.5, "\(mark.providerID) is too short")
            XCTAssertGreaterThanOrEqual(box.minX, -0.5, "\(mark.providerID) overflows left")
            XCTAssertGreaterThanOrEqual(box.minY, -0.5, "\(mark.providerID) overflows top")
            XCTAssertLessThanOrEqual(box.maxX, mark.viewBox.width + 0.5, "\(mark.providerID) overflows right")
            XCTAssertLessThanOrEqual(box.maxY, mark.viewBox.height + 0.5, "\(mark.providerID) overflows bottom")
        }
    }

    /// Two services, one company, one published glyph. The pair is a shared
    /// constant precisely so this stays true, and they are two entries so the
    /// strip resolves each by its own id: `chatgpt` reports subscription status
    /// and `codex` reports usage windows, and both can be on the strip at once.
    func testTheTwoOpenAIServicesCarryTheSameGlyph() throws {
        let chatGPT = try XCTUnwrap(BrandMark.mark(for: "chatgpt"))
        let codex = try XCTUnwrap(BrandMark.mark(for: "codex"))
        XCTAssertEqual(chatGPT.pathData, codex.pathData)
        XCTAssertEqual(chatGPT.viewBox, codex.viewBox)
        XCTAssertNotEqual(chatGPT.title, codex.title)
    }

    /// Claude and Claude Code are two rows measuring different things, and in a
    /// 13pt strip the glyph is the only thing telling them apart — so unlike the
    /// OpenAI pair they must not share artwork. One brand colour, two shapes.
    func testClaudeCodeIsDrawnApartFromClaude() throws {
        let claude = try XCTUnwrap(BrandMark.mark(for: "claude"))
        let claudeCode = try XCTUnwrap(BrandMark.mark(for: "claudecode"))
        XCTAssertNotEqual(claude.pathData, claudeCode.pathData)
        XCTAssertEqual(claude.hex, claudeCode.hex)
    }

    // MARK: - Ink

    /// The strip's own height, and the panel logo's. 13pt is far smaller than
    /// anything that drew a mark before the strip existed, and it is where a
    /// glyph with hairline features empties out.
    private static let sizes: [CGFloat] = [13, 30]

    /// Every mark, filled, at both sizes — measured as a share of its box rather
    /// than as "more than zero pixels", because a mark that survives as three
    /// specks has failed at the thing the strip needs it for. The floor is well
    /// under the thinnest shipping mark (Gemini's star, ~0.24) and well over
    /// nothing at all.
    @MainActor
    func testEveryMarkInksAtBothDrawnSizes() throws {
        for mark in BrandMark.all {
            for size in Self.sizes {
                let inked = try XCTUnwrap(
                    coverage(of: mark, at: size),
                    "\(mark.providerID) could not be rasterised at \(size)pt"
                )
                XCTAssertGreaterThan(
                    inked, 0.10,
                    "\(mark.providerID) covers \(inked) of its box at \(size)pt — it has thinned to nothing"
                )
            }
        }
    }

    /// Filled ink as a fraction of the box, through `SVGShape` — the same view
    /// both the panel row and the strip draw the mark with, so the scale-and-
    /// centre transform is under test too and not just the path data.
    @MainActor
    private func coverage(of mark: BrandMark, at size: CGFloat) -> Double? {
        let renderer = ImageRenderer(
            content: SVGShape(pathData: mark.pathData, viewBox: mark.viewBox)
                .fill(Color.black)
                .frame(width: size, height: size)
        )
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }

        var inked = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                // Half alpha, so an antialiased edge does not count as the
                // shape being there.
                guard let colour = bitmap.colorAt(x: x, y: y), colour.alphaComponent > 0.5 else { continue }
                inked += 1
            }
        }
        return Double(inked) / Double(bitmap.pixelsWide * bitmap.pixelsHigh)
    }

    // MARK: - Contrast

    /// Stand-ins for the menu bar, which is translucent over whatever the
    /// desktop happens to be and so has no one colour. These are the two ends of
    /// the range it lands in; a mark that clears both clears what is between.
    private static let menuBar: (light: UInt32, dark: UInt32) = (0xF5F5F5, 0x1C1C1C)

    /// Deliberately not the 4.5:1 body text owes. A filled glyph is found by its
    /// silhouette, and a brand's colour is the brand's, not ours to correct —
    /// the tightest thing shipping is Perplexity's cyan at ~2.2:1 on a light
    /// bar. What this catches is a mark that disappears outright, which is every
    /// near-black brand on a dark bar and the whole reason the ink functions
    /// have a low band at all.
    private static let inkFloor = 2.0

    /// The ink measured is `foreground(dark:)` and not `menuBarInk(dark:)`,
    /// because `MenuBarStripRenderer.markColour` draws the first one: measuring
    /// the second would report the contrast of a colour the strip never asks
    /// for. Where the two can differ is pinned separately, below.
    func testEveryMarkClearsTheInkFloorOnTheMenuBar() throws {
        for mark in BrandMark.all {
            for dark in [false, true] {
                let ground = Color(hex: dark ? Self.menuBar.dark : Self.menuBar.light)
                let ratio = try XCTUnwrap(
                    contrast(mark.foreground(dark: dark), on: ground, dark: dark),
                    "\(mark.providerID) could not be resolved in sRGB"
                )
                XCTAssertGreaterThanOrEqual(
                    ratio, Self.inkFloor,
                    "\(mark.providerID) measures \(ratio):1 on the \(dark ? "dark" : "light") menu bar"
                )
            }
        }
    }

    /// The two ink functions differ on exactly one branch: a mark too pale for a
    /// light ground is damped to 0.85 for the panel, which is an opaque surface
    /// that can be seen through the alpha, and substituted outright for the menu
    /// bar, which is translucent and would show the desktop through it instead.
    /// Nothing published is that pale, so the branch is unreached and the strip
    /// drawing `foreground(dark:)` costs nothing today. This is the test that
    /// fires the day a near-white brand arrives and the strip has to pick.
    func testTheInkFunctionsAgreeOnEveryShippingMark() {
        for mark in BrandMark.all {
            XCTAssertLessThanOrEqual(
                mark.luminance, 0.78,
                "\(mark.providerID) reaches the pale branch — the strip needs menuBarInk now"
            )
            for dark in [false, true] {
                XCTAssertEqual(
                    mark.foreground(dark: dark), mark.menuBarInk(dark: dark),
                    "\(mark.providerID) inks differently in the panel and on the bar"
                )
            }
        }
    }

    /// The same floor in the panel, where the ground is known rather than
    /// guessed at, so this one is exact. `Surface.base` is the ground the untiled
    /// logo style draws on; under `.tile` the mark sits on a 15% wash of its own
    /// hex, which moves the ground toward the ink — and the brands dark enough to
    /// vanish into that wash are the ones `tile(dark:)` already substitutes a
    /// neutral for, so the tightest case in the panel is still this one.
    func testEveryMarkClearsTheInkFloorOnThePanel() throws {
        for mark in BrandMark.all {
            for dark in [false, true] {
                let ratio = try XCTUnwrap(
                    contrast(mark.foreground(dark: dark), on: Tokens.Surface.base, dark: dark),
                    "\(mark.providerID) could not be resolved in sRGB"
                )
                XCTAssertGreaterThanOrEqual(
                    ratio, Self.inkFloor,
                    "\(mark.providerID) measures \(ratio):1 on the \(dark ? "dark" : "light") panel"
                )
            }
        }
    }

    func testNearBlackMarksFlipToLightOnDarkBackgrounds() throws {
        let openAI = try XCTUnwrap(BrandMark.mark(for: "chatgpt"))
        XCTAssertLessThan(openAI.luminance, 0.22)
        XCTAssertNotEqual(openAI.foreground(dark: true), Color(hex: openAI.hex))
        XCTAssertEqual(openAI.foreground(dark: false), Color(hex: openAI.hex))

        let claude = try XCTUnwrap(BrandMark.mark(for: "claude"))
        XCTAssertEqual(claude.foreground(dark: true), Color(hex: claude.hex))

        // The three marks the pass added that are near black. OpenCode's
        // published hex is pure black, which is the extreme case: on a dark bar
        // it is the background.
        for id in ["codex", "zai", "opencode"] {
            let mark = try XCTUnwrap(BrandMark.mark(for: id))
            XCTAssertLessThan(mark.luminance, 0.22, "\(id) no longer needs the dark-appearance flip")
            XCTAssertNotEqual(mark.foreground(dark: true), Color(hex: mark.hex), "\(id) stayed black on dark")
        }
    }

    // MARK: - Resolving

    /// One colour as sRGB components, resolved in a named appearance.
    ///
    /// `performAsCurrentDrawingAppearance` rather than assigning
    /// `NSAppearance.current`: the second is deprecated, and a deprecation
    /// warning is a build regression here.
    private func resolve(_ color: Color, dark: Bool) -> NSColor? {
        guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { return nil }
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return resolved
    }

    /// WCAG contrast, with the ink composited over the ground first: an ink that
    /// is damped rather than substituted carries the ground through it, and
    /// measuring the undamped colour would report a contrast nobody sees.
    private func contrast(_ ink: Color, on ground: Color, dark: Bool) -> Double? {
        guard let ink = resolve(ink, dark: dark), let ground = resolve(ground, dark: dark) else { return nil }
        let a = luminance(composite(ink, over: ground)), b = luminance(ground)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func composite(_ ink: NSColor, over ground: NSColor) -> NSColor {
        let alpha = ink.alphaComponent
        guard alpha < 1 else { return ink }
        func blend(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a * alpha + b * (1 - alpha) }
        return NSColor(
            srgbRed: blend(ink.redComponent, ground.redComponent),
            green:   blend(ink.greenComponent, ground.greenComponent),
            blue:    blend(ink.blueComponent, ground.blueComponent),
            alpha:   1
        )
    }

    private func luminance(_ colour: NSColor) -> Double {
        func linear(_ value: CGFloat) -> Double {
            let channel = Double(min(max(value, 0), 1))
            return channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(colour.redComponent)
             + 0.7152 * linear(colour.greenComponent)
             + 0.0722 * linear(colour.blueComponent)
    }
}

final class CountdownTests: XCTestCase {
    func testFormats() {
        let now = Date()
        XCTAssertEqual(Countdown.short(until: now.addingTimeInterval(45), from: now), "45s")
        XCTAssertEqual(Countdown.short(until: now.addingTimeInterval(90), from: now), "1m")
        XCTAssertEqual(Countdown.short(until: now.addingTimeInterval(3600 * 3 + 720), from: now), "3h 12m")
        XCTAssertEqual(Countdown.short(until: now.addingTimeInterval(86400 * 2 + 3600 * 4), from: now), "2d 4h")
        XCTAssertNil(Countdown.short(until: now.addingTimeInterval(-5), from: now))
    }
}
