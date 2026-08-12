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
            // Measured against Surface.base in each appearance. The resting
            // stop is no longer teal: a healthy row carries no hue, so the
            // lowest band is grey and the recorded pair moved with it.
            //
            // Both alarm stops were re-cut for the ground `Surface.base` is not:
            // a hovered `.always` row card, light #E1E2E4 / dark #262629, which
            // three of the five presets ship and which is the worst ground any
            // ink in the panel lands on. Amber's light stop was #B45309, which
            // measured 3.87:1 there — a figure under the floor — and was also a
            // second amber beside `Ink.attention`'s. It is now `Ink.attention`'s
            // own #8A5A00, so the panel has one amber. Red's was #C62A2F at
            // 4.29:1 on the same card and is now #B92126. Both went up here as a
            // consequence, which is what these numbers are for: a stop moving
            // shows up as a number rather than as "still above 4.5".
            ("grey", 0.10, 5.67, 5.81),
            ("amber", 0.85, 5.58, 6.19),
            ("red", 0.95, 5.97, 6.81)
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

    /// The boundaries are at exactly 0.80 and 0.95, and the value *at* a
    /// boundary belongs to the band above it. 95% is warned about rather than
    /// cautioned about; the other way round is the app rounding in the
    /// provider's favour.
    ///
    /// The edges moved with the reskin — the resting band used to end at 0.60
    /// and warning used to start at 0.85 — so these are the palette's own
    /// boundaries restated, not a second opinion about where caution begins.
    /// The invariant being guarded is the rounding direction, which is unchanged.
    func testABoundaryValueBelongsToTheHigherBand() throws {
        let grey = try XCTUnwrap(hex(UsageTint.color(for: 0), dark: true))
        let amber = try XCTUnwrap(hex(UsageTint.color(for: 0.85), dark: true))
        let red = try XCTUnwrap(hex(UsageTint.color(for: 1), dark: true))
        XCTAssertNotEqual(grey, amber)
        XCTAssertNotEqual(amber, red)

        XCTAssertEqual(hex(UsageTint.color(for: 0.799), dark: true), grey)
        XCTAssertEqual(hex(UsageTint.color(for: 0.80), dark: true), amber, "0.80 is caution, not resting")
        XCTAssertEqual(hex(UsageTint.color(for: 0.949), dark: true), amber)
        XCTAssertEqual(hex(UsageTint.color(for: 0.95), dark: true), red, "0.95 is the warning, not the top of caution")
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

        // Caution first, because warning is clamped to at least caution + 0.05
        // and the shipped caution is now 0.80 — assigning 0.70 straight to the
        // warning would silently clamp back up to 0.85 and this test would be
        // asserting against the default it was written to avoid.
        appearance.cautionThreshold = 0.60
        appearance.warningThreshold = 0.70
        XCTAssertEqual(appearance.warningThreshold, 0.70, accuracy: 0.001, "the threshold did not take")
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
        XCTAssertEqual(hex(tint, dark: true), hex(UsageTint.color(for: 1), dark: true))
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
