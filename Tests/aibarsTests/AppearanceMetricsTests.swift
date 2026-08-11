import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// A scratch domain per test, so one test's writes cannot decide another's
/// starting state. Named after the test rather than shared, because these assert
/// what a fresh install and a stored value each produce.
///
/// At file scope rather than on one class: the derived metrics and the figure's
/// colour are both settings read off a store, and two copies of the same
/// four-line fixture is two places for "a fresh install" to mean two things.
@MainActor
private func settings(_ name: String, seed: [String: Any] = [:]) -> AppearanceSettings {
    let domain = "aibars.metrics-tests.\(name)"
    guard let store = UserDefaults(suiteName: domain) else {
        XCTFail("could not open a scratch defaults domain")
        return AppearanceSettings(store: .standard)
    }
    store.removePersistentDomain(forName: domain)
    for (key, value) in seed { store.set(value, forKey: key) }
    return AppearanceSettings(store: store)
}

/// The derived half of the appearance model: the two type sizes and the two
/// figure rails the panel's new column is built on, and the settings that had to
/// change shape underneath them.
///
/// Asserted rather than eyeballed because every one of these is a number some
/// other view lays itself out against. A figure size that quietly drifts from
/// its title size, or a rail whose width no longer matches the digits it
/// reserves, shows up as a percentage truncating on one row out of nine — which
/// is exactly the class of fault nobody notices in a screenshot.
final class AppearanceMetricsTests: XCTestCase {

    // MARK: - The two derived type sizes

    @MainActor
    func testFigureAndUnitSizePerDensity() {
        let expected: [(AppearanceSettings.Density, CGFloat, CGFloat)] = [
            (.compact, 14, 9),
            (.cozy, 15, 9),
            (.comfortable, 16, 10)
        ]
        let appearance = settings("sizes")
        appearance.textScale = 1.0
        for (density, figure, unit) in expected {
            appearance.density = density
            XCTAssertEqual(
                appearance.metrics.figureSize, figure,
                "\(density.rawValue) draws its figure at \(appearance.metrics.figureSize)pt, not \(figure)"
            )
            XCTAssertEqual(
                appearance.metrics.unitSize, unit,
                "\(density.rawValue) draws its unit at \(appearance.metrics.unitSize)pt, not \(unit)"
            )
        }
    }

    /// The floors exist so density times text scale cannot produce a figure
    /// smaller than macOS draws text at. Both are asserted at the bottom of the
    /// range, where the multiplication is at its worst.
    @MainActor
    func testTheDerivedSizesHoldTheirFloors() {
        let appearance = settings("floors")
        appearance.textScale = 0.85
        for density in AppearanceSettings.Density.allCases {
            appearance.density = density
            let metrics = appearance.metrics
            XCTAssertGreaterThanOrEqual(
                metrics.figureSize, 12,
                "\(density.rawValue) at the smallest text scale sank the figure to \(metrics.figureSize)pt"
            )
            XCTAssertGreaterThanOrEqual(
                metrics.unitSize, 9,
                "\(density.rawValue) at the smallest text scale sank the unit to \(metrics.unitSize)pt"
            )
            // The figure is the row's answer: it must never end up smaller than
            // the name beside it, floors or no floors.
            XCTAssertGreaterThan(
                metrics.figureSize, metrics.titleSize,
                "\(density.rawValue) drew the figure no larger than the service name"
            )
        }
    }

    // MARK: - The rails

    /// The literal widths the panel reserves at the shipped density. Spelled out
    /// rather than recomputed from the same formula, so a change to the advance
    /// ratio or to the multiplier has to be admitted here.
    @MainActor
    func testTheRailsAtCozy() {
        let appearance = settings("rails")
        appearance.density = .cozy
        appearance.textScale = 1.0
        XCTAssertEqual(appearance.metrics.headlineRail, 35, "the headline rail is not 35pt at cozy")
        XCTAssertEqual(appearance.metrics.secondaryRail, 27, "the secondary rail is not 27pt at cozy")
    }

