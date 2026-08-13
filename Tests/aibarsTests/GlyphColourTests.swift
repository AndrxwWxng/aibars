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

    /// The two stops that are text hold the text floor, on the ground text is
    /// read against.
    ///
    /// Resting is not in this loop any more, and the exemption is *earned below*
    /// rather than asserted: `testTheRestingStopIsNeverText` proves that no
    /// figure in the application resolves to it, and
    /// `testTheRestingStopClearsThreeToOneOnItsOwnTrack` holds it to the floor a
    /// graphic actually has. Dropping it from here without those two would be
    /// lowering a floor; with them it is measuring the right thing.
    ///
    /// The history: the resting stop *was* `Ink.muted`, a text ink, and it was
    /// folded there to delete a duplicate hex. That fold also deleted the ramp's
    /// only greyscale step — resting L\* 67.61 against the amber of the day at
    /// 65.73 was 1.062:1 — so a resting bar and a caution bar were the same grey
    /// the moment hue came off. `Tokens.Meter.fill` un-folds it, and being a
    /// graphic and not a figure is what buys the lightness that gap needs. Both
    /// stops have moved since; `testEveryPairOfStopsSeparatesInGreyscale` carries
    /// the figures that hold now.
    func testEveryStopThatIsTextClearsBodyTextContrastOnTheSurfaceItSitsOn() throws {
        for stop in stops where stop.name != "grey" {
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

    /// Nothing in the application draws the ramp's resting stop as type. This is
    /// the premise the test above rests on, so it is checked rather than assumed.
    ///
    /// Three places could put the ramp on a glyph, and all three are here:
    ///
    /// - **A row's headline figure and a chip's reading**, through
    ///   `AppearanceSettings.figureTint`. Under `.usage` it answers `Ink.body`
    ///   below caution and never reaches the ramp at all; under `.accent` and
    ///   `.provider` it answers a colour the ramp does not own; under `.mono` it
    ///   answers `Ink.muted`, which is a text ink and stays one.
    /// - **The menu bar strip's figure**, through `StripStyle.band`. `.perBar`
    ///   used to hand it `UsageTint.color(for:)` at every reading; it now
    ///   substitutes the strip's own `neutral` below caution, because the menu
    ///   bar's ground is the desktop's and not one this palette solves against.
    /// - **`UsageTint` itself**, which everything else reaches through.
    ///
    /// Asserted over the whole resting band and at both ends of it, so a stop
    /// creeping back onto a glyph fails here rather than in a screenshot.
    @MainActor
    func testTheRestingStopIsNeverText() throws {
        let resting = UsageTint.color(for: 0)
        // A scratch domain, not `AppearanceSettings.shared`: this walks
        // `colorRamp` through all four cases, and the save/restore that used to
        // guard that is not proof against the run being killed part way round the
        // loop. `TestIsolation.swift` has the argument.
        let appearance = try isolatedSettings()
        let ramps: [AppearanceSettings.ColorRamp] = [.usage, .accent, .provider, .mono]

        for dark in [false, true] {
            let restingHex = try XCTUnwrap(hex(resting, dark: dark))

            for ramp in ramps {
                appearance.colorRamp = ramp
                for percent in [0.0, 0.40, 0.79] {
                    let figure = appearance.figureTint(for: percent, providerAccent: .red)
                    XCTAssertNotEqual(
                        hex(figure, dark: dark), restingHex,
                        "a \(ramp) figure at \(percent) on \(dark ? "dark" : "light") is the ramp's "
                            + "resting stop, which is solved as a fill on Meter.track and not as type"
                    )
                }
            }

            // The strip, at the one colour mode that reaches the ramp at all.
            let ink = StripInk(
                neutral: Tokens.Ink.body,
                colour: .perBar,
                warningThreshold: 0.95,
                isDark: dark,
                coloursMarks: true,
                carriesColour: true
            )
            for percent in [0.0, 0.40, 0.79] {
                XCTAssertNotEqual(
                    hex(ink.band(percent), dark: dark), restingHex,
                    "the .perBar strip draws the ramp's resting stop at \(percent), on the menu bar's "
                        + "own ground rather than on Meter.track"
                )
            }
        }
    }

    /// And the floor the resting stop *does* have to clear: 3:1 against the track
    /// it lies on, which is what a non-text graphic needs to be a shape.
    ///
    /// Measured and recorded rather than bounded, because both halves are thin
    /// on purpose — the stop is cut as light as the track allows so that the gap
    /// to amber is as wide as possible, and there is nothing left to spend. If
    /// `Meter.track` moves, this is the first pair to re-cut.
    func testTheRestingStopClearsThreeToOneOnItsOwnTrack() throws {
        let expected: [(dark: Bool, ratio: Double)] = [(false, 3.05), (true, 3.19)]
        for row in expected {
            let ratio = try XCTUnwrap(
                contrast(UsageTint.color(for: 0), on: Tokens.Meter.track, dark: row.dark)
            )
            XCTAssertGreaterThanOrEqual(
                ratio, 3.0,
                "the resting fill measures \(ratio):1 on the \(row.dark ? "dark" : "light") track"
            )
            XCTAssertEqual(ratio, row.ratio, accuracy: 0.01)
        }
    }

    /// And the same floor for the two stops that are also bars, which is the
    /// half of the ramp this file used to leave to `Tokens.Meter`'s prose.
    ///
    /// Every stop is a fill before it is a figure — the bar and the dial are drawn
    /// in it at every reading — so 3:1 on the track is a floor all three have to
    /// clear and not only the resting one. It was asserted for resting alone
    /// because resting is the only stop that does *not* also have to clear 4.5:1
    /// somewhere, and 4.5 on the panel was quietly being treated as covering it.
    /// It does not: the track is a different ground from the panel, it is the one
    /// absolute token drawn inside the panel, and the re-cut moved both hues far
    /// enough for the two figures to swap places in dark (amber 5.09 → 7.19, red
    /// 7.13 → 5.26). Recorded so that a stop nudged toward the track fails here.
    func testEveryStopClearsThreeToOneOnItsOwnTrack() throws {
        let expected: [(name: String, percent: Double, light: Double, dark: Double)] = [
            ("grey", 0.10, 3.05, 3.19),
            ("amber", 0.85, 4.78, 7.19),
            ("red", 0.95, 6.85, 5.26)
        ]
        for stop in expected {
            for dark in [false, true] {
                let ratio = try XCTUnwrap(
                    contrast(UsageTint.color(for: stop.percent), on: Tokens.Meter.track, dark: dark)
                )
                XCTAssertGreaterThanOrEqual(
                    ratio, 3.0,
                    "\(stop.name) measures \(ratio):1 on the \(dark ? "dark" : "light") track — "
                        + "a meter fill is a meaningful non-text graphic on it"
                )
                XCTAssertEqual(ratio, dark ? stop.dark : stop.light, accuracy: 0.02, stop.name)
            }
        }
    }

    /// The ramp ranks in the channel a viewer actually uses: **chroma never
    /// decreases going up it.**
    ///
    /// This is the assertion the ramp has never had, and it is the one the shipped
    /// palette failed. Measured off the dark render, the 92% row's amber carried
    /// OKLCh chroma 0.1506 and the 97% row's red 0.1069 — the caution stop was
    /// **1.41× the chroma of the alarm stop**, so the worse reading was drawn in
    /// the softer, less saturated colour and a panel of nine rows pulled the eye to
    /// the second-worst one. Contrast could not see it (both stops cleared every
    /// floor) and lightness could not see it (they were 10.92 L\* apart), which is
    /// why it survived two passes of this file.
    ///
    /// Recorded as well as bounded, because the margins are the design: light
    /// 0.0113 → 0.1131 → 0.1595, dark 0.0117 → 0.1408 → 0.1600. The last step is
    /// the thin one at 1.14× in dark, and it is thin for a gamut reason rather than
    /// a taste — see `Ink.attention`, which sets out the two arrangements the
    /// pressed-card bound allows and why only this one ranks.
    ///
    /// OKLCh rather than HSB saturation or Lab chroma: it is the only one of the
    /// three that is perceptually uniform across lightness, and the two stops under
    /// test sit 10 L\* apart on purpose.
    func testChromaNeverDecreasesGoingUpTheRamp() throws {
        let expected: [(dark: Bool, ladder: [Double])] = [
            (false, [0.0113, 0.1131, 0.1595]),
            (true, [0.0117, 0.1408, 0.1600])
        ]
        for row in expected {
            let ladder = try [0.0, 0.85, 0.99].map {
                chroma(try XCTUnwrap(resolve(UsageTint.color(for: $0), dark: row.dark)))
            }
            for step in 1..<ladder.count {
                XCTAssertGreaterThan(
                    ladder[step], ladder[step - 1],
                    "the \(row.dark ? "dark" : "light") ramp loses chroma between stop "
                        + "\(step - 1) (\(ladder[step - 1])) and stop \(step) (\(ladder[step])) — "
                        + "the worse reading is drawn in the quieter colour"
                )
            }
            for (measured, recorded) in zip(ladder, row.ladder) {
                XCTAssertEqual(measured, recorded, accuracy: 0.002)
            }
        }
    }

    /// **Every pair** of stops is still two greys once the hue is taken off.
    ///
    /// This was `testTheRampIsMonotoneInGreyscale`, and it asserted something
    /// stronger and narrower: that each stop is ≥ 9 L\* *further from the ground*
    /// than the one below it. That premise died when the ramp was re-cut to rank in
    /// chroma. The sRGB gamut hands amber its chroma high and red its chroma low,
    /// so on a near-black ground the stop that can hold the most colour is the
    /// *nearer* one — dark now reads 51.89 → 76.92 → 66.76 rather than
    /// 51.89 → 65.73 → 76.65. `Ink.alarm` sets out the arithmetic.
    ///
    /// What replaces it is deliberately stated as three pairs rather than two
    /// steps, and the trade is worth writing down in both directions. **Gained:**
    /// resting-against-red is now measured rather than inferred, where the old form
    /// only ever got it by transitivity; and the property the old form could not
    /// express at all — that chroma ranks — is asserted next door in
    /// `testChromaNeverDecreasesGoingUpTheRamp`, which is the test that would have
    /// caught the defect this re-cut fixes. **Given up:** the signed direction, and
    /// with it the ≥ 18 that transitivity used to buy between resting and red in
    /// dark, which now measures 14.87. Nine is what a greyscale reader needs
    /// between any two marks; the rest was a by-product of an ordering the gamut
    /// will not pay for.
    ///
    /// Measured: light 49.99 / 37.76 / 27.93 — pairs 12.24, 9.83, 22.06. Dark
    /// 51.89 / 76.92 / 66.76 — pairs 25.03, 10.16, 14.87.
    func testEveryPairOfStopsSeparatesInGreyscale() throws {
        for dark in [false, true] {
            let ladder = try [0.0, 0.85, 0.99].map {
                lightness(try XCTUnwrap(resolve(UsageTint.color(for: $0), dark: dark)))
            }
            let names = ["resting", "amber", "red"]
            for first in 0..<ladder.count {
                for second in (first + 1)..<ladder.count {
                    XCTAssertGreaterThanOrEqual(
                        abs(ladder[first] - ladder[second]), 9,
                        "\(names[first]) L* \(ladder[first]) and \(names[second]) L* "
                            + "\(ladder[second]) are \(abs(ladder[first] - ladder[second])) apart in "
                            + "\(dark ? "dark" : "light") — one grey in a greyscale screenshot"
                    )
                }
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
            //   resting  #5F636B / #8A8F98  ->  Meter.fill     #74777E / #787C83
            //   caution  #8A5A00 / #D08214  ->  Ink.attention  #764C00 / #E08D1C
            //   warning  #B92126 / #FF6B6E  ->  Ink.alarm      #7E1217 / #FFA5A7
            //
            // Resting passed through `Ink.muted` (#53565E / #A0A5AE, 6.85/7.85
            // here) for one pass and moved off it again. That fold was the one
            // change in the rebuild that cost something it did not price: it put
            // the ramp's first two stops on the same rung of the grey ladder, so
            // resting and caution were 1.062:1 apart in dark and 1.020:1 in light
            // once the hue came off. The figure it is recorded at now is *lower*
            // on purpose and not a regression — see `Tokens.Meter.fill`. Nothing
            // draws it as type (`testTheRestingStopIsNeverText`), its ground is
            // the track rather than the panel
            // (`testTheRestingStopClearsThreeToOneOnItsOwnTrack`), and eight
            // resting rows of nine stop carrying a slab at body-text contrast.
            //
            // Recomputed: grey 6.85 -> 4.19 light and 7.85 -> 4.63 dark. Amber
            // and red were untouched by that pass and have since moved again:
            //
            //   caution  #764C00 / #E08D1C  ->  Ink.attention  #894800 / #F1B347
            //   warning  #7E1217 / #FFA5A7  ->  Ink.alarm      #890313 / #FD7B74
            //
            // The grounds moved as well — `Surface.base` went #F7F8FA ->
            // #F6F7FA light and #101114 -> #0C0D11 dark — but they are the
            // small half of every delta below: holding the old stops and
            // swapping only the ground moves the dark column by about +0.2 and
            // the light column by about -0.04. The stops did the rest.
            //
            // Re-recorded rather than corrected, twice. First: grey 5.67 -> 6.85
            // light and 5.81 -> 7.85 dark, amber 5.58 -> 6.99 and 6.19 -> 7.39,
            // red 5.97 -> 9.87 and 6.81 -> 10.35. Then the re-cut that made the
            // ramp rank in chroma: amber 6.99 -> 6.55 and 7.39 -> 10.43, red
            // 9.87 -> 9.40 and 10.35 -> 7.64.
            //
            // The dark column is the one that moved, and it moved because the two
            // dark stops changed places against the contrast bound rather than
            // because either was cut for contrast. Amber climbed to L* 76.92 and
            // gained 3 points of ratio it does not need; red dropped to 66.76,
            // spending 2.7 of its own to buy 50% more chroma. Neither number is a
            // target — the targets are 4.5:1 on the pressed card, which
            // `testNoInkFallsBelowFourFiveOnThePressedCard` holds, and the ranking,
            // which `testChromaNeverDecreasesGoingUpTheRamp` holds. These are the
            // figures those two decisions produced on the one ground that is the
            // same in every drawing.
            ("grey", 0.10, 4.19, 4.63),
            ("amber", 0.85, 6.55, 10.43),
            ("red", 0.95, 9.40, 7.64)
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
    ///     body       10.66 / 10.72        attention   4.60 / 6.39
    ///     mark        7.42 /  7.32        alarm       6.59 / 4.68
    ///     muted       4.80 /  4.81
    ///
    /// The measured minimum is **4.60**, *light* `attention`, and it moved here
    /// from dark `attention` at 4.53 when the ramp was re-cut to rank in chroma.
    /// The two are the same fact from either side: this plane bounds a light figure
    /// at L\* ≤ 38.32 and a dark one at L\* ≥ 65.51, and each appearance now spends
    /// its bound on whichever of its two hues has the least chroma to give — the
    /// light amber, brown at any lightness the bound allows, and the dark red, pink
    /// at any lightness above it. The margin over the floor widened from 0.03 to
    /// 0.10 in the process, which is the thickest this palette has held.
    ///
    /// The assertion below therefore names *light* as the binding appearance, and
    /// that is a real assertion rather than bookkeeping: it fails if a future
    /// re-cut lets the dark half slide back down onto the bound, which is exactly
    /// the arrangement that inverted the ramp. Both figures under 4.5 before the
    /// palette rebuild were on this plane and unmeasured — light `attention` at
    /// 4.44 and the ramp's own resting grey at 4.48 dark — because the file
    /// measured on a hovered card instead.
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
        XCTAssertEqual(
            lowest.appearance, "light",
            "the binding appearance is \(lowest.appearance) — if it is dark again, the dark amber "
                + "has slid back onto the bound and the ramp's chroma ranking is at risk"
        )
        XCTAssertEqual(
            lowest.ratio, 4.60, accuracy: 0.01,
            "the palette's thinnest margin is \(lowest.ratio):1, recorded as 4.60"
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
    /// Measured now: light 37.76 amber against 27.93 red, **9.83 apart**; dark
    /// 76.92 against 66.76, **10.16**. The floor is 9, which is under both and
    /// far over what the retired pair could reach.
    ///
    /// The direction is asserted as well as the distance, and the direction is the
    /// half that changed. It used to be "red is always the stop *further from the
    /// ground*", which means darker in light and lighter in dark — two opposite
    /// facts under one sentence, and the second of them is what produced the
    /// salmon: the only sRGB reds above L\* 74.5 are pastels, so the rule spent the
    /// alarm stop's whole chroma budget on satisfying itself. It is now **red is
    /// the darker of the two, in both appearances**, which is one fact rather than
    /// two, holds on either ground, and is the direction the gamut pays for — red's
    /// chroma peaks at L\* 53 and amber's near 75.
    ///
    /// This is a *replacement* for the old direction and not a relaxation: it is
    /// still an ordering assertion, it now holds in both appearances rather than
    /// flipping between them, and it is asserted alongside the ranking the old
    /// direction could not deliver (`testChromaNeverDecreasesGoingUpTheRamp`). What
    /// it gives up is the claim that red is the louder of the two in a *dark*
    /// greyscale screenshot, which is true and is priced on `Ink.alarm`: near-cap
    /// is carried there by shape and weight, and `testTheNearCapContractSurvives-
    /// Desaturation` renders it rather than asserting it from a palette.
    func testAmberAndRedSeparateInGreyscale() throws {
        for dark in [false, true] {
            let amber = lightness(try XCTUnwrap(resolve(Tokens.Ink.attention, dark: dark)))
            let red = lightness(try XCTUnwrap(resolve(Tokens.Ink.alarm, dark: dark)))
            XCTAssertGreaterThanOrEqual(
                abs(amber - red), 9,
                "amber L* \(amber) and red L* \(red) are \(abs(amber - red)) apart in "
                + "\(dark ? "dark" : "light") — one alarm in a greyscale screenshot"
            )
            XCTAssertLessThan(
                red, amber,
                "red L* \(red) is lighter than amber L* \(amber) in "
                + "\(dark ? "dark" : "light") — red is the darker stop in both appearances, "
                + "because that is where the gamut keeps its chroma"
            )
        }
    }

    // MARK: - The near-cap contract, rendered and desaturated

    /// **Draw it, take the hue off, and check the state is still there.**
    ///
    /// `ProviderRow.nearCapChannels` promises that "at or above the warning
    /// threshold" is carried by three channels that are not colour — the fill's
    /// square trailing cap, the figure at `Ramp.alertWeight`, and a fill visibly
    /// past the redline — and that promise is what lets the ramp be cut for
    /// ranking rather than for legibility. Every existing test of it reads the
    /// *inputs*: `nearCapChannels` returns two booleans and the tests assert the
    /// booleans. That is a test of a switch, not of a drawing, and it would pass
    /// unchanged if `MeterFill` stopped squaring its end or `UsageFigure` stopped
    /// reading the weight it is handed.
    ///
    /// So this renders the meter and the figure, converts every pixel to CIE
    /// luminance — which *is* desaturation, and is the same transfer the ratios in
    /// this file use, so the two cannot disagree about what a colour is — and
    /// measures each channel on the greyscale bitmap. The hue is not merely
    /// ignored; it is discarded before anything is asserted.
    ///
    /// It matters more since the re-cut than it did before it. The old dark ramp
    /// put red further from the ground than amber, so a dark greyscale screenshot
    /// ranked the two by lightness on its own; the new one puts red *nearer* the
    /// ground, which is the price of a red that can hold chroma at all. That price
    /// is only payable because these three channels really are drawn — so they are
    /// measured here rather than quoted from a doc comment.
    @MainActor
    func testTheNearCapContractSurvivesDesaturation() throws {
        let track: CGFloat = 160, thickness: CGFloat = 5, warning = 0.95

        @MainActor
        func bar(_ percent: Double, squareCap: Bool, dark: Bool) throws -> GreyGrid {
            try Self.desaturated(
                AnyView(
                    MeterTrack(
                        percent: percent,
                        height: thickness,
                        tint: UsageTint.color(for: percent),
                        isNearCap: squareCap,
                        warning: warning
                    )
                    .frame(width: track)
                ),
                size: CGSize(width: track, height: thickness),
                dark: dark
            )
        }

        for dark in [false, true] {
            let appearance = dark ? "dark" : "light"

            // **Length — the redline.** Both appearances, because the fill is
            // lighter than its track in one and darker in the other, and a
            // measurement that only worked on a dark screenshot would be assuming
            // the very thing under test.
            var reach: [Double: Int] = [:]
            for percent in [0.92, 0.97] {
                let grey = try bar(percent, squareCap: percent >= warning, dark: dark)
                let middle = grey.height / 2
                // Sampled inside the fill and inside the empty track, three pixels
                // in from each end so neither lands on the capsule's own
                // antialiasing. The gap between them is the bar surviving
                // desaturation, and it is asserted before anything is derived from
                // it — otherwise a fill that had gone the same grey as its track
                // would make every case below vacuously true.
                let fill = grey.value(atX: 3, y: middle)
                let empty = grey.value(atX: grey.width - 3, y: middle)
                XCTAssertGreaterThan(
                    abs(fill - empty), 0.10,
                    "at \(percent) on \(appearance) the fill and its track are the same grey "
                        + "once the hue is off — ΔY \(abs(fill - empty))"
                )
                reach[percent] = grey.lastRun(y: middle, from: empty, past: abs(fill - empty) / 2)
            }

            // The redline is drawn at `warning` of the track's own width, so its
            // pixel is the same arithmetic in the bitmap.
            let pixels = try XCTUnwrap(reach[0.97])
            let scale = Double(pixels) / (Double(track) * 0.97)
            let redline = Int((Double(track) * warning * scale).rounded())
            XCTAssertLessThan(
                try XCTUnwrap(reach[0.92]), redline,
                "on \(appearance) a 92% fill reaches \(reach[0.92] ?? -1)px, already past the "
                    + "redline at \(redline)px"
            )
            XCTAssertGreaterThan(
                pixels, redline,
                "on \(appearance) a 97% fill reaches \(pixels)px and does not clear the redline "
                    + "at \(redline)px"
            )

            // **Shape — the square trailing cap.** Measured as the same reading
            // drawn both ways rather than as two readings drawn once each, which
            // is what isolates the channel: the two bitmaps differ in nothing but
            // the end of the fill.
            //
            // The margin is small and is meant to be. `MeterTrack` itself records
            // that the corner is 2.5pt on a 5pt bar and "0.19% of the fill's area";
            // squaring one end of a capsule adds `r²(2 − π/2)` = 0.43r², which at
            // 2x on a 5pt bar is 10.7 square pixels of coverage against a fill of
            // about 3100. So this asserts the direction and the presence, not a
            // size — a cap that stopped being drawn would take all 10.7 away.
            let square = try bar(0.97, squareCap: true, dark: dark).inkMass()
            let round = try bar(0.97, squareCap: false, dark: dark).inkMass()
            XCTAssertGreaterThan(
                square, round,
                "on \(appearance) a near-cap fill lays down \(square) of ink against a round-ended "
                    + "fill of the same length at \(round) — the trailing end is not squaring off"
            )
        }

        // **Weight.** The same reading rendered on either side of the threshold,
        // so the digits are identical and the only difference is the weight the
        // contract asks for. Ink is summed as coverage rather than counted as
        // pixels: antialiasing puts most of a stem's extra weight into partial
        // coverage rather than into new pixels.
        var ink: [String: Double] = [:]
        for (name, threshold) in [("medium", 0.95), ("semibold", 0.90)] {
            ink[name] = try Self.desaturated(
                AnyView(
                    UsageFigure(
                        percent: 0.94,
                        size: 13,
                        unitSize: UsageFigure.unitSize(for: 13),
                        weight: ProviderRow.figureWeight(percent: 0.94, warning: threshold),
                        tint: Tokens.Ink.body
                    )
                ),
                size: nil,
                dark: true
            ).inkMass()
        }
        let medium = try XCTUnwrap(ink["medium"])
        let semibold = try XCTUnwrap(ink["semibold"])
        XCTAssertGreaterThan(
            semibold, medium * 1.02,
            "\"94%\" lays down \(semibold) of ink at the near-cap weight against \(medium) below "
                + "it — under 2% apart, which is not a weight step a reader can see"
        )
    }

    /// A rendered view as a greyscale grid, with the hue thrown away.
    ///
    /// Drawn on the panel's own ground rather than on transparency: the contract is
    /// about what a reader sees, and alpha is not what a screenshot keeps.
    /// `cacheDisplay` rather than `ImageRenderer` for the reason `PanelLayoutTests`
    /// records — the renderer resolves this app's scroll view to an empty box — and
    /// one run-loop turn rather than a sleep, following `PanelWidthContractTests`.
    @MainActor
    private static func desaturated(_ view: AnyView, size: CGSize?, dark: Bool) throws -> GreyGrid {
        let host = NSHostingView(rootView: AnyView(
            view
                .background(Tokens.Surface.base)
                .environment(\.colorScheme, dark ? .dark : .light)
        ))
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let resolved = size ?? host.fittingSize
        host.frame = CGRect(origin: .zero, size: resolved)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(mode: .default, before: Date())
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)

        var values = [Double](repeating: 0, count: rep.pixelsWide * rep.pixelsHigh)
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide {
                guard let pixel = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                func linear(_ value: CGFloat) -> Double {
                    let channel = Double(min(max(value, 0), 1))
                    return channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
                }
                values[y * rep.pixelsWide + x] =
                    0.2126 * linear(pixel.redComponent)
                    + 0.7152 * linear(pixel.greenComponent)
                    + 0.0722 * linear(pixel.blueComponent)
            }
        }
        return GreyGrid(width: rep.pixelsWide, height: rep.pixelsHigh, values: values)
    }

    /// One rendered view with its hue removed. Deliberately not a `Color` or an
    /// `NSImage`: everything below reads luminance and nothing can reach a
    /// component, which is what makes "desaturated" a property of the fixture
    /// rather than a promise in a comment.
    private struct GreyGrid {
        let width: Int
        let height: Int
        let values: [Double]

        func value(atX x: Int, y: Int) -> Double {
            values[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
        }

        /// The last x on one row that stands `past` a threshold away from the empty
        /// track's own luminance — the fill's reach along that row.
        ///
        /// A threshold rather than "any difference from the ground", because the
        /// redline is a rectangle of `Surface.base` standing *in* the empty track
        /// and would otherwise be counted as fill: at 92% it sits 5pt beyond the
        /// end of the bar and reported the fill as reaching past the very mark it
        /// exists to stand in front of. Half the measured fill-to-track distance,
        /// so it works whichever side of the track the fill sits on.
        func lastRun(y: Int, from empty: Double, past threshold: Double) -> Int {
            var last = 0
            for x in 0..<width where abs(value(atX: x, y: y) - empty) > threshold { last = x }
            return last
        }

        /// Total coverage: the summed distance of every pixel from the ground the
        /// drawing sits on, which is the corner. Sums partial coverage rather than
        /// counting pixels, and works on either appearance.
        func inkMass() -> Double {
            let ground = value(atX: 0, y: 0)
            return values.reduce(0) { $0 + abs($1 - ground) }
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

    /// OKLCh chroma: how much colour a colour has, on the one axis of the three
    /// that is perceptually uniform across lightness.
    ///
    /// The axis the ramp has to rank on, and the reason it is this one rather than
    /// HSB saturation or CIELAB chroma. Both of those move with lightness on their
    /// own — HSB reports the old dark red `#FFA5A7` at 0.35 and the old dark amber
    /// `#E08D1C` at 0.87 partly because one is 10 L\* lighter than the other — and
    /// the two stops under test sit ten points apart by design, so a measure that
    /// confounds the two would be measuring the separation twice and the colour not
    /// at all.
    ///
    /// Written out here rather than reached for: `NSColor` has no OKLab space, and
    /// the transfer is short enough that spelling it out is cheaper than a
    /// dependency and clearer than a table. Same sRGB linearisation the luminance
    /// above uses, so the two cannot disagree about what a colour is either.
    private func chroma(_ colour: NSColor) -> Double {
        func linear(_ value: CGFloat) -> Double {
            let channel = Double(min(max(value, 0), 1))
            return channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        let r = linear(colour.redComponent)
        let g = linear(colour.greenComponent)
        let b = linear(colour.blueComponent)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        return (a * a + bb * bb).squareRoot()
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
