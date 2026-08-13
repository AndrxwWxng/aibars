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

/// A scratch defaults domain, so the two settings the mark's ink is a function of
/// can be set here without deciding what another suite's "fresh install" looks
/// like — and, more to the point, without writing to the domain the running
/// developer's own app reads.
///
/// The same fixture `AppearanceMetricsTests` keeps at its own file scope, under a
/// different domain rather than shared between the two files: that suite asserts
/// what the resolver answers for a handful of ids, this one asserts it for every
/// brand in the register, and neither should be able to seed the other's store.
@MainActor
private func markInkSettings() -> AppearanceSettings {
    let domain = "aibars.brand-mark-tests.mark-ink"
    guard let store = UserDefaults(suiteName: domain) else {
        XCTFail("could not open a scratch defaults domain")
        return AppearanceSettings(store: .standard)
    }
    store.removePersistentDomain(forName: domain)
    return AppearanceSettings(store: store)
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

    /// The floor a mark owes now, which is body text's own.
    ///
    /// It used to be 2.0, and the comment justifying it said "a brand's colour
    /// is the brand's, not ours to correct". That premise is gone: identity is a
    /// silhouette in one ink, so there is no brand colour left to protect and no
    /// reason to accept Perplexity's cyan at 2.2:1 on a light bar. Every mark
    /// draws `Tokens.Ink.mark`, which clears 4.5:1 everywhere it lands.
    private static let inkFloor = 4.5

    /// The worst ground any ink in the panel lands on.
    ///
    /// It was recorded here as a hovered `.always` row card, `#E1E2E4` /
    /// `#262629`, and that was wrong twice over. `Fill.pressed` (0.12) is a step
    /// above `Fill.cardHover` (0.09) and `rowBackground` returns it for the
    /// whole row card, so the pressed card is worse than the hovered one; and
    /// neither of them was measured over the desktop, which the scrim only
    /// partly covers. The plane below is the pressed card over `Surface.base` at
    /// `scrimAlpha` over the wallpaper that pushes hardest — black in light,
    /// white in dark — with `.regularMaterial` modelled as contributing nothing,
    /// which is the strict upper bound on what a desktop can do to it.
    ///
    /// Written as literals here rather than composited, because this file's
    /// business is the marks rather than the palette: the arithmetic that
    /// produces these two, and the assertion that it still does, live in
    /// `GlyphColourTests.worstPressedPlane(dark:)`.
    private static let worstPlane: (light: UInt32, dark: UInt32) = (0xD0D1D3, 0x36373A)

    // `testEveryMarkDrawsTheOneMarkInk` was here, asserting that
    // `ProviderLogo.markInk(isLive: true)` was `Ink.mark` for every brand — the
    // rule that a mark's ink never varies with the brand. That rule is the one
    // this change replaces, and the accessor it called is deleted, so the test
    // could not be re-recorded: it is superseded by
    // `testMarkInkIsMutedInEveryNotReportingState` below, which asserts the half
    // of it that survived (nothing varies with the brand while a service is not
    // reporting) against the settings resolver that now owns the answer, and by
    // `testTheAchromaticLiveBandIsTheMarkInk`, which asserts the other half for
    // the seven brands that have no hue to spend.

    /// The mark ink on the menu bar, on the panel, and on the worst plane.
    ///
    /// Re-recorded with the palette: `Ink.mark` moved `0x3A3D45` → `0x383A42`
    /// light and `0xC8CCD3` → `0xC7CBD3` dark to put the three neutrals on even
    /// L\* steps, and every ground under it moved too. It measures 10.40 on the
    /// light menu bar and 10.48 on the dark one, 10.58 and 11.94 on
    /// `Surface.base`, and **7.42 and 7.32 on the worst plane** — which is the
    /// figure that matters, because it is the one the old "hovered card" ground
    /// was standing in for.
    func testTheMarkInkClearsBodyContrastEverywhereItLands() throws {
        let grounds: [(String, Color, Bool)] = [
            ("light menu bar", Color(hex: Self.menuBar.light), false),
            ("dark menu bar", Color(hex: Self.menuBar.dark), true),
            ("light panel", Tokens.Surface.base, false),
            ("dark panel", Tokens.Surface.base, true),
            ("light pressed card", Color(hex: Self.worstPlane.light), false),
            ("dark pressed card", Color(hex: Self.worstPlane.dark), true)
        ]
        for (name, ground, dark) in grounds {
            let ratio = try XCTUnwrap(contrast(Tokens.Ink.mark, on: ground, dark: dark))
            XCTAssertGreaterThanOrEqual(
                ratio, Self.inkFloor,
                "the mark ink measures \(ratio):1 on the \(name)"
            )
        }
    }

    /// A mark that is not reporting is drawn in a different ink, not a fade.
    /// `Dim.disconnected` composited Gemini at 1.92:1 in light, across a whole
    /// first-run panel; `Ink.muted` at full opacity measures this.
    ///
    /// `muted` is the palette's floor by construction — anything quieter fails
    /// 4.5:1 on the plane below — so this pair is the tightest in the file:
    /// 6.85 and 7.85 on `Surface.base`, **4.80 and 4.81** on the pressed card,
    /// against a 4.5 floor.
    ///
    /// The token directly rather than through an accessor, because the accessor it
    /// used to call (`ProviderLogo.markInk(isLive: false)`) is deleted. The value
    /// is byte-identical — `AppearanceSettings.markInk` still answers `Ink.muted`
    /// here, and `testMarkInkIsMutedInEveryNotReportingState` is what proves it —
    /// so this test measures the same colour it always measured.
    func testTheNotReportingInkClearsBodyContrastToo() throws {
        for dark in [false, true] {
            let card = Color(hex: dark ? Self.worstPlane.dark : Self.worstPlane.light)
            for (name, ground) in [("panel", Tokens.Surface.base), ("pressed card", card)] {
                let ratio = try XCTUnwrap(contrast(Tokens.Ink.muted, on: ground, dark: dark))
                XCTAssertGreaterThanOrEqual(
                    ratio, Self.inkFloor,
                    "the not-reporting mark ink measures \(ratio):1 on the \(dark ? "dark" : "light") \(name)"
                )
            }
        }
    }

    /// The two surfaces that still ask for brand hue — the strip under `.perBar`
    /// and meters and figures under `ColorRamp.provider` — take the banded pair,
    /// and the band is cut so it is legal as a *figure* and not merely as a bar.
    ///
    /// The light half of that band was re-cut for this test's new ground and not
    /// for taste: at OKLCh L 0.48 every entry measured L\* ≈ 42 and **3.91–3.93**
    /// on the pressed card, under the floor asserted here, while reading as 4.5+
    /// on the hovered card this used to measure against. Re-banded to L 0.455 it
    /// runs L\* 35.66–37.63, **4.62–4.97** on the pressed card and 6.59–7.09 on
    /// `Surface.base`. The dark half was already legal there — L\* 75.80–77.74,
    /// 6.18–6.55 and 10.09–10.69 — and did not move.
    func testEveryBandedBrandInkIsLegalAsAFigure() throws {
        for mark in BrandMark.all {
            for dark in [false, true] {
                let card = Color(hex: dark ? Self.worstPlane.dark : Self.worstPlane.light)
                for (name, ground) in [("panel", Tokens.Surface.base), ("pressed card", card)] {
                    let ratio = try XCTUnwrap(
                        contrast(mark.brandInk(dark: dark), on: ground, dark: dark),
                        "\(mark.providerID) could not be resolved in sRGB"
                    )
                    XCTAssertGreaterThanOrEqual(
                        ratio, 4.5,
                        "\(mark.providerID) banded ink measures \(ratio):1 on the "
                        + "\(dark ? "dark" : "light") \(name)"
                    )
                }
            }
        }
    }

    // MARK: - The live band

    /// The band a mark is drawn in when the user leaves brand colour on: every
    /// entry, both appearances, past the 3:1 a graphic owes its ground.
    ///
    /// A second band and not a second opinion. `brandInk` above is cut for a
    /// meter fill and a percentage, so it holds a *figure's* lightness; a mark
    /// is neither, and painting an 18pt silhouette at the figure band measures
    /// 7.04 on `Surface.base` for a live Claude, which is the `muted` rung — a
    /// service that *is* reporting drawn at the weight this app uses to say one
    /// is not, against `mark`'s own 10.58 on the same ground. So the
    /// live band holds `Ink.mark`'s lightness exactly and spends the brand on
    /// hue alone.
    ///
    /// 3:1 rather than 4.5 is the right floor and the wrong bound: a mark is a
    /// graphic, but this band is pinned to an ink that clears body text, so the
    /// measured range is nowhere near it. On `Surface.base`, **10.28–10.91**
    /// light and **11.60–12.21** dark; on the pressed card, **7.21–7.65** and
    /// **7.11–7.48**. The minimum anywhere is 7.11 (MiniMax, dark pressed card),
    /// which is a little over twice the floor — and that is the property the
    /// escape hatch rests on rather than a margin to spend: switching brand
    /// colour off has to remove a hue and move no measurement.
    func testEveryLiveBrandInkClearsThreeToOne() throws {
        for mark in BrandMark.all {
            for dark in [false, true] {
                let card = Color(hex: dark ? Self.worstPlane.dark : Self.worstPlane.light)
                for (name, ground) in [("panel", Tokens.Surface.base), ("pressed card", card)] {
                    let ratio = try XCTUnwrap(
                        contrast(mark.liveInk(dark: dark), on: ground, dark: dark),
                        "\(mark.providerID) could not be resolved in sRGB"
                    )
                    XCTAssertGreaterThanOrEqual(
                        ratio, 3,
                        "\(mark.providerID)'s live ink measures \(ratio):1 on the "
                        + "\(dark ? "dark" : "light") \(name)"
                    )
                }
            }
        }
    }

    /// No brand is allowed to be as saturated as an alarm.
    ///
    /// This is the whole of what keeps an opt-in identity from becoming a third
    /// thing that means "act": there are two hues in the application, amber and
    /// red, and a mark drawn louder than either would be a fifteen-way colour
    /// vocabulary competing with a two-way one. The ceiling is **OKLCh C 0.070**
    /// in both appearances, applied *before* the derivation so a raw hue louder
    /// than it is simply clamped — which is why the loudest value the set
    /// produces is 0.0704 light and 0.0705 dark rather than something under.
    /// 0.072 is the assertion, allowing the two 8-bit quantisation steps between
    /// the derivation and the shipped hex.
    ///
    /// The second bound is the one that carries the meaning, and it is stated
    /// against the live token rather than a number: `Ink.attention` measures
    /// C 0.0965 light and 0.1506 dark, `Ink.alarm` 0.1414 and 0.1069, so the
    /// binding case is the light amber — the quietest thing in the app that
    /// means "act" — and the ceiling is 0.725× it. Asserting it against
    /// `Tokens.Ink.attention` rather than against 0.0965 is deliberate: if the
    /// amber is ever re-cut quieter, this is the test that has to fail.
    ///
    /// Perplexity's light half is the one entry under the ceiling and not by
    /// choice: the sRGB gamut at L 0.3496 and h 209.8 runs out at C 0.0606.
    func testNoLiveBandExceedsTheChromaCeiling() throws {
        // The converter first, or the loop under it is fifteen measurements of
        // nothing. These four are the values `BrandMarks.swift` and
        // `DesignSystem.swift` state, so reproducing them is the proof that this
        // OKLab is the one those bands were cut in.
        for (name, colour, expected) in [
            ("attention", Tokens.Ink.attention, (light: 0.0965, dark: 0.1506)),
            ("alarm", Tokens.Ink.alarm, (light: 0.1414, dark: 0.1069))
        ] as [(String, Color, (light: Double, dark: Double))] {
            let light = chroma(try XCTUnwrap(resolve(colour, dark: false)))
            let dark = chroma(try XCTUnwrap(resolve(colour, dark: true)))
            XCTAssertEqual(light, expected.light, accuracy: 0.0005, "\(name) light")
            XCTAssertEqual(dark, expected.dark, accuracy: 0.0005, "\(name) dark")
        }
        XCTAssertEqual(
            lightness(try XCTUnwrap(resolve(Tokens.Ink.mark, dark: false))), 0.3496, accuracy: 0.0005,
            "the band's own lightness is not where BrandMarks says it is"
        )
        XCTAssertEqual(
            lightness(try XCTUnwrap(resolve(Tokens.Ink.mark, dark: true))), 0.8414, accuracy: 0.0005
        )

        for dark in [false, true] {
            let alarmFloor = min(
                chroma(try XCTUnwrap(resolve(Tokens.Ink.attention, dark: dark))),
                chroma(try XCTUnwrap(resolve(Tokens.Ink.alarm, dark: dark)))
            )
            for mark in BrandMark.all {
                let brand = chroma(try XCTUnwrap(resolve(mark.liveInk(dark: dark), dark: dark)))
                XCTAssertLessThanOrEqual(
                    brand, 0.072,
                    "\(mark.providerID)'s live ink is C \(brand) in \(dark ? "dark" : "light")"
                )
                XCTAssertLessThan(
                    brand, alarmFloor,
                    "\(mark.providerID) is C \(brand) in \(dark ? "dark" : "light"), which is as loud "
                    + "as the quieter alarm at \(alarmFloor) — a mark cannot out-shout an alert"
                )
            }
        }
    }

    /// Every entry in the band lands within 0.35:1 of `Ink.mark`'s own contrast,
    /// on every ground a mark is drawn on, in both appearances.
    ///
    /// This is the assertion `AppearanceSettings.coloursBrandMarks` rests on. The
    /// switch is safe to ship on by default only if turning it off removes a hue
    /// and moves nothing else — otherwise it is not a colour switch, it is a
    /// second look, and every contrast figure in the app would have to be recorded
    /// twice. Pinning the band to `Ink.mark`'s lightness is what buys that, and
    /// this is the test that says the pinning held.
    ///
    /// Measured, the widest deviation in the set is **+0.3471** — MiniMax on
    /// `Surface.raised` in light, 11.69:1 against the mark ink's 11.34:1 — with
    /// **−0.34** (MiniMax, dark `Surface.base`) the widest the other way. The
    /// bound is 0.35 because that is where the measurement landed, not the other
    /// way round: a band re-cut loose enough to fail this has stopped being a hue
    /// change.
    ///
    /// Six grounds rather than two, because the panel is not the only place a mark
    /// is drawn: the connect dialog is `Surface.raised`, a tiled logo sits on its
    /// own plate, and the strip takes the resolved half of this same band onto a
    /// menu bar whose ends are the last two.
    func testEveryLiveBandHoldsTheMarkInksWeight() throws {
        for dark in [false, true] {
            let grounds: [(String, Color)] = [
                ("Surface.base", Tokens.Surface.base),
                ("the worst plane", Color(hex: dark ? Self.worstPlane.dark : Self.worstPlane.light)),
                ("Surface.raised", Tokens.Surface.raised),
                ("the logo tile", try XCTUnwrap(logoTile(dark: dark))),
                ("the menu bar", Color(hex: dark ? Self.menuBar.dark : Self.menuBar.light))
            ]
            for (name, ground) in grounds {
                let neutral = try XCTUnwrap(contrast(Tokens.Ink.mark, on: ground, dark: dark))
                for mark in BrandMark.all {
                    let brand = try XCTUnwrap(contrast(mark.liveInk(dark: dark), on: ground, dark: dark))
                    XCTAssertEqual(
                        brand, neutral, accuracy: 0.35,
                        "\(mark.providerID)'s live ink measures \(brand):1 on \(name) in "
                        + "\(dark ? "dark" : "light") where the mark ink measures \(neutral):1 — "
                        + "brand colour has started changing weight and not only hue"
                    )
                }
            }
        }
    }

    /// A brand with no hue is the general rule evaluated at zero chroma, and at
    /// zero chroma the band's own lightness *is* `Ink.mark` — so seven of the
    /// fifteen draw exactly what they drew before any of this existed.
    ///
    /// Byte-equal and not merely close, because `achromaticBand` is written as two
    /// literals rather than reached through `Tokens.Ink.mark`: `liveInk(dark:)` is
    /// resolved rather than dynamic, and the strip takes one half of it. This is
    /// the test that stops the duplication drifting, and it is the reason the
    /// duplication is allowed to exist.
    ///
    /// The membership is asserted rather than listed. `BrandMarks.swift` used to
    /// say six near-black marks and Copilot was the one it left out, on a raw
    /// `0x181717` that measures OKLCh C 0.0016 — as achromatic as Grok's
    /// `0x0A0A0A`. So the second half walks all fifteen and checks that the set
    /// landing on the mark ink is exactly the set whose raw hex is under C 0.02,
    /// which makes the count a measurement instead of a sentence.
    func testTheAchromaticLiveBandIsTheMarkInk() throws {
        let achromatic = ["chatgpt", "codex", "cursor", "copilot", "grok", "zai", "opencode"]
        for providerID in achromatic {
            let mark = try XCTUnwrap(BrandMark.mark(for: providerID), "\(providerID) has no mark")
            for dark in [false, true] {
                XCTAssertEqual(
                    hex(mark.liveInk(dark: dark), dark: dark), hex(Tokens.Ink.mark, dark: dark),
                    "\(providerID)'s live ink has drifted from the mark ink in "
                    + "\(dark ? "dark" : "light")"
                )
            }
        }

        for mark in BrandMark.all {
            let raw = chroma(try XCTUnwrap(resolve(Color(hex: mark.hex), dark: false)))
            let listed = achromatic.contains(mark.providerID)
            XCTAssertEqual(
                listed, raw < 0.02,
                "\(mark.providerID)'s raw hex is C \(raw) and it is \(listed ? "" : "not ")on the "
                + "achromatic list — the list and the measurement disagree"
            )
            for dark in [false, true] {
                XCTAssertEqual(
                    hex(mark.liveInk(dark: dark), dark: dark) == hex(Tokens.Ink.mark, dark: dark),
                    listed,
                    "\(mark.providerID) resolves to the mark ink in \(dark ? "dark" : "light") "
                    + "and should\(listed ? "" : " not")"
                )
            }
        }
    }

    /// Copilot's own band entry is gone, and this is what stops it coming back.
    ///
    /// It returned `(0x656363, 0xBFBDBD)` where the fallback returns
    /// `(0x575757, 0xBEBEBE)` — OKLab ΔE 0.0031 light and 0.0027 dark, one 8-bit
    /// step per channel and about a thirtieth of the smallest difference an eye
    /// resolves. A `case` implies a decision somebody made; that one implied a
    /// decision nothing could see, and it would have been maintained forever.
    ///
    /// Asserted against Grok rather than against the two hexes, because the claim
    /// is that Copilot takes *the same fallback every other hueless mark takes* —
    /// quoting `neutralBand`'s literals here would let the pair drift together and
    /// still pass.
    func testCopilotHasNoBandOfItsOwn() throws {
        let copilot = try XCTUnwrap(BrandMark.mark(for: "copilot"))
        let fallback = try XCTUnwrap(BrandMark.mark(for: "grok"))
        for dark in [false, true] {
            XCTAssertEqual(
                hex(copilot.brandInk(dark: dark), dark: dark),
                hex(fallback.brandInk(dark: dark), dark: dark),
                "Copilot has been given a band of its own again in \(dark ? "dark" : "light")"
            )
        }
    }

    // MARK: - The three-way answer

    /// Not reporting is the muted ink for every one of the fifteen, under every
    /// colour ramp and both positions of the brand-colour switch.
    ///
    /// The first branch of `markInk(for:isLive:)`, and the one the old arrangement
    /// got wrong everywhere but the panel row: `ProviderLogo.ink` defaulted to nil
    /// and nil meant "reporting", so the Settings list, the Budget pane, the
    /// connect dialog and the Appearance sample drew every mark at the reporting
    /// ink whatever state their subject was in.
    ///
    /// The whole matrix rather than a sample — 15 brands × 4 ramps × 2 switch
    /// positions × 2 appearances, 240 comparisons — because the point of this
    /// branch is that nothing above it can reach it. A brand hue that survived
    /// into a signed-out row would put the loudest treatment in the panel on the
    /// row with the least to say, and it would only show up for the one brand and
    /// the one ramp that leaked.
    @MainActor
    func testMarkInkIsMutedInEveryNotReportingState() {
        let appearance = markInkSettings()
        for ramp in AppearanceSettings.ColorRamp.allCases {
            appearance.colorRamp = ramp
            for colours in [true, false] {
                appearance.coloursBrandMarks = colours
                for mark in BrandMark.all {
                    let ink = appearance.markInk(for: mark.providerID, isLive: false)
                    for dark in [false, true] {
                        XCTAssertEqual(
                            hex(ink, dark: dark), hex(Tokens.Ink.muted, dark: dark),
                            "\(mark.providerID) under \(ramp.rawValue) with brand colour "
                            + "\(colours ? "on" : "off") drew \(dark ? "dark" : "light") ink that is "
                            + "not the muted one, while it was not reporting"
                        )
                    }
                }
            }
        }
    }

    /// Optical mass, not hue, is the other half of the "row of stickers"
    /// complaint: coverage across the set varies 2.7×. Every entry carries a
    /// scale, and it lands the set inside a narrow band.
    func testEveryMarkCarriesAnOpticalScaleInRange() {
        for mark in BrandMark.all {
            XCTAssertGreaterThanOrEqual(mark.opticalScale, 0.80, "\(mark.providerID)")
            XCTAssertLessThanOrEqual(mark.opticalScale, 1.10, "\(mark.providerID)")
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

    /// One colour as the 0xRRGGBB a screen would show, for the assertions whose
    /// claim is byte-equality rather than a ratio. Rounded to eight bits on
    /// purpose: `achromaticBand` and `Tokens.Ink.mark` are two literals that have
    /// to be the same *colour*, and comparing `Color` values or float components
    /// would fail on a representation difference that nothing can see.
    private func hex(_ color: Color, dark: Bool) -> UInt32? {
        guard let srgb = resolve(color, dark: dark) else { return nil }
        func channel(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return channel(srgb.redComponent) << 16
             | channel(srgb.greenComponent) << 8
             | channel(srgb.blueComponent)
    }

    /// The logo plate as an opaque ground.
    ///
    /// `ProviderLogo.tile` fills `quiet(Fill.logoTile)` — 7% ink — over whatever
    /// the logo was dropped on, and a translucent ground cannot be handed to
    /// `contrast(_:on:dark:)`: it would measure the mark against a colour with a
    /// hole in it. Composited from the two live tokens rather than recorded as a
    /// hex the way `worstPlane` is, because `Fill.logoTile` is one of the things
    /// this measurement is watching, and a literal here would go on passing after
    /// the plate moved.
    private func logoTile(dark: Bool) -> Color? {
        guard let plate = resolve(Tokens.quiet(Tokens.Fill.logoTile), dark: dark),
              let ground = resolve(Tokens.Surface.base, dark: dark) else { return nil }
        return Color(nsColor: composite(plate, over: ground))
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

    // MARK: - OKLab

    /// sRGB to OKLab, written out for the same reason the WCAG arithmetic above
    /// is: both bands in `BrandMarks.swift` are stated in OKLCh, so a test that
    /// cannot measure chroma can only assert that the hexes are the hexes.
    ///
    /// Björn Ottosson's published matrices, unmodified. The transfer function is
    /// the sRGB one with the 0.04045 knee rather than WCAG's 0.03928 — they are
    /// the same curve with two different roundings of the same constant, and
    /// each is quoted here as its own specification writes it.
    private func oklab(_ colour: NSColor) -> (lightness: Double, a: Double, b: Double) {
        func linear(_ value: CGFloat) -> Double {
            let channel = Double(min(max(value, 0), 1))
            return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let r = linear(colour.redComponent)
        let g = linear(colour.greenComponent)
        let b = linear(colour.blueComponent)
        let long = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let medium = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let short = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        return (
            0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short,
            1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short,
            0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short
        )
    }

    /// How much colour a colour has, independent of how light it is — which is
    /// the axis a chroma ceiling is a ceiling on.
    private func chroma(_ colour: NSColor) -> Double {
        let lab = oklab(colour)
        return (lab.a * lab.a + lab.b * lab.b).squareRoot()
    }

    /// OKLab's L, not CIE L\*. Both bands are pinned to a lightness in this
    /// space, so this is the number that says a band held it.
    private func lightness(_ colour: NSColor) -> Double {
        oklab(colour).lightness
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