    /// A secondary window's figure is a smaller reading of the same kind, so its
    /// rail must be narrower at every density. Two rails of the same width would
    /// mean the two type sizes had collapsed into one.
    @MainActor
    func testTheSecondaryRailIsAlwaysNarrower() {
        let appearance = settings("rail-order")
        for density in AppearanceSettings.Density.allCases {
            for scale in [0.85, 1.0, 1.30] {
                appearance.density = density
                appearance.textScale = scale
                let metrics = appearance.metrics
                XCTAssertLessThan(
                    metrics.secondaryRail, metrics.headlineRail,
                    "\(density.rawValue) at \(scale) reserves as much for a secondary figure as for the headline"
                )
            }
        }
    }

    @MainActor
    func testCaptionGapNeverCloses() {
        let appearance = settings("caption-gap")
        for density in AppearanceSettings.Density.allCases {
            appearance.density = density
            let metrics = appearance.metrics
            XCTAssertGreaterThanOrEqual(metrics.captionGap, 2, "\(density.rawValue) closed the caption gap")
            XCTAssertLessThanOrEqual(
                metrics.captionGap, metrics.contentSpacing,
                "\(density.rawValue) separates a caption from its own title by more than two things"
            )
        }
    }

    // MARK: - Presets

    /// Every preset has to survive being written to the store and read back by a
    /// fresh instance. This is what catches a preset that names a value outside
    /// its own clamp: `normalize` would pull it in on load and the preset would
    /// stop matching itself for reasons invisible in the table.
    @MainActor
    func testEveryPresetRoundTripsThroughTheStore() {
        for preset in AppearanceSettings.Preset.allCases {
            let domain = "aibars.metrics-tests.persist.\(preset.rawValue)"
            guard let store = UserDefaults(suiteName: domain) else {
                XCTFail("could not open a scratch defaults domain")
                return
            }
            store.removePersistentDomain(forName: domain)
            AppearanceSettings(store: store).apply(preset)
            let reloaded = AppearanceSettings(store: store)
            XCTAssertEqual(
                reloaded.snapshot, preset.snapshot,
                "\(preset.id) did not survive a relaunch"
            )
        }
    }

    /// Applying a preset must name that preset and no other, and touching one
    /// field must name none. The second half is what a retired Snapshot field
    /// breaks: equality is over every field, so a preset table left half
    /// re-spelled silently stops recognising anything.
    @MainActor
    func testMatchingPresetRecognisesEachPresetExactly() {
        let appearance = settings("matching")
        for preset in AppearanceSettings.Preset.allCases {
            appearance.apply(preset)
            XCTAssertEqual(appearance.matchingPreset, preset, "\(preset.id) does not name itself")

            // One field, changed to something no preset uses.
            let before = appearance.panelWidth
            appearance.panelWidth = 411
            XCTAssertNil(
                appearance.matchingPreset,
                "\(preset.id) still matched after its panel width was changed"
            )
            appearance.panelWidth = before
        }
    }

    /// THE PRESET INVARIANT. Read the failure message before touching anything
    /// else: this is the test a reskin trips.
    ///
    /// `Snapshot()`'s per-property defaults are the only place the shipped
    /// configuration is written down, and `Preset.comfortable` is that same
    /// configuration spelled a second time. The two must stay identical, because
    /// `matchingPreset` is plain equality over every field: change one default
    /// argument in the reskin — a density, a meter thickness, a threshold, a
    /// glyph height — and every fresh install launches on a configuration that
    /// no preset names, so the Appearance pane opens with nothing selected and
    /// the five chips become five ways to leave the state you are in.
    ///
    /// Three assertions because there are three ways to get here: the preset
    /// table drifting from the defaults, the defaults drifting from what a fresh
    /// store loads, and `matchingPreset` itself no longer recognising either.
    @MainActor
    func testTheShippedDefaultsAreStillTheComfortablePreset() {
        XCTAssertEqual(
            AppearanceSettings.Preset.comfortable.snapshot, AppearanceSettings.Snapshot(),
            """
            A Snapshot default changed and the comfortable preset was not changed with it. \
            Preset.comfortable == Snapshot() is the invariant the reskin is not allowed to \
            break: it is what makes a fresh install recognise the preset it is on. Whatever \
            moved the default has to move the comfortable preset's spelling of it too.
            """
        )

        let appearance = settings("empty")
        XCTAssertEqual(
            appearance.snapshot, AppearanceSettings.Snapshot(),
            """
            A defaults domain with nothing of ours in it did not load the shipped \
            configuration. Either a property's fallback no longer comes from Snapshot(), \
            or normalize() is pulling a shipped value into range — which would mean a \
            default now sits outside its own clamp.
            """
        )
        XCTAssertEqual(
            appearance.matchingPreset, .comfortable,
            """
            A fresh install launches on no preset at all. The Appearance pane will open \
            with none of its five chips selected, and every chip will look like a change \
            away from the state the user is already in.
            """
        )
    }

