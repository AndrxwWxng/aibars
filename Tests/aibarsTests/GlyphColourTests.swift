import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// The usage ramp, checked against the ground it is drawn on.
///
/// This matters more than a palette test usually would, because every stop here
/// is also the colour of a percentage: the ramp is not decoration on a bar, it
/// is body text. So each stop has to clear 4.5:1 against `Tokens.Surface.base`
/// in the appearance it resolves to — which is the whole reason each stop is a
/// light/dark pair rather than one fixed value.
final class UsageRampContrastTests: XCTestCase {
    /// The three stops, sampled inside their own bands rather than at the
    /// boundaries, so a boundary moving cannot quietly change which colour is
    /// under test.
    private let stops: [(name: String, percent: Double)] = [
        ("teal", 0.10),
        ("amber", 0.70),
        ("red", 0.95)
    ]

    func testEveryStopClearsBodyTextContrastOnTheSurfaceItSitsOn() throws {
        for stop in stops {
            for dark in [false, true] {
                let ratio = try XCTUnwrap(
                    contrast(UsageTint.color(for: stop.percent), on: Tokens.Surface.base, dark: dark),
                    "\(stop.name) could not be resolved in sRGB"
                )
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(stop.name) measures \(ratio):1 on \(dark ? "dark" : "light") — it is a percentage as well as a bar, so it is body text"
                )
            }
        }
    }

    /// The figures the palette was chosen against, so that a stop being nudged
    /// shows up as a number rather than as "still above 4.5".
    ///
    /// The tolerance covers the last decimal only: the published figures were
    /// measured to two places, and sRGB round-tripping through `NSColor` moves
    /// the third.
    func testTheRecordedContrastFiguresStillHold() throws {
        let expected: [(name: String, percent: Double, light: Double, dark: Double)] = [
            ("teal", 0.10, 5.34, 7.48),
            ("amber", 0.70, 4.95, 7.70),
            ("red", 0.95, 5.02, 5.22)
        ]
        for stop in expected {
            let light = try XCTUnwrap(
                contrast(UsageTint.color(for: stop.percent), on: Tokens.Surface.base, dark: false)
            )
            let dark = try XCTUnwrap(
                contrast(UsageTint.color(for: stop.percent), on: Tokens.Surface.base, dark: true)
            )
            XCTAssertEqual(light, stop.light, accuracy: 0.15, "\(stop.name) on light")
            XCTAssertEqual(dark, stop.dark, accuracy: 0.15, "\(stop.name) on dark")
        }
    }

    /// A single fixed value cannot serve both appearances, which is the reason
    /// the ramp goes through `Tokens.dynamic` at all. A stop resolving to one
    /// colour in both has stopped doing that.
    func testTheRampResolvesDifferentlyInEachAppearance() throws {
        for stop in stops {
            let colour = UsageTint.color(for: stop.percent)
            let light = try XCTUnwrap(hex(colour, dark: false))
            let dark = try XCTUnwrap(hex(colour, dark: true))
            XCTAssertNotEqual(light, dark, "\(stop.name) resolved to one value in both appearances")
        }
    }

    // MARK: - Bands

    /// The boundaries are at exactly 0.60 and 0.85, and the value *at* a
    /// boundary belongs to the band above it. 85% is warned about rather than
    /// cautioned about; the other way round is the app rounding in the
    /// provider's favour.
    func testABoundaryValueBelongsToTheHigherBand() throws {
        let teal = try XCTUnwrap(hex(UsageTint.color(for: 0), dark: true))
        let amber = try XCTUnwrap(hex(UsageTint.color(for: 0.70), dark: true))
        let red = try XCTUnwrap(hex(UsageTint.color(for: 1), dark: true))
        XCTAssertNotEqual(teal, amber)
        XCTAssertNotEqual(amber, red)

        XCTAssertEqual(hex(UsageTint.color(for: 0.599), dark: true), teal)
        XCTAssertEqual(hex(UsageTint.color(for: 0.60), dark: true), amber, "0.60 is caution, not resting")
        XCTAssertEqual(hex(UsageTint.color(for: 0.849), dark: true), amber)
        XCTAssertEqual(hex(UsageTint.color(for: 0.85), dark: true), red, "0.85 is the warning, not the top of caution")
    }

    // MARK: - The menu bar's one colour

    /// Colour in the menu bar is spent only when it is carrying a warning — and
    /// the line it warns about is the user's, not this file's.
    ///
    /// This used to assert `UsageTint.menuBarTint`, which is deleted. That
    /// function answered against a hardcoded 0.85 while the panel beside it read
    /// the setting, so a user who dragged the warning threshold to 0.70 got a red
    /// row and a grey strip reporting the same number. The survivor reads the
    /// threshold, and a changed threshold is therefore what is asserted here:
    /// re-pointing the test at the identical shipped default would have left the
    /// duplicate's only real fault untested.
    @MainActor
    func testMenuBarTintIsSpentOnlyAtTheConfiguredWarning() throws {
        let appearance = settings("menu-bar-tint")

        appearance.warningThreshold = 0.70
        XCTAssertNil(appearance.menuBarTint(for: 0.65), "0.65 is below a warning the user set at 0.70")
        XCTAssertNotNil(appearance.menuBarTint(for: 0.70), "0.70 is the warning the user set")

        // And the other direction, which the fixed threshold got wrong too: a
        // user who moved the line *up* was alarmed before reaching it.
        appearance.warningThreshold = 0.95
        XCTAssertNil(appearance.menuBarTint(for: 0.90), "0.90 is below a warning the user set at 0.95")
        XCTAssertNotNil(appearance.menuBarTint(for: 0.95))

        // Wherever the line is, the strip has one colour and it is the alarm.
        // Compared against the ramp's top stop rather than against
        // `color(for: 0.95)` — the same hex today, but the second would be
        // asserting "the colour of 95%" when what the strip means is "this
        // crossed the line".
        let tint = try XCTUnwrap(appearance.menuBarTint(for: 0.95))
        XCTAssertEqual(hex(tint, dark: true), hex(UsageTint.color(for: 0.85), dark: true))
    }

    /// The same function's other half, and the second thing the duplicate could
    /// not see: whether the strip takes a tint at all is a setting.
    /// `.monochrome` asks for a template image, and a tint is exactly what makes
    /// AppKit stop treating the rasterised strip as one.
    @MainActor
    func testMonochromeLeavesTheStripUntintedAtAnyReading() {
        let appearance = settings("menu-bar-monochrome")
        appearance.menuBarColour = .monochrome
        appearance.warningThreshold = 0.70
        XCTAssertNil(appearance.menuBarTint(for: 0.70))
        XCTAssertNil(appearance.menuBarTint(for: 1), "monochrome means monochrome at the cap too")
    }

    // MARK: - The cut

    /// The clearance punched through a fill so the pace riser survives it.
    ///
    /// Both forms of the meter punch the same hole: the bar draws the covered
    /// half of its riser in `Surface.onFill`, and the dial draws its radial tick
    /// in the same colour once the arc has passed it. It is only a hole if that
    /// colour is the ground exactly — a value a shade off reads as a grey mark
    /// laid *on* the fill, which is a fourth thing on the bar rather than a gap
    /// in it, and the two tokens drifting apart is a silent way to get there.
    func testTheCutIsTheGroundExactlyInBothAppearances() throws {
        for dark in [false, true] {
            let cut = try XCTUnwrap(hex(Tokens.Surface.onFill, dark: dark))
            let ground = try XCTUnwrap(hex(Tokens.Surface.base, dark: dark))
            XCTAssertEqual(
                cut, ground,
                "the cut is \(String(cut, radix: 16)) on \(dark ? "dark" : "light") where the ground is \(String(ground, radix: 16))"
            )
            // And it is not the riser's own colour. The riser above the bar and
            // the cut through it are two marks with opposite jobs, so a change
            // that collapsed them would erase the cut rather than move it.
            XCTAssertNotEqual(cut, hex(Tokens.Meter.notch, dark: dark))
        }
    }

    // MARK: - Resolving

    /// A scratch defaults domain per test, so one test's writes cannot decide
    /// another's starting state — these assert against thresholds they move.
    @MainActor
    private func settings(_ name: String) -> AppearanceSettings {
        let domain = "aibars.glyph-colour-tests.\(name)"
        guard let store = UserDefaults(suiteName: domain) else {
            XCTFail("could not open a scratch defaults domain")
            return AppearanceSettings(store: .standard)
        }
        store.removePersistentDomain(forName: domain)
        return AppearanceSettings(store: store)
    }

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

    private func hex(_ color: Color, dark: Bool) -> UInt32? {
        guard let srgb = resolve(color, dark: dark) else { return nil }
        func channel(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return channel(srgb.redComponent) << 16
             | channel(srgb.greenComponent) << 8
             | channel(srgb.blueComponent)
    }

    /// WCAG relative luminance and contrast ratio, written out rather than
    /// reached for, because the arithmetic is the point of the assertion.
    private func contrast(_ color: Color, on background: Color, dark: Bool) -> Double? {
        guard let ink = resolve(color, dark: dark),
              let ground = resolve(background, dark: dark) else { return nil }
        let a = luminance(ink), b = luminance(ground)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
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

/// The cut on the dial, at the thickness floor the bar is held to.
///
/// One rule, two forms. `MeterCut.isCut` refuses below `cutMinBarHeight` because
/// a gap as wide as the bar is thick reads as a bar snapped in two, and the dial
/// draws the same band radially across its stroke — so the stroke is the
/// thickness it has to be judged on, and the floor means the same thing there.
///
/// Worth its own tests rather than trusting the shared function, because the dial
/// meets the floor from a place the bar never does: `UsageRing` keeps a hole a
/// third of its width, so its stroke is capped at `diameter / 3` however thick
/// the meter setting asks for. A dial can therefore fall under the floor while a
/// bar on the same setting sits comfortably over it, and that is the case where
/// two forms of one instrument could quietly start disagreeing about whether a
/// reading is overspending.
final class RingCutTests: XCTestCase {
    /// A reading that has overtaken its pace boundary: 80% spent, 40% of the
    /// window gone. Sampled well clear of the boundary, so nothing here is
    /// asserting where `fillHasPassedNotch` rounds.
    private let overspending = (percent: 0.80, elapsed: 0.40)

    /// The stroke a dial draws at, which is what it hands the cut where the bar
    /// hands its thickness. `UsageRing` derives it exactly this way; it is
    /// restated rather than reached for because the dial's own copy is private
    /// and this is the input under test, not the drawing.
    private func stroke(thickness: CGFloat, diameter: CGFloat) -> CGFloat {
        min(thickness, diameter / 3)
    }

    /// The boundary itself, in the dial's terms: a stroke at the floor cuts, a
    /// stroke a point under it does not. The same two assertions the bar makes,
    /// which is the point — a floor that only one form honoured would be a floor
    /// the panel does not have.
    func testTheDialCutsAtTheFloorAndNotBelowIt() {
        XCTAssertTrue(
            MeterCut.isCut(
                percent: overspending.percent,
                elapsed: overspending.elapsed,
                barHeight: Tokens.Meter.cutMinBarHeight
            ),
            "a stroke exactly at the floor is thick enough to hold a cut"
        )
        XCTAssertFalse(
            MeterCut.isCut(
                percent: overspending.percent,
                elapsed: overspending.elapsed,
                barHeight: Tokens.Meter.cutMinBarHeight - 1
            ),
            "a stroke under the floor would be broken by the gap rather than interrupted"
        )
    }

    /// The dial's ceiling against the cut's floor, at the two ends of the
    /// meter-thickness setting and at the diameters the leading column actually
    /// produces — the headline dial, and the secondary chip's dial at 0.55 of it.
    ///
    /// The headline dial at the default thickness lands on the floor; the chip's
    /// dial cannot reach it at any thickness, because a third of 12pt is 4. So the
    /// small dial goes on drawing its riser in `Surface.onFill` where the arc
    /// covers it, which is the reading a 3pt bar carries too, and neither form
    /// invents a cut it has no room for.
    func testTheDialsCeilingDecidesWhetherItCanCutAtAll() {
        let cases: [(thickness: CGFloat, diameter: CGFloat, cuts: Bool)] = [
            (5, 22, true),    // the default: stroke 5, exactly on the floor
            (12, 22, true),   // the thickest setting on the same dial: stroke 7.3
            (12, 12, false),  // the chip's dial: the third-of-its-width cap bites first
            (3, 22, false)    // the thinnest setting: the dial is as thin as the bar
        ]
        for (thickness, diameter, cuts) in cases {
            let height = stroke(thickness: thickness, diameter: diameter)
            XCTAssertEqual(
                MeterCut.isCut(
                    percent: overspending.percent,
                    elapsed: overspending.elapsed,
                    barHeight: height
                ),
                cuts,
                "a \(diameter)pt dial at \(thickness)pt strokes at \(height)pt, against a floor of \(Tokens.Meter.cutMinBarHeight)"
            )
        }
    }

    /// Why the floor is where it is, held to in both contrast modes: the gap is
    /// always narrower than the thinnest bar it is allowed on. Under increased
    /// contrast the riser widens and the gap widens with it, and that is the case
    /// the floor has to survive — a cut as wide as its own bar is the broken bar
    /// the floor exists to prevent, on the dial as much as on the bar.
    func testTheGapIsNarrowerThanTheThinnestBarItIsAllowedOn() {
        for increased in [false, true] {
            XCTAssertLessThan(
                MeterCut.width(increasedContrast: increased),
                Tokens.Meter.cutMinBarHeight,
                "the cut measures \(MeterCut.width(increasedContrast: increased))pt with increased contrast \(increased ? "on" : "off")"
            )
        }
    }

    /// A window nobody described has no boundary to overtake, so there is nothing
    /// to cut whatever the stroke — the dial's version of the uniform track, and
    /// the reason `isCut` takes the optional rather than each caller unwrapping it
    /// and reaching its own conclusion.
    func testAnUndescribedWindowIsNeverCut() {
        XCTAssertFalse(
            MeterCut.isCut(percent: 1, elapsed: nil, barHeight: Tokens.Meter.cutMinBarHeight * 2)
        )
    }
}

/// The app mark, at the two sizes the app actually draws it.
///
/// It carries no data any more, so there is nothing to assert about what it
/// says — only that it says it visibly. The pair of sizes is the real check: the
/// mark is one shape scaled off `size`, and its bars are 3–4pt wide at the small
/// end, which is exactly where a rounding mistake empties the image.
final class AppMarkTests: XCTestCase {
    /// The status item's own height. A literal rather than a setting: this is
    /// the small end of the range the mark has to survive, not a preference.
    private let menuBarHeight: CGFloat = 13

    /// Inked pixels, and the size the mark laid itself out at.
    @MainActor
    private func render(size: CGFloat) -> (inked: Int, layout: CGSize)? {
        let renderer = ImageRenderer(content: AppMark(size: size, tint: .black))
        renderer.scale = 2

        var layout = CGSize.zero
        renderer.render { measured, _ in layout = measured }

        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }

        var inked = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                // Half alpha, so the antialiased edge of a 3pt bar does not
                // count as the bar being there.
                guard let colour = bitmap.colorAt(x: x, y: y), colour.alphaComponent > 0.5 else { continue }
                inked += 1
            }
        }
        return (inked, layout)
    }

    @MainActor
    func testTheMarkDrawsAtHeaderSize() throws {
        let drawn = try XCTUnwrap(render(size: Tokens.Control.headerGlyph))
        XCTAssertGreaterThan(drawn.inked, 0, "the mark came out blank at header size")
    }

    @MainActor
    func testTheMarkDrawsAtAboutSize() throws {
        let drawn = try XCTUnwrap(render(size: Tokens.Control.aboutGlyph))
        XCTAssertGreaterThan(drawn.inked, 0, "the mark came out blank at About size")
    }

    /// The larger mark is more ink than the smaller one — the cheapest way to
    /// say the profile scales rather than collapsing onto its floors.
    @MainActor
    func testTheMarkScalesWithItsSize() throws {
        let small = try XCTUnwrap(render(size: Tokens.Control.headerGlyph))
        let large = try XCTUnwrap(render(size: Tokens.Control.aboutGlyph))
        XCTAssertGreaterThan(large.inked, small.inked)
    }

    /// Whole-point geometry. The status item resamples a fractional image to fit
    /// its slot, and half a point of resampling is visible blur on a mark that is
    /// mostly 3pt-wide bars — which is what the mark had while its spacing and
    /// its plot height were the two measurements nobody rounded.
    @MainActor
    func testTheMarkLaysItselfOutOnWholePoints() throws {
        for size in [menuBarHeight, Tokens.Control.headerGlyph, Tokens.Control.aboutGlyph] {
            let drawn = try XCTUnwrap(render(size: size))
            XCTAssertEqual(
                drawn.layout.width, drawn.layout.width.rounded(),
                "the mark measured \(drawn.layout.width)pt wide at size \(size)"
            )
            XCTAssertEqual(
                drawn.layout.height, size,
                accuracy: 0.001,
                "the mark grew past the height it was asked for"
            )
        }
    }
}
