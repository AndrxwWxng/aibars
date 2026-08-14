import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// The palette's arithmetic, and the claims about it that are worth more than a
/// screenshot: that a reserved figure column is wide enough for the figure, that
/// a colour pair meant to be a visible step actually is one in *both*
/// appearances, and that the three grounds stay a ladder rather than three
/// hexes that merely differ.
///
/// It also holds the two guards that stop the design system drifting back: the
/// type ramp is pinned to macOS's own three control sizes, and no source file
/// may call `.monospaced()`. Both are cheap, and both catch the kind of change
/// that arrives as a tidy-up rather than as a decision.
final class TokensTests: XCTestCase {

    // MARK: - Resolving a dynamic colour

    /// A dynamic colour has no value until something draws it, so the test has
    /// to stand in for the drawing. `performAsCurrentDrawingAppearance` is the
    /// supported way to do that — setting `NSAppearance.current` is deprecated.
    private func resolve(_ color: Color, dark: Bool) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return try XCTUnwrap(resolved, "colour would not resolve in sRGB")
    }

    /// WCAG contrast ratio, the same formula the spec's measurements are quoted
    /// in, so a failure here is directly comparable with them.
    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let la = Tokens.relativeLuminance(a)
        let lb = Tokens.relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    /// A neutral grey with a chosen relative luminance — the inverse of the sRGB
    /// transfer function, so the boundary in `onAccent` can be approached from
    /// both sides rather than guessed at.
    private func grey(luminance: Double) -> Color {
        let v = 1.055 * pow(luminance, 1 / 2.4) - 0.055
        return Color(nsColor: NSColor(srgbRed: v, green: v, blue: v, alpha: 1))
    }

    // MARK: - The type ramp

    /// 13/11/10 is macOS's own control ramp, and that is the whole argument for
    /// it: a settings window set in house sizes disagrees with every native form
    /// it sits beside by a point or two, which reads as a rendering fault rather
    /// than as a choice.
    func testRampIsTheThreePlatformControlSizes() {
        XCTAssertEqual(Tokens.Ramp.title, 13)
        XCTAssertEqual(Tokens.Ramp.detail, 11)
        XCTAssertEqual(Tokens.Ramp.caption, 10)
    }

    /// Three sizes, strictly descending, and none of them the two that were
    /// retired.
    ///
    /// The ramp was five sizes (13/12/11/10/9) and the collapse to three is the
    /// point of the migration: `body` 12 went up to `title`, `section` 9 went up
    /// to `caption`. A call site reaching for either name no longer compiles, so
    /// the way a fourth size comes back is not a new name but an old *value*
    /// creeping into one of these three — `detail` sliding to 12 because a label
    /// looked cramped. That is what the last loop is for.
    func testRampHasThreeDistinctSizesAndNoneOfTheRetiredOnes() {
        let sizes: [CGFloat] = [Tokens.Ramp.title, Tokens.Ramp.detail, Tokens.Ramp.caption]
        XCTAssertGreaterThan(Tokens.Ramp.title, Tokens.Ramp.detail)
        XCTAssertGreaterThan(Tokens.Ramp.detail, Tokens.Ramp.caption)
        XCTAssertEqual(Set(sizes).count, 3, "two of the three ramp sizes collapsed onto one value")
        for retired in [CGFloat(12), 9] {
            XCTAssertFalse(
                sizes.contains(retired),
                "\(retired)pt is back in the ramp; it was retired into the size above it"
            )
        }
    }

    // MARK: - figureWidth

    /// The column is the face's own advance, and the claim is that it is
    /// *measured* rather than a ratio — so it is asserted against the face rather
    /// than against a number, which is the only form of this test that a change
    /// of face moves with instead of being caught by.
    func testFigureWidthIsTheMeasuredColumn() {
        // 15pt, cozy's figure size, at three digits and the weight a figure past
        // its warning line is set in.
        let three = Tokens.figureWidth(15, digits: 3)
        XCTAssertEqual(three, Self.measured("888", size: 15, weight: .semibold).rounded(.up), accuracy: 0.001)
        // Whole points, so a column can never be a fraction narrower than the
        // glyphs in it.
        XCTAssertEqual(three, three.rounded())

        // And the unit cell is its own cell, not a fourth digit: SF Pro's `%` is
        // about 1.47 times a digit, which is the whole reason `unitWidth` exists.
        // Under SF Mono the two were the same number and the distinction could
        // not have been tested at all.
        XCTAssertEqual(
            Tokens.unitWidth(15),
            Self.measured("%", size: 15, weight: .semibold).rounded(.up),
            accuracy: 0.001
        )
        XCTAssertGreaterThan(Tokens.unitWidth(15), Tokens.figureWidth(15, digits: 1))
    }

    /// A heavier run wants a wider cell, which a mono face never had to say.
    func testAHeavierFigureReservesAWiderCell() {
        for size in stride(from: CGFloat(9), through: 20, by: 1) {
            XCTAssertGreaterThanOrEqual(
                Tokens.figureWidth(size, digits: 9, weight: .semibold),
                Tokens.figureWidth(size, digits: 9, weight: .regular),
                "\(size)pt reserved no more for semibold digits than for regular ones"
            )
        }
    }

    /// The measurement the tokens claim to be, done here independently: the
    /// system face at the given weight with its numbers made tabular.
    private static func measured(_ run: String, size: CGFloat, weight: NSFont.Weight) -> CGFloat {
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        let descriptor = system.fontDescriptor.addingAttributes([
            .featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector
            ]]
        ])
        let font = NSFont(descriptor: descriptor, size: size) ?? system
        return (run as NSString).size(withAttributes: [.font: font]).width
    }

    func testFigureWidthGrowsWithSizeAndWithDigits() {
        for digits in 1...6 {
            for size in stride(from: CGFloat(9), through: 24, by: 1) {
                XCTAssertGreaterThanOrEqual(
                    Tokens.figureWidth(size + 1, digits: digits),
                    Tokens.figureWidth(size, digits: digits),
                    "a larger size gave a narrower column at \(digits) digits"
                )
                XCTAssertGreaterThan(
                    Tokens.figureWidth(size, digits: digits + 1),
                    Tokens.figureWidth(size, digits: digits),
                    "an extra digit did not widen the column at \(size)pt"
                )
            }
        }
    }

    // MARK: - The rails derived from it

    /// Money's rail, stated against `figureWidth` rather than as the 65 it
    /// currently measures — the test should move when the token does, and pinning
    /// the number here would mean a change to the advance ratio failed in two
    /// places while being wrong in neither.
    ///
    /// Eight cells is `$1234.56`: the sign, four digits, the point and two
    /// decimals. Money is the one rail allowed decimals at all, which is why it
    /// needs a rail of its own rather than a digit count at each call site.
    func testMoneyRailIsEightMonospacedCellsAtTheRampSizeItIsSetIn() {
        XCTAssertEqual(
            Tokens.moneyWidth(Tokens.Ramp.title),
            Tokens.figureWidth(Tokens.Ramp.title, digits: 8)
        )
    }

    /// The strip's reserved cell is the same column every other figure in the app
    /// is set in — asserted at the two ends of the range
    /// `AppearanceSettings.menuBarGlyphHeight` clamps to, because the bounds are
    /// where a derivation that has quietly stopped being one shows up first.
    ///
    /// Stated through the strip's own two parts rather than through `height - 1`
    /// and a 3: the claim is that the cell is *derived* from `figureWidth`, and a
    /// test that restates the derivation's constants has only copied it.
    func testTheMenuBarFigureCellIsTheSameColumnAsEveryOtherFigure() {
        for height in [CGFloat(10), 16] {
            XCTAssertEqual(
                Tokens.Strip.figureCell(height: height),
                Tokens.figureWidth(
                    Tokens.Strip.figureSize(height: height),
                    digits: Tokens.Strip.figureDigits
                ),
                "the strip's cell left Tokens' column at \(height)pt"
            )
        }
    }

    /// `StripFit` keeps its own cell so the fitting arithmetic can be pure, and
    /// the renderer draws from `Tokens.Strip`. Two copies of one width is exactly
    /// the contract that stops being true quietly — the strip shoving its
    /// neighbours sideways is the bug — so they are held equal here.
    ///
    /// Over the whole clamped range rather than the bounds, because these two are
    /// a duplication rather than a derivation and a duplication can disagree
    /// anywhere in the middle.
    func testTheFittersCellAndTheTokenAgree() {
        for height in stride(from: CGFloat(10), through: 16, by: 1) {
            XCTAssertEqual(
                StripFit.figureCell(height: height),
                Tokens.Strip.figureCell(height: height),
                "the fitter and the token reserve different cells at \(height)pt"
            )
        }
    }

    // MARK: - The scrim

    func testScrimIsOpaqueUnderReduceTransparency() {
        // Both appearances, because the caller also drops the material in this
        // branch: a translucent scrim over no material is just a pale fill, and
        // the setting exists to stop the desktop showing through at all.
        XCTAssertEqual(Tokens.scrimAlpha(isDark: true, reduceTransparency: true), 1)
        XCTAssertEqual(Tokens.scrimAlpha(isDark: false, reduceTransparency: true), 1)
    }

    /// The two literals, and they are derived rather than chosen.
    ///
    /// They were 0.88 dark / 0.92 light, and both moved because `Meter.track` is
    /// an absolute pair drawn *inside* a panel whose ground is `Surface.base` at
    /// this alpha over the user's desktop. Modelling the material as fully
    /// transparent — the strict upper bound on what the wallpaper contributes —
    /// a white desktop composited the dark ground to within 1.0715:1 of the
    /// track at the retired 0.88 and to 1.0005:1 at 0.86, which is the two of
    /// them being one colour: the empty half of every bar and dial stops being a
    /// container and becomes a hole. At **0.94** the dark ground is
    /// `12 + 243·0.06 = 26.6 → #1B1C1F` (L\* 10.28) against the track's L\* 19.42,
    /// **1.2735:1 with the track still above it**; at **0.96** the light ground
    /// is `246·0.96 → #ECEDF0` (L\* 93.75) against the track's L\* 85.25,
    /// **1.2545:1 with the track still below it**.
    ///
    /// `PanelShellTests.testTheTrackNeverInvertsAgainstTheGround` measures those
    /// two ratios off the same arithmetic, so these literals and that
    /// measurement move together or one of them fails.
    func testScrimIsHeavierOnLightThanOnDark() {
        let dark = Tokens.scrimAlpha(isDark: true, reduceTransparency: false)
        let light = Tokens.scrimAlpha(isDark: false, reduceTransparency: false)
        XCTAssertEqual(dark, 0.94, accuracy: 0.0001)
        XCTAssertEqual(light, 0.96, accuracy: 0.0001)
        // The light base sits nearer a bright wallpaper, so it needs more cover
        // to keep the same distance from the card planes above it.
        XCTAssertGreaterThan(light, dark)
    }

    // MARK: - Ink on an accent fill

    func testOnAccentDarkensTheTextRatherThanTheFill() {
        // A pale accent — the case white text disappears into.
        XCTAssertEqual(Tokens.Ink.onAccent(Color(hex: 0xF2E48A)), Color(hex: 0x101010))
        // A saturated one, which is what most users leave it at.
        XCTAssertEqual(Tokens.Ink.onAccent(Color(hex: 0x0A5FD6)), Color.white)
        XCTAssertEqual(Tokens.Ink.onAccent(.black), Color.white)
    }

    func testOnAccentSwitchesAtTheStatedBoundary() throws {
        // The helper has to actually land where it claims, or the two assertions
        // under it are testing nothing in particular.
        let atBoundary = try resolve(grey(luminance: 0.45), dark: false)
        XCTAssertEqual(Tokens.relativeLuminance(atBoundary), 0.45, accuracy: 0.0005)

        // Strictly above takes the dark ink; the boundary itself belongs to
        // white, which is the safer side for a fill we are only just calling
        // pale.
        XCTAssertEqual(Tokens.Ink.onAccent(grey(luminance: 0.4501)), Color(hex: 0x101010))
        XCTAssertEqual(Tokens.Ink.onAccent(grey(luminance: 0.4499)), Color.white)
    }

    // MARK: - Relative luminance

    func testRelativeLuminanceOfBlackAndWhite() {
        XCTAssertEqual(Tokens.relativeLuminance(NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)), 1, accuracy: 0.0001)
        XCTAssertEqual(Tokens.relativeLuminance(NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)), 0, accuracy: 0.0001)
    }

    func testRelativeLuminanceConvertsFromAnotherColourSpace() {
        // The coefficients are only true in sRGB, and a colour can arrive from
        // the picker in any space. Converted, a P3 white is still white.
        let p3White = NSColor(displayP3Red: 1, green: 1, blue: 1, alpha: 1)
        XCTAssertEqual(Tokens.relativeLuminance(p3White), 1, accuracy: 0.01)
    }

    // MARK: - Surfaces

    func testSurfaceBaseDiffersByAppearance() throws {
        let light = try resolve(Tokens.Surface.base, dark: false)
        let dark = try resolve(Tokens.Surface.base, dark: true)
        XCTAssertNotEqual(light, dark)
        XCTAssertGreaterThan(Tokens.relativeLuminance(light), Tokens.relativeLuminance(dark))
    }

    /// Three grounds, one ladder, same direction in both appearances: the well is
    /// sunk below the base and the raised surface stands above it.
    ///
    /// Distinct hexes are not the claim worth testing — three values that differ
    /// in the third decimal of their luminance are a ladder on paper and one
    /// plane on a display. So each step is also held to a measurable separation.
    /// The shipped steps measure **1.1041** well→base and **1.0712** base→raised
    /// in light, **1.0556** and **1.1632** in dark; the floor is set at 1.05,
    /// which is loose enough to let a step be retuned and tight enough to catch
    /// one being lost. Measured off the retired hexes (`#EDEEF1`/`#F7F8FA` light,
    /// `#08090A`/`#101114`/`#1A1B1F` dark) the same four steps were 1.0918 /
    /// 1.0626 and 1.0555 / 1.0972, so the rebuild widened three of them and left
    /// dark's well where it was.
    ///
    /// Dark's well is now the binding case at 1.0556, 0.0056 above the floor,
    /// and it cannot be given much more room: the *entire* headroom beneath
    /// `Surface.base` `#0C0D11` is `ratio(base, #000000)` = 1.0813:1, so a well
    /// that is not pure black has 0.08 of a ratio to live in and `#030407`
    /// spends two thirds of it. That is also why the two appearances put their
    /// larger step at opposite ends — light has room below its base and almost
    /// none above `#FFFFFF`, dark has room above and almost none below.
    ///
    /// What does *not* flip is the direction: a well is a hole and a raised
    /// surface catches light in both appearances, so the order is
    /// `well < base < raised` in luminance in dark exactly as in light. A dark
    /// ladder that inverted would put the sunk plane above the ground it is cut
    /// into, which is why this is asserted in a loop over both rather than
    /// per-appearance.
    ///
    /// Elevation has exactly three planes. A fourth ground is the change this
    /// test cannot see, and is a review question rather than an assertion.
    func testTheThreeGroundsAreALadderInBothAppearances() throws {
        for dark in [true, false] {
            let name = dark ? "dark" : "light"
            let well = try resolve(Tokens.Surface.well, dark: dark)
            let base = try resolve(Tokens.Surface.base, dark: dark)
            let raised = try resolve(Tokens.Surface.raised, dark: dark)

            XCTAssertLessThan(
                Tokens.relativeLuminance(well), Tokens.relativeLuminance(base),
                "the well is not sunk below the ground it is cut into in \(name)"
            )
            XCTAssertLessThan(
                Tokens.relativeLuminance(base), Tokens.relativeLuminance(raised),
                "the raised surface does not stand above the base in \(name)"
            )
            XCTAssertGreaterThanOrEqual(
                contrast(well, base), 1.05,
                "base to well is \(contrast(well, base)):1 in \(name), which is one plane"
            )
            XCTAssertGreaterThanOrEqual(
                contrast(base, raised), 1.05,
                "base to raised is \(contrast(base, raised)):1 in \(name), which is one plane"
            )
        }
    }

    func testSurfaceIsCoolRatherThanTinted() throws {
        // Cool by a small blue-over-red offset. Enough to read as deliberate
        // beside a default neutral panel, never enough to read as a colour.
        for dark in [true, false] {
            let base = try resolve(Tokens.Surface.base, dark: dark)
            let offset = base.blueComponent - base.redComponent
            XCTAssertGreaterThan(offset, 0, "the base is not cool in \(dark ? "dark" : "light")")
            XCTAssertLessThan(offset, 0.05, "the base reads as tinted in \(dark ? "dark" : "light")")
        }
    }

    // MARK: - The planes over the ground

    /// `Tokens.quiet(_:)` lays down pure ink at exactly the alpha it is handed.
    ///
    /// This is the premise every plane hex below rests on, and it did not hold
    /// until the palette rebuild. `quiet(_:)` returned `Color.primary.opacity(o)`;
    /// `Color.primary` resolves to `NSColor.labelColor`, which is black or white
    /// at **alpha 0.8471**, and `Color.opacity(_:)` *multiplies*. Every value in
    /// `Fill` was therefore laying down 84.71% of the ink it names — `card` 0.05
    /// composited at 0.0424 — so the whole elevation ladder ran 15% quieter than
    /// every number written against it, including the hexes this file and
    /// `GlyphColourTests` both record.
    ///
    /// All eight opacities rather than the six that make cards: `rule` and
    /// `border` go through the same function, and a regression here would be a
    /// regression in the panel's one hairline too.
    func testQuietIsPureInkAtTheStatedAlpha() throws {
        let opacities: [(name: String, value: Double)] = [
            ("card", Tokens.Fill.card), ("hover", Tokens.Fill.hover),
            ("logoTile", Tokens.Fill.logoTile), ("controlHover", Tokens.Fill.controlHover),
            ("cardHover", Tokens.Fill.cardHover), ("pressed", Tokens.Fill.pressed),
            ("rule", Tokens.Fill.rule), ("border", Tokens.Fill.border)
        ]
        for dark in [false, true] {
            let ink: CGFloat = dark ? 1 : 0
            for opacity in opacities {
                let resolved = try resolve(Tokens.quiet(opacity.value), dark: dark)
                for channel in [resolved.redComponent, resolved.greenComponent, resolved.blueComponent] {
                    XCTAssertEqual(
                        channel, ink, accuracy: 0.001,
                        "quiet(\(opacity.name)) is not pure ink in \(dark ? "dark" : "light")"
                    )
                }
                XCTAssertEqual(
                    Double(resolved.alphaComponent), opacity.value, accuracy: 0.001,
                    "quiet(\(opacity.name)) laid down \(resolved.alphaComponent) of the "
                    + "\(opacity.value) it names — a second alpha has got in"
                )
            }
        }
    }

    /// The six card planes, as hexes.
    ///
    /// A `Fill` value is an opacity rather than a colour precisely so that one
    /// ground carries the whole ladder, which means nothing in the palette
    /// states what these planes actually *are* — they exist only once something
    /// composites them, and they are what almost every ink in the app is read
    /// against. Recorded here so that a change to `Surface.base`, to a `Fill`
    /// value, or to `quiet(_:)` shows up as a named plane moving rather than as
    /// a distant contrast figure drifting a tenth.
    ///
    /// Light, over `#F6F7FA`, with the ΔL\* each one buys:
    /// `card` −4.18, `hover` −5.24, `logoTile` −5.94, `controlHover` −7.00,
    /// `cardHover` −7.70, `pressed` −10.54. Dark, over `#0C0D11`: +5.14, +6.61,
    /// +7.64, +8.63, +10.05, +13.43. A single opacity buys a 23% larger step in
    /// dark than in light because L\* is compressive near black; that asymmetry
    /// is stated in `Fill`'s own doc and is the price of the property that makes
    /// the ladder one set of numbers instead of a pair per value.
    ///
    /// `logoTile` light is the one entry sitting on a rounding tie: its blue
    /// channel composites to exactly `250 − 250·0.07 = 232.5`, and `.rounded()`
    /// goes half away from zero, so the plane is `#E5E6E9` and not the `#E5E6E8`
    /// the same arithmetic rounded to even would give. Both are the same colour
    /// to a display; the value is written down here so the next reader knows the
    /// last bit is a coin toss rather than a measurement.
    func testTheCardPlanesResolveToTheRecordedHexes() throws {
        let planes: [(name: String, opacity: Double, light: UInt32, dark: UInt32)] = [
            ("card", Tokens.Fill.card, 0xEAEBEE, 0x18191D),
            ("hover", Tokens.Fill.hover, 0xE7E8EB, 0x1B1C1F),
            ("logoTile", Tokens.Fill.logoTile, 0xE5E6E9, 0x1D1E22),
            ("controlHover", Tokens.Fill.controlHover, 0xE2E3E6, 0x1F2024),
            ("cardHover", Tokens.Fill.cardHover, 0xE0E1E4, 0x222326),
            ("pressed", Tokens.Fill.pressed, 0xD8D9DC, 0x292A2E)
        ]
        for dark in [false, true] {
            let base = try resolve(Tokens.Surface.base, dark: dark)
            for plane in planes {
                let ink = try resolve(Tokens.quiet(plane.opacity), dark: dark)
                let drawn = composite(ink, over: base)
                XCTAssertEqual(
                    drawn, dark ? plane.dark : plane.light,
                    String(
                        format: "%@ resolved to #%06X in %@, not #%06X",
                        plane.name, drawn, dark ? "dark" : "light", dark ? plane.dark : plane.light
                    )
                )
            }
        }
    }

    /// One plane laid over another, the way the palette states the arithmetic:
    /// `round(bg + (fg − bg)·α)` per 8-bit channel, with the ink's own resolved
    /// alpha rather than the `Fill` constant it was built from — the point of the
    /// pairing with `testQuietIsPureInkAtTheStatedAlpha` is that both halves are
    /// read back off the token rather than restated here.
    ///
    /// Quantised per step rather than at the end because each of these is a real
    /// drawn surface and a drawn surface is eight bits.
    private func composite(_ ink: NSColor, over ground: NSColor) -> UInt32 {
        func channel(_ component: (NSColor) -> CGFloat) -> UInt32 {
            let background = (component(ground) * 255).rounded()
            let foreground = (component(ink) * 255).rounded()
            let drawn = background + (foreground - background) * ink.alphaComponent
            return UInt32(min(max(drawn.rounded(), 0), 255))
        }
        return channel { $0.redComponent } << 16
             | channel { $0.greenComponent } << 8
             | channel { $0.blueComponent }
    }

    // MARK: - The keyboard's row

    /// A selected row draws the pressed plane, under every background setting and
    /// over every hover step.
    ///
    /// There is deliberately no `Fill.selected`, and this case is where that
    /// decision is pinned: a fourth plane between `cardHover` 0.09 and `pressed`
    /// 0.12 would be a 1.5% step nobody can see, asking the reader to tell apart
    /// two states that never appear on the same row anyway — the pointer's hover
    /// follows the pointer and the selection follows the arrow keys. The two are
    /// the same sentence, "this is the row the next action lands on", and they get
    /// the same number.
    func testASelectedRowDrawsThePressedFill() {
        XCTAssertEqual(Tokens.rowBackground(.plain, isHovered: false, isSelected: true), Tokens.Fill.pressed)
        for style in [AppearanceSettings.RowBackground.plain, .hover, .always] {
            for hovered in [false, true] {
                XCTAssertEqual(
                    Tokens.rowBackground(style, isHovered: hovered, isSelected: true),
                    Tokens.Fill.pressed,
                    "selection did not outrank \(style)/\(hovered ? "hovered" : "resting")"
                )
            }
        }
        // And a press still outranks the selection, which is the order the
        // function documents: the two resolve to one value, so the only way to
        // see the precedence is that neither branch can produce anything else.
        XCTAssertEqual(
            Tokens.rowBackground(.always, isHovered: true, isPressed: true, isSelected: true),
            Tokens.Fill.pressed
        )
        // The default keeps every existing call site exactly where it was.
        XCTAssertEqual(Tokens.rowBackground(.plain, isHovered: false), 0)
        XCTAssertEqual(Tokens.rowBackground(.always, isHovered: true), Tokens.Fill.cardHover)
    }

    // MARK: - Increased contrast

    func testRulesAndBordersStepUpUnderIncreasedContrast() {
        XCTAssertEqual(Tokens.ruleOpacity(increased: false), Tokens.Fill.rule)
        XCTAssertEqual(Tokens.borderOpacity(increased: false), Tokens.Fill.border)
        XCTAssertGreaterThan(Tokens.ruleOpacity(increased: true), Tokens.ruleOpacity(increased: false))
        XCTAssertGreaterThan(Tokens.borderOpacity(increased: true), Tokens.borderOpacity(increased: false))
    }

    // `Fill.divider` is not tested here, and that is the assertion: the token is
    // gone, so naming it would not compile, and the three `Divider` call sites it
    // fed are now the one `Rectangle` at `ruleOpacity(increased:)` covered above.
    // The same goes for `Ramp.body`, `Ramp.section` and `sectionSize(textScale:)`
    // — a deleted token needs no test, only no reference.

    // MARK: - Source guards

    /// No source file calls `.monospaced()`.
    ///
    /// `Text.monospaced()` is macOS 13.3 against this app's 13.0 floor, and the
    /// mistake is invisible where it is made: the `View` overload *is* 13.0, so
    /// the line looks fine and the compiler raises no availability error, but
    /// whenever the receiver is statically a `Text` overload resolution picks the
    /// 13.3 one and the app's real minimum moves. `Ramp.figureDesign` through
    /// `Font.system` carries no annotation at all and is what every figure in the
    /// app is set in, so nothing is given up by banning the call outright.
    ///
    /// A grep rather than a type-level guard because there is nothing to hang a
    /// type on — the offending call builds. Both spellings are banned together
    /// because a grep cannot tell which overload a receiver resolves to, which is
    /// the same reason the call site cannot. There are zero call sites today; this
    /// is what keeps it at zero.
    func testNoSourceFileCallsMonospaced() throws {
        // `.monospacedDigit()` and `design: .monospaced` are both wanted and
        // neither contains this, so the needle needs no exceptions.
        let needle = ".monospaced()"
        var scanned = 0
        var offenders: [String] = []

        for url in Self.appSources {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            scanned += 1
            guard text.contains(needle) else { continue }
            for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated()
            where Self.code(in: line).contains(needle) {
                offenders.append("\(url.lastPathComponent):\(offset + 1)")
            }
        }

        // A suite that scanned nothing would pass for the wrong reason, so the
        // walk has to prove it found the tree before its silence means anything.
        try XCTSkipIf(scanned == 0, "no sources under \(Self.repositoryRoot.path) to scan")
        XCTAssertEqual(offenders, [], "\(needle) is macOS 13.3; use Font.system(design: .monospaced)")
    }

    /// A line with its comment taken off.
    ///
    /// Necessary, not fastidious: the ban is *explained* in two doc comments —
    /// `Ramp.figureDesign`'s and `ForecastLine`'s — and a check that reads a whole
    /// line fails on the prose that documents it, which is the worst kind of red.
    /// Naive on purpose: a `//` inside a string literal would blind the rest of
    /// that line, and the only cost of that is a call hidden behind one, which is
    /// not a way anyone writes this mistake.
    private static func code(in line: Substring) -> Substring {
        guard let comment = line.range(of: "//") else { return line }
        return line[line.startIndex..<comment.lowerBound]
    }

    /// Every Swift file in the framework and in the app, from the compile-time
    /// location of this file — the app target is included because a 13.3 call
    /// raises the floor from either target, and the framework is only where most
    /// of the type lives.
    private static let appSources: [URL] = ["Sources", "SourcesApp"].flatMap { directory -> [URL] in
        let base = repositoryRoot.appendingPathComponent(directory)
        guard let walk = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil) else {
            return []
        }
        return walk.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// `#filePath` is `<root>/Tests/aibarsTests/TokensTests.swift`, so the root is
    /// three components up. Baked at compile time, which is the right time: the
    /// sources being checked are the sources that were built.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