    // MARK: - The menu bar settings

    @MainActor
    func testTheServiceCountClampsAStoredValue() {
        let high = settings("count-high", seed: ["aibars.appearance.menuBarServiceCount": 6])
        XCTAssertEqual(high.menuBarServiceCount, MenuBarStripContent.range.upperBound)

        let low = settings("count-low", seed: ["aibars.appearance.menuBarServiceCount": 0])
        XCTAssertEqual(low.menuBarServiceCount, MenuBarStripContent.range.lowerBound)
    }

    /// A user who set the old bar count keeps a service count near it rather than
    /// being dropped back to the default — six bars meant "show me as many as you
    /// can", and three services is that answer under the new strip.
    @MainActor
    func testAStoredBarCountCarriesOver() {
        let appearance = settings("bar-count", seed: ["aibars.appearance.menuBarBarCount": 6])
        XCTAssertEqual(appearance.menuBarServiceCount, 3)
    }

    /// "name" was icon plus rotating service names, which the per-service marks
    /// replace. It must land on the default rather than on whichever case happens
    /// to be first.
    @MainActor
    func testAStoredRotatingNameStyleBecomesMarkPlusFigure() {
        let appearance = settings("label-name", seed: ["aibars.appearance.menuBarLabel": "name"])
        XCTAssertEqual(appearance.menuBarLabel, .iconAndPercent)
        XCTAssertEqual(appearance.menuBarLabel.rawValue, "percent")
    }

    @MainActor
    func testEachLabelStyleDropsExactlyOneThing() {
        XCTAssertTrue(AppearanceSettings.MenuBarLabelStyle.iconOnly.showsGlyph)
        XCTAssertFalse(AppearanceSettings.MenuBarLabelStyle.iconOnly.showsFigure)
        XCTAssertTrue(AppearanceSettings.MenuBarLabelStyle.iconAndPercent.showsGlyph)
        XCTAssertTrue(AppearanceSettings.MenuBarLabelStyle.iconAndPercent.showsFigure)
        XCTAssertFalse(AppearanceSettings.MenuBarLabelStyle.percentOnly.showsGlyph)
        XCTAssertTrue(AppearanceSettings.MenuBarLabelStyle.percentOnly.showsFigure)
    }

    /// A status-only service carries no urgency, so it can never take a slot from
    /// a service that is actually near a cap. ChatGPT and Copilot report a
    /// subscription and a seat, and either one shouldering Claude at 92% off the
    /// strip is the whole feature failing quietly.
    @MainActor
    func testStatusOnlyServicesNeverDisplaceAMeteredOne() {
        let appearance = settings("entries")
        appearance.menuBarServiceCount = 3

        let readings: [(serviceID: String, displayName: String, percent: Double?)] = [
            ("chatgpt", "ChatGPT", nil),
            ("copilot", "Copilot", nil),
            ("claude", "Claude", 0.92),
            ("gemini", "Gemini", 0.30)
        ]
        let entries = MenuBarStripContent.entries(
            from: readings.map {
                MenuBarEntry(serviceID: $0.serviceID, displayName: $0.displayName, percent: $0.percent)
            },
            limit: appearance.menuBarServiceCount
        )
        XCTAssertEqual(Array(entries.map(\.serviceID).prefix(2)), ["claude", "gemini"])
    }

    /// A service that has not answered is absent from `serviceReadings` rather
    /// than present with a nil percent, so a launch with nothing reported yet
    /// draws nothing at all — not a row of dashes claiming every service
    /// publishes no quota.
    @MainActor
    func testNothingReportedYetDrawsNothing() {
        let appearance = settings("entries-empty")
        XCTAssertTrue(appearance.menuBarEntries(in: AppState()).isEmpty)
    }
}

