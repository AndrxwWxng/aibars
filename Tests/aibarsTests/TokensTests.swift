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

    func testFigureWidthIsTheMeasuredColumn() {
        // 15pt (cozy's figure size) at three digits: 15 * 0.6185 * 3 = 27.8325,
        // rounded up to a whole point so the column can never be a fraction
        // narrower than the glyphs in it.
        XCTAssertEqual(Tokens.figureWidth(15, digits: 3), 28)
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

    func testScrimIsHeavierOnLightThanOnDark() {
        let dark = Tokens.scrimAlpha(isDark: true, reduceTransparency: false)
        let light = Tokens.scrimAlpha(isDark: false, reduceTransparency: false)
        XCTAssertEqual(dark, 0.88, accuracy: 0.0001)
        XCTAssertEqual(light, 0.92, accuracy: 0.0001)
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
    /// The shipped steps measure 1.09 and 1.08 light, 1.07 and 1.15 dark; the
    /// floor is set at 1.05, which is loose enough to let a step be retuned and
    /// tight enough to catch one being lost.
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
