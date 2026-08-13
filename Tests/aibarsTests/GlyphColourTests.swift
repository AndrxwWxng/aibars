import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// The usage ramp, checked against the ground it is drawn on.
///
/// This matters more than a palette test usually would, because every stop here
/// is also the colour of a percentage: the ramp is not decoration on a bar, it
/// is body text. So each stop has to clear 4.5:1 — which is the whole reason
/// each stop is a light/dark pair rather than one fixed value.
///
/// **Where that is measured moved with the palette rebuild**, and the change is
/// the point rather than a detail. It used to be `Tokens.Surface.base`, with a
/// hovered `.always` card named as "the worst ground any ink in the panel lands
/// on". `Fill.pressed` (0.12) is a step above `Fill.cardHover` (0.09) and
/// `rowBackground` returns it for the whole row card, so the hovered card was
/// never the worst ground; and neither is measured over the desktop, which the
/// scrim only ever partly covers. The floor is now held on the **pressed row
/// card over the wallpaper that pushes hardest**, modelling `.regularMaterial`
/// as fully transparent — `#D0D1D3` light and `#36373A` dark. `Surface.base`
/// stays the ground the recorded table below is quoted on, because it is the
/// one plane that is the same in every drawing; the floor lives in
/// `testNoInkFallsBelowFourFiveOnThePressedCard`.
final class UsageRampContrastTests: XCTestCase {
    /// The three stops, sampled inside their own bands rather than at the
    /// boundaries, so a boundary moving cannot quietly change which colour is
    /// under test.
    ///
    /// Caution was sampled at 0.70 while the band starts at 0.80, which meant
    /// this array named amber and handed the resting grey to every case that
    /// read it — the ramp's middle stop was untested from the reskin that moved
    /// the boundary until the palette rebuild that re-recorded these figures.
    /// 0.85 is inside caution by 0.05 at each end.
    private let stops: [(name: String, percent: Double)] = [
        ("grey", 0.10),
        ("amber", 0.85),
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
            // Measured against Surface.base in each appearance. All three pairs
            // moved with the palette rebuild, and none of them moved because a
            // stop was re-cut for contrast: the ramp stopped holding colours of
            // its own. Every stop is now a `Tokens.Ink` token, so what these
            // figures record is the palette's, read back through `UsageTint`.
            //
            //   resting  #5F636B / #8A8F98  ->  Ink.muted      #53565E / #A0A5AE
            //   caution  #8A5A00 / #D08214  ->  Ink.attention  #764C00 / #E08D1C
            //   warning  #B92126 / #FF6B6E  ->  Ink.alarm      #7E1217 / #FFA5A7
            //
            // The grounds moved as well — `Surface.base` went #F7F8FA ->
            // #F6F7FA light and #101114 -> #0C0D11 dark — but they are the
            // small half of every delta below: holding the old stops and
            // swapping only the ground moves the dark column by about +0.2 and
            // the light column by about -0.04. The stops did the rest.
            //
            // Re-recorded rather than corrected: grey 5.67 -> 6.85 light and
            // 5.81 -> 7.85 dark, amber 5.58 -> 6.99 and 6.19 -> 7.39, red
            // 5.97 -> 9.87 and 6.81 -> 10.35. The red pair moves furthest
            // because #7E1217 is deliberately much darker than the #B92126 it
            // replaces — red now has to sit a greyscale step away from amber,
            // which `testAmberAndRedSeparateInGreyscale` is the assertion for,
            // and the contrast is what that buys rather than what it was cut
            // for.
            ("grey", 0.10, 6.85, 7.85),
            ("amber", 0.85, 6.99, 7.39),
            ("red", 0.95, 9.87, 10.35)
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

    // MARK: - The floor, on the ground it is actually measured on

    /// Every ink in the palette, on the worst plane it can land on, in both
    /// appearances. Nothing that carries text is under 4.5:1.
    ///
    /// The five inks and not only the ramp's three, because they share one
    /// ground and the ramp is where two of them are also read as figures: a
    /// change to `Surface.base`, to `Fill.pressed` or to the scrim moves all ten
    /// of these numbers at once, and the ramp's own recorded table above cannot
    /// see it.
    ///
    /// Light on `#D0D1D3` / dark on `#36373A`:
    ///
    ///     body       10.66 / 10.72        attention   4.90 / 4.53
    ///     mark        7.42 /  7.32        alarm       6.92 / 6.34
    ///     muted       4.80 /  4.81
    ///
    /// The measured minimum is **4.53**, dark `attention`, which is 0.03 over
    /// the floor and is therefore the binding constraint in the whole palette:
    /// it is the first thing to re-measure if any of the three inputs to the
    /// plane moves, and the reason the amber's dark half cannot be quietened
    /// further. Both figures under 4.5 before the rebuild were on this plane and
    /// unmeasured — light `attention` at 4.44 and the ramp's own resting grey at
    /// 4.48 dark — because the file measured on a hovered card instead.
    func testNoInkFallsBelowFourFiveOnThePressedCard() throws {
        let inks: [(name: String, colour: Color)] = [
            ("body", Tokens.Ink.body),
            ("mark", Tokens.Ink.mark),
            ("muted", Tokens.Ink.muted),
            ("attention", Tokens.Ink.attention),
            ("alarm", Tokens.Ink.alarm)
        ]
        var lowest = (name: "", appearance: "", ratio: Double.greatestFiniteMagnitude)
        for dark in [false, true] {
            let appearance = dark ? "dark" : "light"
            let plane = try XCTUnwrap(worstPressedPlane(dark: dark))
            // The plane has to be the one the palette says it is, or the ten
            // ratios under it are ten measurements of somewhere else.
            XCTAssertEqual(
                hex(plane), dark ? 0x36373A : 0xD0D1D3,
                String(format: "the worst %@ plane composited to #%06X", appearance, hex(plane))
            )
            for ink in inks {
                let resolved = try XCTUnwrap(resolve(ink.colour, dark: dark))
                let ratio = contrast(resolved, on: plane)
                XCTAssertGreaterThanOrEqual(
                    ratio, 4.5,
                    "\(ink.name) measures \(ratio):1 on the \(appearance) pressed card"
                )
                guard ratio < lowest.ratio else { continue }
                lowest = (ink.name, appearance, ratio)
            }
        }
        XCTAssertEqual(lowest.name, "attention", "the binding ink is now \(lowest.name)")
        XCTAssertEqual(lowest.appearance, "dark")
        XCTAssertEqual(
            lowest.ratio, 4.53, accuracy: 0.01,
            "the palette's thinnest margin is \(lowest.ratio):1, recorded as 4.53"
        )
    }

    /// Amber and red are still two marks with the hue taken off.
    ///
    /// They are the entire colour vocabulary of the application, so which alarm
    /// it is has to survive a greyscale screenshot and a deuteranope, and that
    /// is a lightness gap rather than a contrast one — both stops clear 4.5:1
    /// against the ground and are still indistinguishable from each other if
    /// they sit at the same L\*. The pair this replaces failed exactly there:
    /// `Ink.attention` light L\* 42.33 against the ramp's red at 40.51 is
    /// **1.8 apart**, and 61.16 against 64.08 in dark is 2.9.
    ///
    /// Measured now: light 36.02 amber against 26.53 red, **9.49 apart**; dark
    /// 65.73 against 76.65, **10.92**. The floor is 9, which is under both and
    /// far over what the retired pair could reach.
    ///
    /// The direction is asserted as well as the distance, because it is what
    /// makes red readable as *worse* than amber without naming a hue: red is
    /// always the stop further from the ground. It is forced as much as chosen —
    /// the pressed card bounds a light figure at L\* ≤ 38.32 and a dark one at
    /// L\* ≥ 65.51, amber sits on the bound in both, and red takes the only room
    /// left.
    func testAmberAndRedSeparateInGreyscale() throws {
        for dark in [false, true] {
            let amber = lightness(try XCTUnwrap(resolve(Tokens.Ink.attention, dark: dark)))
            let red = lightness(try XCTUnwrap(resolve(Tokens.Ink.alarm, dark: dark)))
            let ground = lightness(try XCTUnwrap(resolve(Tokens.Surface.base, dark: dark)))
            XCTAssertGreaterThanOrEqual(
                abs(amber - red), 9,
                "amber L* \(amber) and red L* \(red) are \(abs(amber - red)) apart in "
                + "\(dark ? "dark" : "light") — one alarm in a greyscale screenshot"
            )
            XCTAssertGreaterThan(
                abs(red - ground), abs(amber - ground),
                "red is nearer the \(dark ? "dark" : "light") ground than amber, "
                + "so it reads as the quieter of the two"
            )
        }
    }

    /// The lit and unlit halves of the connection dot are two inks, and they are
    /// far enough apart to be two states.
    ///
    /// `Ink.ok` is deleted — green is not in the vocabulary — so the 6pt dot in
    /// a row's figure rail is `Ink.body` when the service is reporting and
    /// `Ink.muted` when it is not. That is the whole of the signal now, so the
    /// separation between the two is worth a number: **2.22:1 light and 2.23:1
    /// dark**, measured against each other rather than against a ground. It is a
    /// wider gap than the hue it replaces ever gave a colour-blind reader, which
    /// is the argument for the deletion and is exactly the claim that would rot
    /// silently if `body` or `muted` were ever nudged towards each other.
    func testTheLitAndUnlitStatusDotsSeparate() throws {
        for dark in [false, true] {
            let lit = try XCTUnwrap(resolve(Tokens.Ink.body, dark: dark))
            let unlit = try XCTUnwrap(resolve(Tokens.Ink.muted, dark: dark))
            let separation = contrast(lit, on: unlit)
            XCTAssertGreaterThanOrEqual(
                separation, 2.2,
                "the \(dark ? "dark" : "light") dot's two states are \(separation):1 apart"
            )
            XCTAssertEqual(separation, dark ? 2.23 : 2.22, accuracy: 0.01)
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
        return hex(srgb)
    }

    private func hex(_ srgb: NSColor) -> UInt32 {
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
        return contrast(ink, on: ground)
    }

    /// The same ratio between two colours that are already resolved — the worst
    /// plane is composited rather than declared, so there is no `Color` left to
    /// resolve by the time it is measured against.
    private func contrast(_ ink: NSColor, on ground: NSColor) -> Double {
        let a = luminance(ink), b = luminance(ground)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    /// CIE L\*, which is the greyscale axis: the number that says whether two
    /// colours are still two colours once the hue is taken off. Same relative
    /// luminance as the contrast ratio uses, so the two measurements cannot
    /// disagree about what a colour is.
    private func lightness(_ colour: NSColor) -> Double {
        let y = luminance(colour)
        return y > 216.0 / 24389.0 ? 116 * pow(y, 1.0 / 3.0) - 16 : y * 24389.0 / 27.0
    }

    /// The worst plane an ink in the panel can land on, built rather than
    /// written down: `Surface.base` under the wallpaper that pushes hardest,
    /// with the pressed row card over that.
    ///
    /// Three facts put the floor here. The panel's ground is `Surface.base` at
    /// `Tokens.scrimAlpha` over `.regularMaterial`, so the desktop is never
    /// fully covered — modelled here as fully transparent, which is the strict
    /// upper bound on what it can contribute and so pessimistic on purpose,
    /// since a real material adds its own tint and pulls the ground back towards
    /// `base`. The hardest wallpaper is the one that pushes the ground *towards*
    /// the ink: pure black in light, pure white in dark. And `rowBackground`
    /// returns `Fill.pressed` for the whole row card under all three background
    /// settings, with `RowButtonStyle` drawing the row's entire contents, text
    /// included, on top of it.
    ///
    /// Composited per the palette's own arithmetic, `round(bg + (fg − bg)·α)`
    /// per 8-bit channel at each step: light `246·0.96 → #ECEDF0`, then
    /// `236·0.88 → #D0D1D3`; dark `12 + 243·0.06 → #1B1C1F`, then
    /// `27 + 228·0.12 → #36373A`. Derived rather than hardcoded so that a change
    /// to the scrim, to `Fill.pressed` or to `Surface.base` moves the
    /// measurement instead of dating a comment — the two hexes are asserted at
    /// the top of the case that uses them.
    private func worstPressedPlane(dark: Bool) -> NSColor? {
        guard let base = resolve(Tokens.Surface.base, dark: dark) else { return nil }
        let extreme: CGFloat = dark ? 1 : 0
        let wallpaper = NSColor(srgbRed: extreme, green: extreme, blue: extreme, alpha: 1)
        let scrim = Tokens.scrimAlpha(isDark: dark, reduceTransparency: false)
        let ground = composite(wallpaper, at: 1 - scrim, over: base)
        return composite(wallpaper, at: Tokens.Fill.pressed, over: ground)
    }

    private func composite(_ ink: NSColor, at alpha: Double, over ground: NSColor) -> NSColor {
        func channel(_ component: (NSColor) -> CGFloat) -> CGFloat {
            let background = (component(ground) * 255).rounded()
            let foreground = (component(ink) * 255).rounded()
            return (background + (foreground - background) * CGFloat(alpha)).rounded() / 255
        }
        return NSColor(
            srgbRed: channel { $0.redComponent },
            green: channel { $0.greenComponent },
            blue: channel { $0.blueComponent },
            alpha: 1
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

/// The app mark's grid: every measurement it resolves before anything is drawn.
///
/// Split from the rendered tests below because it needs nothing — no renderer,
/// no display scale, no menu bar — and because the whole of the mark's crispness
/// is in these numbers. What used to stand here was a single rendered check that
/// the laid-out width came out whole at 13, 14 and 44. It passed throughout the
/// fault it was written to catch: the width *was* whole (18 at every size from 11
/// to 15), and the blur was vertical — an odd 13pt box centred in an even 22pt
/// bar, with 12pt of ink inside it.
///
/// The sizes below are every one the app can ask for. Half steps are included
/// because the strip-height tuner shipped with `step: 0.5` and a defaults domain
/// can still hold what it wrote, so a build that stops quantising must not be
/// able to reach a fractional mark through this type.
final class AppMarkGridTests: XCTestCase {
    private let sizes: [CGFloat] =
        stride(from: 10.0, through: 16.0, by: 0.5).map { CGFloat($0) }
        + [Tokens.Control.headerGlyph, Tokens.Control.iconButton, Tokens.Control.aboutGlyph]

    /// Whole points, all of them.
    ///
    /// The status item resamples a fractional image to fit its slot, and half a
    /// point of resampling is visible blur on a mark that is mostly 3pt stems.
    /// Asserted measurement by measurement rather than on the width alone: the
    /// width was the one number the old construction did round, and rounding one
    /// of nine is how a mark ends up with a whole outline and a fractional
    /// interior.
    func testEveryMeasurementIsAWholePoint() {
        for size in sizes {
            let grid = AppMarkGeometry(size: size)
            let named: [(String, CGFloat)] = [
                ("box", grid.box), ("stem", grid.stem), ("gap", grid.gap),
                ("baseline", grid.baseline), ("baselineGap", grid.baselineGap),
                ("plot", grid.plot), ("step", grid.step), ("corner", grid.corner),
                ("overhang", grid.overhang), ("runWidth", grid.runWidth), ("width", grid.width)
            ]
            for (name, value) in named {
                XCTAssertEqual(value, value.rounded(), "\(name) is \(value) at size \(size)")
            }
            for (index, height) in grid.heights.enumerated() {
                XCTAssertEqual(height, height.rounded(), "bar \(index) is \(height)pt at size \(size)")
            }
        }
    }

    /// And even, which is the half of it a whole-point rule does not cover.
    ///
    /// AppKit centres the status image in a 22pt bar, so an odd box hangs at a
    /// half point however whole its own interior is — (22 − 13) / 2 = 4.5, one
    /// device row split in two at 1× for the baseline and each of the four bar
    /// tops. The second assertion is the one that matters; the first is the rule
    /// that guarantees it.
    func testTheBoxIsEvenAndCentresOnAWholePoint() {
        for size in sizes {
            let box = AppMarkGeometry(size: size).box
            XCTAssertEqual(
                box.truncatingRemainder(dividingBy: 2), 0,
                "size \(size) resolved to an odd \(box)pt box"
            )
            let origin = (MenuBarIcon.barHeight - box) / 2
            XCTAssertEqual(origin, origin.rounded(), "a \(box)pt box hangs at y = \(origin) in the bar")
        }
    }

    /// `size` is the room the caller has, so the box rounds down into it and
    /// never up out of it. The 8pt floor is the one exception and is not reachable
    /// from the app: the smallest size anything asks for is `menuBarGlyphHeight`'s
    /// lower clamp of 10.
    func testTheBoxNeverExceedsTheSizeAskedFor() {
        for size in sizes {
            let box = AppMarkGeometry(size: size).box
            XCTAssertLessThanOrEqual(box, size, "size \(size) grew to a \(box)pt box")
            // And not by more than the parity costs, or "rounds down" would cover
            // a box that had quietly stopped tracking its size at all.
            XCTAssertGreaterThan(box, size - 2, "size \(size) collapsed to a \(box)pt box")
        }
        XCTAssertEqual(AppMarkGeometry(size: 2).box, 8, "the floor is the only case that may exceed the ask")
    }

    /// The ink is the box. The three stacked parts add up to it exactly, and the
    /// tallest bar is the whole plot.
    ///
    /// This is the defect the rendered tests could not see. The old profile topped
    /// out at 0.9 of its plot, so at 13pt the mark drew 10 + 1 + 1 = 12pt of ink,
    /// bottom-aligned, inside a 13pt image: a point of dead air above the bars,
    /// compounding with the half-point origin into ink whose centre sat 5.0pt above
    /// the box floor in a slot whose centre is at 11.0.
    func testInkFillsTheBox() {
        for size in sizes {
            let grid = AppMarkGeometry(size: size)
            XCTAssertEqual(
                grid.plot + grid.baselineGap + grid.baseline, grid.box,
                "the parts sum to \(grid.plot + grid.baselineGap + grid.baseline) in a \(grid.box)pt box"
            )
            XCTAssertEqual(grid.heights[0], grid.plot, "dead air above the bars at size \(size)")
        }
    }

    /// One constant step, so the four tops fall on a single line — which is what
    /// makes four rectangles read as a chart rather than as a comb. The old
    /// profile's steps were 3, 3, 2 at 13pt and 9, 9, 7 at 44: a descent short by
    /// a fifth to a third on its last step at every size.
    func testTheTopsAreCollinear() {
        for size in sizes {
            let grid = AppMarkGeometry(size: size)
            for index in 0..<(AppMarkGeometry.count - 1) {
                XCTAssertEqual(
                    grid.heights[index] - grid.heights[index + 1], grid.step,
                    "bars \(index) and \(index + 1) are \(grid.heights) at size \(size)"
                )
            }
        }
    }

    /// A rectangle shorter than it is wide has stopped being a bar. The floor is
    /// in the construction, but it must not be *firing* at any size the app draws
    /// — a bar clamped up to the stem is a bar off the line the test above pins.
    func testNoBarIsShorterThanItIsWide() {
        for size in sizes {
            let grid = AppMarkGeometry(size: size)
            for (index, height) in grid.heights.enumerated() {
                XCTAssertGreaterThanOrEqual(
                    height, grid.stem,
                    "bar \(index) is \(height) × \(grid.stem) at size \(size)"
                )
            }
        }
    }

    /// The horizontal half of the same claim, at both scales a Mac draws at. A
    /// stem starting on a half pixel is a stem with a grey edge, and at 1× on a
    /// non-Retina external display there is no second sample to hide it in.
    func testStemsLandOnWholePointsAtEveryScale() {
        for size in sizes {
            let grid = AppMarkGeometry(size: size)
            for index in 0..<AppMarkGeometry.count {
                for scale in [1.0, 2.0] as [CGFloat] {
                    let edge = grid.stemOrigin(index) * scale
                    XCTAssertEqual(edge, edge.rounded(), "stem \(index) starts at \(edge)px at \(scale)× and size \(size)")
                    let far = (grid.stemOrigin(index) + grid.stem) * scale
                    XCTAssertEqual(far, far.rounded(), "stem \(index) ends at \(far)px at \(scale)× and size \(size)")
                }
            }
            // The trailing edge of the last stem plus its overhang is the mark's
            // own width, so nothing is left over and the axis is symmetric.
            XCTAssertEqual(
                grid.stemOrigin(AppMarkGeometry.count - 1) + grid.stem + grid.overhang, grid.width,
                "the run does not fill its width at size \(size)"
            )
        }
    }

    /// Half a point cannot produce a different mark, and neither can a point that
    /// shares an even box. This is the assertion that makes the strip's fallback
    /// memo correct to key on the box: 13 and 12 are one mark, so they are one
    /// bitmap.
    func testHalfStepsResolveToTheWholeSizeBelow() {
        XCTAssertEqual(AppMarkGeometry(size: 13), AppMarkGeometry(size: 12))
        XCTAssertEqual(AppMarkGeometry(size: 13.5), AppMarkGeometry(size: 12))
        XCTAssertEqual(AppMarkGeometry(size: 15.5), AppMarkGeometry(size: 14))
        // And the pairs that must stay apart, or "one mark, one bitmap" would be
        // "every mark, one bitmap".
        XCTAssertNotEqual(AppMarkGeometry(size: 13), AppMarkGeometry(size: 14))
        XCTAssertNotEqual(AppMarkGeometry(size: 22), AppMarkGeometry(size: 44))
    }

    /// Corners and the axis overhang are gated on their own resolved measurement
    /// rather than on a size test, and at every size but About the measurement
    /// comes out under 2pt and they do not appear. A 1pt radius on a 3pt stem is
    /// not a corner, it is a half-lit pixel on each shoulder; 1pt of overhang at
    /// each end is a stray pixel rather than an axis running past its data.
    func testCornersAndOverhangAreLargeSizeOnly() {
        for size in sizes where AppMarkGeometry(size: size).box <= 22 {
            let grid = AppMarkGeometry(size: size)
            XCTAssertEqual(grid.corner, 0, "a \(grid.box)pt box drew a \(grid.corner)pt corner")
            XCTAssertEqual(grid.overhang, 0, "a \(grid.box)pt box drew a \(grid.overhang)pt overhang")
            XCTAssertEqual(grid.width, grid.runWidth, "the axis is not flush with the run at size \(size)")
        }

        let about = AppMarkGeometry(size: Tokens.Control.aboutGlyph)
        XCTAssertEqual(about.corner, 2, "About lost its rounded tops")
        XCTAssertEqual(about.overhang, 2, "About lost its axis overhang")
        XCTAssertEqual(about.width, about.runWidth + 4, "the overhang is not at both ends")
    }

    /// The resolved grid, written out. Not derivable from the rules above — it is
    /// the shape itself, and the four sizes that reach a screen: the strip, the
    /// panel header, the icon-button square, and About.
    ///
    /// The menu bar mark and the header mark share stem 3, gap 1, pitch 4 and
    /// width 15 and differ only in bar heights, which is deliberate: the panel
    /// hangs directly under the status item, so the two are on screen together and
    /// have to read as one mark at two sizes.
    func testTheResolvedGridIsTheShapeItIsMeantToBe() {
        let expected: [CGFloat: (box: CGFloat, stem: CGFloat, gap: CGFloat, width: CGFloat, heights: [CGFloat])] = [
            13: (12, 3, 1, 15, [10, 8, 6, 4]),
            14: (14, 3, 1, 15, [12, 9, 6, 3]),
            22: (22, 5, 2, 26, [18, 14, 10, 6]),
            44: (44, 10, 4, 56, [37, 28, 19, 10])
        ]
        for (size, shape) in expected {
            let grid = AppMarkGeometry(size: size)
            XCTAssertEqual(grid.box, shape.box, "box at \(size)")
            XCTAssertEqual(grid.stem, shape.stem, "stem at \(size)")
            XCTAssertEqual(grid.gap, shape.gap, "gap at \(size)")
            XCTAssertEqual(grid.width, shape.width, "width at \(size)")
            XCTAssertEqual(grid.heights, shape.heights, "bars at \(size)")
            // Written twice on purpose, as the sum as well as the literal: 4 stems
            // and 3 gaps plus an overhang at each end.
            XCTAssertEqual(grid.width, 4 * shape.stem + 3 * shape.gap + 2 * grid.overhang, "width arithmetic at \(size)")
        }
    }

    /// The axis carries less alpha when it is thick enough to hold it. A 1pt rule
    /// is one device pixel at 1×, and one pixel at 55% of a template's alpha is a
    /// line the menu bar's own vibrancy finishes off; a 3pt rule at 70% is a slab
    /// competing with the bars it sits under.
    func testTheAxisTakesItsAlphaFromItsThickness() {
        XCTAssertEqual(AppMarkGeometry(size: 13).baseline, 1)
        XCTAssertEqual(AppMarkGeometry(size: 13).baselineOpacity, 0.70)
        XCTAssertEqual(AppMarkGeometry(size: 44).baseline, 3)
        XCTAssertEqual(AppMarkGeometry(size: 44).baselineOpacity, 0.55)
    }

    /// The size arrives from a defaults domain that can hold anything, and every
    /// `max` in the construction passes infinity straight through to a frame and
    /// an `NSImage`. Both non-finite cases have to land on the floor rather than
    /// on a trap or an unbounded canvas.
    func testANonFiniteSizeFallsToTheFloor() {
        for size in [CGFloat.nan, .infinity, -.infinity, -12] {
            let grid = AppMarkGeometry(size: size)
            XCTAssertEqual(grid.box, 8, "size \(size) produced a \(grid.box)pt box")
            XCTAssertTrue(grid.width.isFinite, "size \(size) produced a \(grid.width)pt canvas")
        }
    }
}

/// The app mark as it is actually drawn, which is the half of it arithmetic
/// cannot answer for: that the grid above reaches SwiftUI intact, and that ink
/// comes out of it at menu bar size, where the stems are 3pt wide.
final class AppMarkTests: XCTestCase {
    /// The height the strip ships at. A literal rather than a setting: this is
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

    /// The seam: what SwiftUI lays the mark out at has to be what
    /// `AppMarkGeometry` said it would be, at every size that reaches a screen.
    ///
    /// This is what makes the grid worth asserting at all. `MenuBarStripRenderer`
    /// sizes its bitmap from the grid without rendering anything first, so a view
    /// that measured one point wider than the grid claims would be a mark clipped
    /// by its own canvas — and the same disagreement in the other direction is a
    /// mark floating in dead pixels. Asserted against the reported size and not
    /// against a rounding of it: `drawn` is the contract.
    @MainActor
    func testTheDrawnSizeIsWhatTheViewReports() throws {
        for size in [menuBarHeight, Tokens.Control.headerGlyph, Tokens.Control.aboutGlyph] {
            let drawn = try XCTUnwrap(render(size: size))
            XCTAssertEqual(
                drawn.layout, AppMarkGeometry(size: size).drawn,
                "a \(size)pt mark laid itself out at \(drawn.layout)"
            )
        }
        // The three, written out, because they are the visual delta this change
        // ships: the header mark narrows 18 → 15, the strip's fallback goes from an
        // 18 × 13 image holding 12pt of ink to a 15 × 12 image that is all ink, and
        // About gains 3pt of ink height inside a 2pt narrower box.
        XCTAssertEqual(AppMarkGeometry(size: menuBarHeight).drawn, CGSize(width: 15, height: 12))
        XCTAssertEqual(AppMarkGeometry(size: Tokens.Control.headerGlyph).drawn, CGSize(width: 15, height: 14))
        XCTAssertEqual(AppMarkGeometry(size: Tokens.Control.aboutGlyph).drawn, CGSize(width: 56, height: 44))
    }
}