/// D3, as arithmetic: which colour a figure is set in, and which one the menu bar
/// is allowed to spend.
///
/// The design's claim is that in a healthy panel the only coloured things are the
/// meters, and that a number gaining colour is therefore the news. That claim
/// lives entirely in one guard inside `figureTint`, and it is a guard with two
/// ways to be wrong that no screenshot shows: an exclusive boundary leaves the
/// figure neutral at the exact percentage the meter turns amber, and a
/// too-eager neutral case robs a user who asked for a coloured column of the
/// column they asked for.
///
/// Colours are compared as resolved sRGB rather than as `Color` values wherever
/// the two sides were built by separate calls, because `Tokens.dynamic` hands
/// back a fresh `NSColor` provider each time and two of those are not equal even
/// when they draw identically. `Color.primary` is compared as itself: that is
/// what catches an `.opacity()` laid over it, which is the one failure a neutral
/// figure cannot afford.
final class AppearanceTintTests: XCTestCase {
    /// The three stops `tint` samples, named as the settings name them. Sampled
    /// inside their own fixed bands, exactly as `AppearanceSettings` does: the
    /// boundaries are settings, the palette is not, so a moved threshold must not
    /// change which of these three a test is comparing against.
    private let resting = UsageTint.color(for: 0)
    private let caution = UsageTint.color(for: 0.60)
    private let warning = UsageTint.color(for: 0.85)

    /// Magenta at full chroma for the user's accent, spring green for the
    /// provider's: neither is in the palette, in any brand mark, or reachable by
    /// any ramp. "Did this defer" is then a fact rather than a guess.
    private let accentSentinel = 0xFF00FF
    private let providerSentinel = Color(hex: 0x00FF7F)

    /// Every ramp that is a request for a coloured column. `.usage` is the only
    /// one the neutral rule applies to, so it is the one excluded here.
    @MainActor
    private var chosenRamps: [AppearanceSettings.ColorRamp] {
        AppearanceSettings.ColorRamp.allCases.filter { $0 != .usage }
    }

    // MARK: - The D3 table

    /// The table itself, at the shipped thresholds: neutral below caution, the
    /// ramp's own colour at and above it.
    @MainActor
    func testTheFigureIsNeutralBelowCautionAndTakesTheRampAtAndAboveIt() {
        let appearance = settings("figure-usage")
        appearance.colorRamp = .usage
        XCTAssertEqual(appearance.cautionThreshold, 0.60, "the fixtures below are written against the shipped pair")
        XCTAssertEqual(appearance.warningThreshold, 0.85)

        for percent in [-0.5, 0, 0.01, 0.25, 0.5, 0.59] {
            XCTAssertEqual(
                figure(appearance, percent), Color.primary,
                "a figure at \(percent) took colour while the row was still healthy"
            )
        }

        let coloured: [(Double, Color)] = [
            (0.60, caution),
            (0.70, caution),
            (0.84, caution),
            (0.85, warning),
            (0.92, warning),
            (1, warning),
            (1.4, warning)
        ]
        for (percent, expected) in coloured {
            assertSameInk(figure(appearance, percent), expected, "the figure at \(percent)")
            XCTAssertNotEqual(figure(appearance, percent), Color.primary, "the figure at \(percent) stayed neutral")
        }

        // The resting teal is the meter's colour at these levels and never the
        // figure's — if it were, the neutral rule would be doing nothing.
        assertDifferentInk(figure(appearance, 0.1), resting, "a healthy figure took the meter's teal")
    }

    /// Inclusive, and inclusive is the side that matters: the meter turns amber
    /// at exactly `cautionThreshold`, and a figure that waited for the next float
    /// would leave the number and the bar beside it disagreeing at the one
    /// percentage where the disagreement is the whole point of the instrument.
    @MainActor
    func testTheBoundaryIsInclusiveAtTheCautionThreshold() {
        let appearance = settings("figure-boundary")
        appearance.colorRamp = .usage
        let boundary = appearance.cautionThreshold
        assertSameInk(figure(appearance, boundary), caution, "the caution threshold itself")
        assertSameInk(figure(appearance, boundary.nextUp), caution, "the float above the caution threshold")
        XCTAssertEqual(
            figure(appearance, boundary.nextDown), Color.primary,
            "the float below the caution threshold took colour"
        )
    }

    /// And the boundary is the setting, not the 0.60 the palette happens to
    /// change colour at. These two numbers are equal on a fresh install and that
    /// is the only reason a hardcoded 0.60 would pass the test above.
    @MainActor
    func testTheNeutralBandFollowsTheSettingRatherThanThePalette() {
        let appearance = settings("figure-moved")
        appearance.apply(AppearanceSettings.Snapshot(
            colorRamp: .usage,
            cautionThreshold: 0.40,
            warningThreshold: 0.85
        ))
        XCTAssertEqual(appearance.cautionThreshold, 0.40, accuracy: 0.0001)

        XCTAssertEqual(figure(appearance, 0.39), Color.primary, "a figure below the user's caution threshold")
        assertSameInk(figure(appearance, 0.40), caution, "the figure at the user's caution threshold")
        // 0.50 is teal in the palette's own fixed bands and caution under this
        // user's settings. The figure follows the user.
        assertSameInk(figure(appearance, 0.50), caution, "the figure between the setting and the palette's band")
    }

    // MARK: - The ramps that were asked for a coloured column

    /// The deferral is unconditional, at every level including below caution.
    /// A user who picked their accent, a brand colour or monochrome asked for a
    /// coloured column of figures and gets one; the neutral rule is a statement
    /// about `.usage` and about nothing else.
    @MainActor
    func testEveryChosenRampKeepsItsColumnAtEveryLevel() {
        let appearance = settings("figure-ramps")
        appearance.accentColorHex = accentSentinel

        for ramp in chosenRamps {
            appearance.colorRamp = ramp
            for percent in [-0.5, 0, 0.1, 0.5, 0.59, 0.60, 0.70, 0.84, 0.85, 1, 1.4] {
                assertSameInk(
                    figure(appearance, percent),
                    appearance.tint(for: percent, providerAccent: providerSentinel),
                    "\(ramp.rawValue) at \(percent) does not agree with the meter beside it"
                )
            }
        }
    }

    /// The half of that the deferral would still pass if `tint` itself had gone
    /// neutral: below caution, the two coloured ramps hand back the colour the
    /// user chose, by identity.
    @MainActor
    func testTheChosenColourIsWhatAHealthyFigureIsSetIn() {
        let appearance = settings("figure-chosen")
        appearance.accentColorHex = accentSentinel

        appearance.colorRamp = .accent
        assertSameInk(figure(appearance, 0.1), Color(hex: UInt32(accentSentinel)), "the accent ramp below caution")
        XCTAssertNotEqual(figure(appearance, 0.1), Color.primary, "the accent ramp went neutral")

        appearance.colorRamp = .provider
        assertSameInk(figure(appearance, 0.1), providerSentinel, "the provider ramp below caution")
        XCTAssertNotEqual(figure(appearance, 0.1), Color.primary, "the provider ramp went neutral")
    }

    /// Monochrome is the one ramp whose coloured column *is* the label colour,
    /// right up to the warning — and then it is not. A monochrome panel is a
    /// preference; a panel that hides an imminent cutoff is a bug, so `tint` gives
    /// the ramp up at `warningThreshold` and the figure follows it there rather
    /// than inventing a rule of its own.
    ///
    /// The opacity floor is asserted on both sides of the warning because both
    /// sides are figures being read: a washed-out number is a number that has been
    /// dimmed, and nothing in these settings asks for that. The floor is
    /// `Color.primary`'s own 0.847, which is the lightest anything here gets.
    @MainActor
    func testMonochromeKeepsTheLabelColourUntilTheWarningAndGivesItUpThere() throws {
        let appearance = settings("figure-mono")
        appearance.colorRamp = .mono

        for percent in [0, 0.1, 0.59, 0.60, 0.84] {
            XCTAssertEqual(
                figure(appearance, percent), Color.primary,
                "the monochrome figure at \(percent) is not the label colour"
            )
        }
        for percent in [0.85, 0.99, 1] {
            assertSameInk(figure(appearance, percent), warning, "the monochrome figure at \(percent)")
            XCTAssertNotEqual(
                figure(appearance, percent), Color.primary,
                "monochrome held its own preference over an imminent cutoff at \(percent)"
            )
        }

        for percent in [0, 0.60, 0.85, 1] {
            for dark in [false, true] {
                let opacity = try XCTUnwrap(alpha(figure(appearance, percent), dark: dark))
                XCTAssertGreaterThanOrEqual(opacity, 0.84, "the monochrome figure at \(percent) is a wash")
            }
        }
    }

    // MARK: - Near the cap, under every threshold pair

    /// A figure at or above the warning is never neutral, whatever the two
    /// sliders were dragged to.
    ///
    /// The sliders are coupled — caution is held at least 0.05 below warning —
    /// so the pairs are a triangle rather than a square, and the invariant is
    /// only interesting at its narrow end, where a caution threshold sits 0.05
    /// under a warning threshold and there is almost no amber band left to be
    /// wrong about. A panel that hid an imminent cutoff behind a graphite number
    /// would be the reskin costing the app the one reading it exists for.
    @MainActor
    func testNoThresholdPairLetsANearCapFigureGoNeutral() {
        let appearance = settings("figure-thresholds")
        var pairs = 0
        for warningStop in stride(from: 0.50, through: 0.98, by: 0.04) {
            for cautionStop in stride(from: 0.30, through: warningStop - 0.05, by: 0.10) {
                appearance.apply(AppearanceSettings.Snapshot(
                    colorRamp: .usage,
                    cautionThreshold: cautionStop,
                    warningThreshold: warningStop
                ))
                let threshold = appearance.warningThreshold
                XCTAssertLessThan(
                    appearance.cautionThreshold, threshold,
                    "the clamps let the two bands cross at \(cautionStop)/\(warningStop)"
                )
                pairs += 1

                for percent in [threshold, threshold.nextUp, (threshold + 1) / 2, 1, 1.5, .greatestFiniteMagnitude] {
                    XCTAssertNotEqual(
                        figure(appearance, percent), Color.primary,
                        "a figure at \(percent) went neutral against a warning threshold of \(threshold)"
                    )
                    assertSameInk(
                        figure(appearance, percent), warning,
                        "the figure at \(percent) against a warning threshold of \(threshold)"
                    )
                }
            }
        }
        XCTAssertGreaterThan(pairs, 40, "the grid stopped covering the range the sliders can produce")
    }

    /// A percentage divided by a limit of zero is a NaN, and a NaN loses every
    /// comparison it is given — including the one that would have made the figure
    /// neutral. That is the right way round: a number the app could not read must
    /// not come out looking like a healthy one, and the figure lands on the alarm
    /// exactly where the meter beside it does.
    ///
    /// A reading below zero is a different fault and takes the other answer. It is
    /// genuinely below the caution threshold, so the figure is graphite while the
    /// meter is teal — which is the D3 rule doing its job, not the panel
    /// contradicting itself.
    @MainActor
    func testAnUnreadableNumberIsNeverDrawnAsAHealthyOne() {
        let appearance = settings("figure-nan")
        for ramp in AppearanceSettings.ColorRamp.allCases {
            appearance.colorRamp = ramp
            for percent in [Double.nan, .infinity] {
                assertSameInk(
                    figure(appearance, percent),
                    appearance.tint(for: percent, providerAccent: providerSentinel),
                    "\(ramp.rawValue) at \(percent) does not agree with the meter beside it"
                )
                XCTAssertNotEqual(
                    figure(appearance, percent), Color.primary,
                    "\(ramp.rawValue) drew an unreadable \(percent) as a healthy figure"
                )
            }
        }

        appearance.colorRamp = .usage
        assertSameInk(figure(appearance, .nan), warning, "a NaN under the usage ramp")
        XCTAssertEqual(figure(appearance, -.infinity), Color.primary, "a reading below zero is a quiet row")
    }

    // MARK: - The menu bar tint

    /// The threshold the strip goes colourful at is the user's, not the 0.85 the
    /// palette changes band at. Asserted in both directions, because a hardcoded
    /// 0.85 is wrong twice over: it withholds the colour from a user who wanted
    /// warning at 0.60, and spends it on one who moved it to 0.95.
    @MainActor
    func testTheMenuBarTintFollowsTheWarningThresholdRatherThanTheHardcodedStop() throws {
        let appearance = settings("menu-bar-tint")

        appearance.apply(AppearanceSettings.Snapshot(
            cautionThreshold: 0.40,
            warningThreshold: 0.60,
            menuBarColour: .alertOnly
        ))
        XCTAssertEqual(appearance.warningThreshold, 0.60, accuracy: 0.0001)
        XCTAssertNil(appearance.menuBarTint(for: 0.55), "the strip took colour below the user's own warning")
        assertSameInk(
            try XCTUnwrap(appearance.menuBarTint(for: 0.60), "the strip stayed quiet at the user's warning"),
            warning,
            "the tint at a lowered warning threshold"
        )
        XCTAssertNotNil(appearance.menuBarTint(for: 0.62))

        appearance.apply(AppearanceSettings.Snapshot(
            cautionThreshold: 0.60,
            warningThreshold: 0.95,
            menuBarColour: .alertOnly
        ))
        XCTAssertEqual(appearance.warningThreshold, 0.95, accuracy: 0.0001)
        XCTAssertNil(
            appearance.menuBarTint(for: 0.90),
            "the strip warned at 0.90 while the user had asked to be warned at 0.95"
        )
        XCTAssertNotNil(appearance.menuBarTint(for: 0.95))
        XCTAssertNotNil(appearance.menuBarTint(for: 1))
    }

    /// Colouring every figure and colouring only the alarming one differ in what
    /// the strip does below the threshold, which is the renderer's business.
    /// Neither is a reason for this function to answer differently: it is asked
    /// for the alarm colour, and there is one alarm.
    @MainActor
    func testTheAlarmColourIsTheSameUnderBothColouredSettings() throws {
        let appearance = settings("menu-bar-tint-both")
        for colour: AppearanceSettings.MenuBarColour in [.alertOnly, .perBar] {
            appearance.menuBarColour = colour
            XCTAssertNil(appearance.menuBarTint(for: 0.84), colour.rawValue)
            assertSameInk(
                try XCTUnwrap(appearance.menuBarTint(for: 0.85)), warning,
                "the tint under \(colour.rawValue)"
            )
        }
    }

    /// Monochrome is a promise about the menu bar and not a preference about
    /// alarms: a tint is what makes AppKit stop treating the image as a template,
    /// so there is no level at which this can hand one back. The strip still says
    /// 100 — it says it in the menu bar's own ink.
    @MainActor
    func testMonochromeRefusesATintAtEveryLevelAndEveryThreshold() {
        let appearance = settings("menu-bar-mono")
        appearance.apply(AppearanceSettings.Snapshot(
            cautionThreshold: 0.40,
            warningThreshold: 0.50,
            menuBarColour: .monochrome
        ))
        for percent in [0, 0.5, 0.85, 0.99, 1, 1.4] {
            XCTAssertNil(
                appearance.menuBarTint(for: percent),
                "a monochrome menu bar took colour at \(percent)"
            )
        }
    }

    // MARK: - Calling, and resolving

    /// The row's call, spelled once: every assertion above is about the first
    /// argument, and the provider accent is only ever the sentinel.
    @MainActor
    private func figure(_ appearance: AppearanceSettings, _ percent: Double) -> Color {
        appearance.figureTint(for: percent, providerAccent: providerSentinel)
    }

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

    private func alpha(_ color: Color, dark: Bool) -> CGFloat? {
        resolve(color, dark: dark)?.alphaComponent
    }

    /// Two colours draw the same thing, in both appearances.
    ///
    /// Both appearances rather than one, because every colour in play here is a
    /// light/dark pair and a comparison made in only one of them would pass for a
    /// ramp that had lost half its palette.
    private func assertSameInk(
        _ actual: Color,
        _ expected: Color,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for dark in [false, true] {
            XCTAssertEqual(
                hex(actual, dark: dark), hex(expected, dark: dark),
                "\(message), on \(dark ? "dark" : "light")",
                file: file, line: line
            )
        }
    }

    private func assertDifferentInk(
        _ actual: Color,
        _ expected: Color,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for dark in [false, true] {
            XCTAssertNotEqual(
                hex(actual, dark: dark), hex(expected, dark: dark),
                "\(message), on \(dark ? "dark" : "light")",
                file: file, line: line
            )
        }
    }
}
