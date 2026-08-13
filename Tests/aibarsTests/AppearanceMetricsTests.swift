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
    AppearanceSettings(store: scratchStore(name, seed: seed))
}

/// The same scratch domain, handed back rather than consumed, for the handful of
/// tests that have to look at what was *written* — which key a value landed
/// under, and whether a second instance reads it back. Split out of `settings`
/// above rather than copied beside it, so there is still exactly one description
/// of what a fresh install's store looks like.
private func scratchStore(_ name: String, seed: [String: Any] = [:]) -> UserDefaults {
    let domain = "dev.aibars.test-scratch.metrics.\(name)"
    // `fatalError`, not `XCTFail` and then `.standard`. Failing the case and then
    // handing back the shared domain still performs the write the guard exists to
    // prevent — and on this file that write goes through `AppearanceSettings`,
    // whose `init` runs `adoptCurrentLook` and empties the appearance namespace
    // of whoever ran the suite. The branch is unreachable: the name is neither
    // empty, `NSGlobalDomain`, nor the current bundle id.
    guard let store = UserDefaults(suiteName: domain) else {
        fatalError("could not open the scratch defaults domain \(domain)")
    }
    store.removePersistentDomain(forName: domain)
    for (key, value) in seed { store.set(value, forKey: key) }
    return store
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
        // The figure is the name's own size and the unit is the figure's. The
        // 15pt figure beside a 13pt name is where "the panel shouts" came from,
        // and the 9pt raised tick beside it was the superscript percent: `92%`
        // is one mono run on one baseline now.
        let expected: [(AppearanceSettings.Density, CGFloat, CGFloat)] = [
            (.compact, 12, 12),
            (.cozy, 13, 13),
            (.comfortable, 14, 14)
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
                metrics.figureSize, 11,
                "\(density.rawValue) at the smallest text scale sank the figure to \(metrics.figureSize)pt"
            )
            XCTAssertGreaterThanOrEqual(
                metrics.unitSize, 11,
                "\(density.rawValue) at the smallest text scale sank the unit to \(metrics.unitSize)pt"
            )
            // The figure is the row's answer, and it is set at the name's own
            // size: its prominence comes from the mono face, the reserved rail
            // and the colour, none of which cost loudness. What must never
            // happen is the floors sinking it *under* the name.
            XCTAssertGreaterThanOrEqual(
                metrics.figureSize, metrics.titleSize,
                "\(density.rawValue) drew the figure smaller than the service name"
            )
        }
    }

    /// The three heights the row reserves for a trace, and the one relation that
    /// keeps it an annotation rather than a second meter.
    ///
    /// Written as literals because `detailSize * 1.6` is a multiplier chosen to
    /// land on exactly these three: 10 × 1.6 = 16, 11 × 1.6 = 17.6 → 18,
    /// 12 × 1.6 = 19.2 → 19. A multiplier nudged to 1.5 gives 15 / 17 / 18 and
    /// nothing in the app would notice, which is why the arithmetic is recorded
    /// here rather than left to be re-derived.
    @MainActor
    func testTheSparklineHeightIsThreeDistinctBoxesUnderTheirOwnRings() {
        let expected: [(AppearanceSettings.Density, CGFloat)] = [
            (.compact, 16),
            (.cozy, 18),
            (.comfortable, 19)
        ]
        let appearance = settings("sparkline-height")
        appearance.textScale = 1.0
        for (density, height) in expected {
            appearance.density = density
            let metrics = appearance.metrics
            XCTAssertEqual(
                metrics.sparklineHeight, height,
                "\(density.rawValue) draws its trace at \(metrics.sparklineHeight)pt, not \(height)"
            )
            // The trace annotates the meter, so it must not out-measure it. The
            // rings at the shipped scale are 18 / 22 / 26.
            XCTAssertLessThan(
                metrics.sparklineHeight, metrics.ringDiameter,
                "\(density.rawValue) reserves more height for the trace than for the dial it sits under"
            )
        }
    }

    /// The floor is for a `Metrics` built by hand — a test, a preview — because
    /// `detailSize` itself floors at 10 and 10 × 1.6 is already 16.
    func testTheSparklineFloorOnlyBindsForAHandBuiltMetrics() {
        let metrics = AppearanceSettings.Metrics(
            rowVerticalPadding: 0, rowHorizontalPadding: 0, rowGap: 0, contentSpacing: 0,
            titleSize: 6, detailSize: 6, captionSize: 6,
            barHeight: 1, secondaryBarHeight: 1, ringDiameter: 1
        )
        // 6 × 1.6 = 9.6 → 10, which is under the floor.
        XCTAssertEqual(metrics.sparklineHeight, 12, "a hand-built Metrics produced a trace nothing can be read off")
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
        XCTAssertEqual(appearance.metrics.secondaryRail, 29, "the secondary rail is not 29pt at cozy")
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

    /// The three settings this pass added, from their defaults through `apply`
    /// and `snapshot` and out the other side of a relaunch.
    ///
    /// One test rather than three, because the failure they share is the one that
    /// matters: a field added to `Snapshot` but missed in `apply`, `snapshot`,
    /// `Key` or `persistAll` is invisible until a user changes it and it does not
    /// stick. `matchingPreset` is plain equality over every field, so a missed
    /// field also silently unnames every preset — which is why the assertion at
    /// the end is that the reloaded snapshot equals the applied one exactly,
    /// rather than that the three fields happen to agree.
    @MainActor
    func testTheThreeNewSettingsSurviveApplySnapshotAndARelaunch() {
        let store = scratchStore("new-settings")
        let appearance = AppearanceSettings(store: store)
        XCTAssertTrue(appearance.coloursBrandMarks, "a fresh install does not carry brand hue on its live marks")
        XCTAssertFalse(appearance.showsRowSparkline, "a fresh install reserves a trace slot on every connected row")
        XCTAssertEqual(appearance.menuBarStyle, .markAndFigure, "a fresh install draws something other than mark plus figure")

        appearance.apply(AppearanceSettings.Snapshot(
            coloursBrandMarks: false,
            showsRowSparkline: true,
            menuBarStyle: .worstOnly
        ))
        XCTAssertFalse(appearance.coloursBrandMarks, "apply did not carry coloursBrandMarks")
        XCTAssertTrue(appearance.showsRowSparkline, "apply did not carry showsRowSparkline")
        XCTAssertEqual(appearance.menuBarStyle, .worstOnly, "apply did not carry menuBarStyle")
        XCTAssertFalse(appearance.snapshot.coloursBrandMarks, "snapshot did not read coloursBrandMarks back")
        XCTAssertTrue(appearance.snapshot.showsRowSparkline, "snapshot did not read showsRowSparkline back")
        XCTAssertEqual(appearance.snapshot.menuBarStyle, .worstOnly, "snapshot did not read menuBarStyle back")

        let reloaded = AppearanceSettings(store: store)
        XCTAssertEqual(
            reloaded.snapshot, appearance.snapshot,
            """
            A setting did not survive a relaunch. One of the three new fields is missing \
            from Key, persistAll, or the read in init — the value was held in memory and \
            never written, or written and never read.
            """
        )
    }

    /// THE FLIP. This replaces the interim pin that stood here — the one that
    /// asserted every preset still named `coloursBrandMarks: true`,
    /// `showsRowSparkline: false` and `.markAndFigure`, and said in its own doc
    /// that it existed to be rewritten by the pass that shipped those drawings.
    /// The styles and the trace exist, so this is that pass and this is the
    /// rewrite: the same three fields, asserted at the values the presets were
    /// always going to take.
    ///
    /// Spelled preset by preset rather than looped, because what is pinned is a
    /// promise per preset and a loop over all five could only say that some flip
    /// happened somewhere. Each of the three is a summary made true: Monochrome
    /// says greyscale marks and colour only above the warning, Minimal says a name
    /// and a number, Dashboard says every window and every account.
    ///
    /// The two that stay conservative are asserted in the same test and not left
    /// out of it, because a flip applied too widely is exactly as wrong as one
    /// applied by halves. Comfortable is the shipped configuration — moving it
    /// moves what a fresh install looks like — and Compact's whole claim is every
    /// service on screen at once, which is the first claim a reserved trace on
    /// every row spends.
    @MainActor
    func testTheThreePresetsThatWereWaitingNameTheirDrawingNow() {
        // Marks in grey, silhouettes in the bar, and the one colour this preset
        // spends kept for the warning. `.monochrome` would have left the strip
        // with identity and no reading at all, because under `.markOnly` the mark
        // *is* the reading.
        let monochrome = AppearanceSettings.Preset.monochrome.snapshot
        XCTAssertFalse(monochrome.coloursBrandMarks, "Monochrome still carries brand hue on its live marks")
        XCTAssertEqual(monochrome.menuBarStyle, .markOnly, "Monochrome still draws figures in the bar")
        XCTAssertEqual(
            monochrome.menuBarColour, .alertOnly,
            "Monochrome draws marks that carry their reading as a tint, with the tint switched off"
        )

        // One service and no mark. The count was already one, sized for this.
        let minimal = AppearanceSettings.Preset.minimal.snapshot
        XCTAssertEqual(minimal.menuBarStyle, .figureOnly, "Minimal still draws a mark it never wanted")
        XCTAssertEqual(
            minimal.menuBarServiceCount, 1,
            "Minimal asks for more services than `.figureOnly` will draw, so the stepper it disables would be lying about the stored value"
        )

        XCTAssertTrue(
            AppearanceSettings.Preset.dashboard.snapshot.showsRowSparkline,
            "Dashboard is the preset for someone who wants everything and it has no trace"
        )

        // And the two that were never waiting on anything.
        for preset in [AppearanceSettings.Preset.comfortable, .compact] {
            let snapshot = preset.snapshot
            XCTAssertTrue(snapshot.coloursBrandMarks, "\(preset.id) took Monochrome's flip")
            XCTAssertFalse(snapshot.showsRowSparkline, "\(preset.id) took Dashboard's flip")
            XCTAssertEqual(snapshot.menuBarStyle, .markAndFigure, "\(preset.id) took a style that is not its own")
        }
    }

    /// The flip, through the store and back, per preset.
    ///
    /// `testMatchingPresetRecognisesEachPresetExactly` above covers the same
    /// ground for all five at once and is the general form; this is the specific
    /// one, and it exists because the three flipped fields are the three that
    /// arrived last. A field added to `Snapshot` and to `Preset.snapshot` but
    /// missed in `apply`, `snapshot`, `Key` or `persistAll` unnames its preset
    /// silently — the pane opens on Custom, every chip reads as a change away from
    /// the state the user is already in, and the only visible symptom is a chip
    /// that is not highlighted.
    ///
    /// Named fields rather than snapshot equality, so a failure says which of the
    /// three did not survive rather than that thirty-two of them did not match.
    @MainActor
    func testTheFlippedFieldsSurviveApplyAndARelaunchPerPreset() {
        for preset in AppearanceSettings.Preset.allCases {
            let domain = "aibars.metrics-tests.flip.\(preset.rawValue)"
            guard let store = UserDefaults(suiteName: domain) else {
                XCTFail("could not open a scratch defaults domain")
                return
            }
            store.removePersistentDomain(forName: domain)
            AppearanceSettings(store: store).apply(preset)

            let reloaded = AppearanceSettings(store: store)
            XCTAssertEqual(
                reloaded.coloursBrandMarks, preset.snapshot.coloursBrandMarks,
                "\(preset.id) did not get its brand-mark switch back"
            )
            XCTAssertEqual(
                reloaded.showsRowSparkline, preset.snapshot.showsRowSparkline,
                "\(preset.id) did not get its trace back"
            )
            XCTAssertEqual(
                reloaded.menuBarStyle, preset.snapshot.menuBarStyle,
                "\(preset.id) did not get its strip style back"
            )
            XCTAssertEqual(
                reloaded.matchingPreset, preset,
                "\(preset.id) no longer names itself after a relaunch"
            )
        }
    }

    /// A preset may only name a strip style whose own ceiling can carry the count
    /// it asks for, because the pane greys the stepper out at a ceiling of one and
    /// a greyed stepper showing 3 while the bar draws 1 is a control lying about
    /// the value behind it.
    ///
    /// Against `segmentCeiling` and not against a list of the two styles that
    /// currently have one, so a seventh style that speaks for a single service is
    /// covered the day it is added.
    @MainActor
    func testNoPresetAsksAStyleForMoreServicesThanItWillDraw() {
        for preset in AppearanceSettings.Preset.allCases {
            let snapshot = preset.snapshot
            let ceiling = StripStyleBox.box(for: snapshot.menuBarStyle).segmentCeiling
            XCTAssertLessThanOrEqual(
                snapshot.menuBarServiceCount, ceiling,
                "\(preset.id) asks \(snapshot.menuBarStyle.label) for \(snapshot.menuBarServiceCount) services and it draws at most \(ceiling)"
            )
        }
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
    ///
    /// One is the case worth having, and the six above is the case that hid the
    /// bug: six clamps to three, three is also the default, so the six-bar
    /// assertion passes whether the carry-over ran or was never reached. A stored
    /// one has to survive as one, and can only come from the legacy key.
    ///
    /// What this cannot see, stated so nobody reads more into a green tick than
    /// is there: `adoptCurrentLook` — which used to delete this key before `init`
    /// could read it — returns early for every store except
    /// `UserDefaults.standard`, so the scratch domain here never runs the wipe.
    /// This pins the carry-over arithmetic; `Key.survivesLookAdoption` is what
    /// makes the arithmetic reachable on a real install, and touching the user's
    /// own domain to prove it is not a trade a test suite gets to make.
    @MainActor
    func testAStoredBarCountCarriesOver() {
        let many = settings("bar-count-six", seed: ["aibars.appearance.menuBarBarCount": 6])
        XCTAssertEqual(many.menuBarServiceCount, 3)

        let one = settings("bar-count-one", seed: ["aibars.appearance.menuBarBarCount": 1])
        XCTAssertEqual(
            one.menuBarServiceCount, 1,
            """
            A user who had asked for one bar was given three services. The stored count \
            reached neither the read in init nor the carry-over in migrateLegacyKeys, so \
            the fallback to the default of 3 is what answered.
            """
        )
    }

    /// "name" was icon plus rotating service names, which the per-service marks
    /// replace. It must land on the default rather than on whichever case happens
    /// to be first.
    ///
    /// It doubles as the read half of the key pin: the seed is written under
    /// `aibars.appearance.menuBarLabel`, which is where the style still lives
    /// after the property was renamed to `menuBarStyle`.
    @MainActor
    func testAStoredRotatingNameStyleBecomesMarkPlusFigure() {
        let appearance = settings("label-name", seed: ["aibars.appearance.menuBarLabel": "name"])
        XCTAssertEqual(appearance.menuBarStyle, .markAndFigure)
        XCTAssertEqual(appearance.menuBarStyle.rawValue, "percent")
    }

    /// The six strings a strip style is filed under.
    ///
    /// Spelled as literals rather than derived from the cases, because the whole
    /// point of these six is that three of them do *not* follow their case names:
    /// `.markAndFigure` is stored as `"percent"`, `.figureOnly` as
    /// `"percentOnly"` and `.markOnly` as `"icon"`, which are the spellings the
    /// setting shipped with. A rename that tidied a raw value to match its case
    /// would read, on the next launch, as a preference that no longer parses —
    /// and a preference that no longer parses lands the user silently on the
    /// default with no way to tell it happened.
    @MainActor
    func testTheSixPersistedStyleSpellingsArePinned() {
        XCTAssertEqual(AppearanceSettings.MenuBarStyle.markAndFigure.rawValue, "percent")
        XCTAssertEqual(AppearanceSettings.MenuBarStyle.figureOnly.rawValue, "percentOnly")
        XCTAssertEqual(AppearanceSettings.MenuBarStyle.markOnly.rawValue, "icon")
        XCTAssertEqual(AppearanceSettings.MenuBarStyle.microBars.rawValue, "bars")
        XCTAssertEqual(AppearanceSettings.MenuBarStyle.markAndMeter.rawValue, "markBar")
        XCTAssertEqual(AppearanceSettings.MenuBarStyle.worstOnly.rawValue, "worst")
        XCTAssertEqual(
            AppearanceSettings.MenuBarStyle.allCases.count, 6,
            "the style chooser draws a chip per case, and the arithmetic in StripFit is written for six"
        )
    }

    /// And the key the six are written under, which is the one the property no
    /// longer shares a name with.
    ///
    /// Both directions, because the two halves fail differently: a write under a
    /// tidied key strands the value the *next* launch reads, and a read from a
    /// tidied key ignores the value that is already there. Either one is a
    /// preference dropped, and neither shows up in a screenshot.
    @MainActor
    func testTheStyleIsStillFiledUnderTheLabelKey() {
        let store = scratchStore("style-key")
        let appearance = AppearanceSettings(store: store)
        appearance.menuBarStyle = .microBars
        XCTAssertEqual(
            store.string(forKey: "aibars.appearance.menuBarLabel"), "bars",
            "the style was written somewhere other than the key it has always been stored under"
        )

        let stored = settings("style-stored", seed: ["aibars.appearance.menuBarLabel": "icon"])
        XCTAssertEqual(
            stored.menuBarStyle, .markOnly,
            "an install that had chosen Marks only did not get Marks only back"
        )
    }

    /// A half-point strip height is whole by the time anything can draw with it.
    ///
    /// The tuner used to offer half steps and the rasteriser passes the height it
    /// is handed straight into `NSImage(size:)`, so a stored 13.5 renders soft at
    /// 1× for ever. Rounding on read is the half of the fix that reaches an
    /// install which already has one in its store.
    ///
    /// The clamp's bounds are whole, so rounding cannot push a value out of range
    /// — 9.6 rounds to 10 and 16.4 to 16, both of which are already in it. The
    /// two half-point cases are the ones the slider could actually mint.
    @MainActor
    func testAHalfPointStripHeightIsWholeByTheTimeAnythingReadsIt() {
        let cases: [(stored: Double, expected: Double)] = [
            (12.5, 13),
            (13.5, 14),
            (10.4, 10),
            (9.6, 10),
            (16.4, 16),
            (17.5, 16)
        ]
        for (stored, expected) in cases {
            let appearance = settings(
                "glyph-height-\(stored)",
                seed: ["aibars.appearance.menuBarGlyphHeight": stored]
            )
            XCTAssertEqual(
                appearance.menuBarGlyphHeight, expected,
                "a stored \(stored) came back as \(appearance.menuBarGlyphHeight) rather than \(expected)"
            )
        }
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
    private let caution = UsageTint.color(for: 0.80)
    private let warning = UsageTint.color(for: 0.95)

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
        XCTAssertEqual(appearance.cautionThreshold, 0.80, "the fixtures below are written against the shipped pair")
        XCTAssertEqual(appearance.warningThreshold, 0.95)

        for percent in [-0.5, 0, 0.01, 0.25, 0.5, 0.79] {
            assertSameInk(
                figure(appearance, percent), Tokens.Ink.body,
                "a figure at \(percent) took colour while the row was still healthy"
            )
        }

        let coloured: [(Double, Color)] = [
            (0.80, caution),
            (0.90, caution),
            (0.94, caution),
            (0.95, warning),
            (0.99, warning),
            (1, warning),
            (1.4, warning)
        ]
        for (percent, expected) in coloured {
            assertSameInk(figure(appearance, percent), expected, "the figure at \(percent)")
            assertDifferentInk(figure(appearance, percent), Tokens.Ink.body, "the figure at \(percent) stayed neutral")
        }

        // The resting stop is the meter's colour at these levels and never the
        // figure's. It is grey now rather than teal, so the two are a step apart
        // rather than a hue apart — which is the whole of what makes a healthy
        // row carry no colour at all.
        assertDifferentInk(figure(appearance, 0.1), resting, "a healthy figure took the meter's resting grey")
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
        assertSameInk(
            figure(appearance, boundary.nextDown), Tokens.Ink.body,
            "the float below the caution threshold took colour"
        )
    }

    /// And the boundary is the setting, not the 0.80 the palette happens to
    /// change colour at. These two numbers are equal on a fresh install and that
    /// is the only reason a hardcoded 0.80 would pass the test above.
    @MainActor
    func testTheNeutralBandFollowsTheSettingRatherThanThePalette() {
        let appearance = settings("figure-moved")
        appearance.apply(AppearanceSettings.Snapshot(
            colorRamp: .usage,
            cautionThreshold: 0.40,
            warningThreshold: 0.85
        ))
        XCTAssertEqual(appearance.cautionThreshold, 0.40, accuracy: 0.0001)

        assertSameInk(figure(appearance, 0.39), Tokens.Ink.body, "a figure below the user's caution threshold")
        assertSameInk(figure(appearance, 0.40), caution, "the figure at the user's caution threshold")
        // 0.50 is the resting grey in the palette's own fixed bands and caution
        // under this user's settings. The figure follows the user.
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
        assertDifferentInk(figure(appearance, 0.1), Tokens.Ink.body, "the accent ramp went neutral")

        appearance.colorRamp = .provider
        assertSameInk(figure(appearance, 0.1), providerSentinel, "the provider ramp below caution")
        assertDifferentInk(figure(appearance, 0.1), Tokens.Ink.body, "the provider ramp went neutral")
    }

    /// Monochrome is the one ramp whose coloured column *is* the panel's quiet
    /// ink, right up to the warning — and then it is not. A monochrome panel is a
    /// preference; a panel that hides an imminent cutoff is a bug, so `tint` gives
    /// the ramp up at `warningThreshold` and the figure follows it there rather
    /// than inventing a rule of its own.
    ///
    /// `Ink.muted` and not `Color.primary`: on a near-black ground primary
    /// resolves to pure white, which made a monochrome column the loudest thing
    /// on a panel whose whole premise is that it has no colour on it.
    ///
    /// The opacity floor is asserted on both sides of the warning because both
    /// sides are figures being read: a washed-out number is a number that has been
    /// dimmed, and nothing in these settings asks for that. Every ink here is
    /// opaque, which is the point of them being inks rather than opacities.
    @MainActor
    func testMonochromeKeepsTheLabelColourUntilTheWarningAndGivesItUpThere() throws {
        let appearance = settings("figure-mono")
        appearance.colorRamp = .mono

        for percent in [0, 0.1, 0.59, 0.80, 0.94] {
            assertSameInk(
                figure(appearance, percent), Tokens.Ink.muted,
                "the monochrome figure at \(percent) is not the panel's quiet ink"
            )
        }
        for percent in [0.95, 0.99, 1] {
            assertSameInk(figure(appearance, percent), warning, "the monochrome figure at \(percent)")
            assertDifferentInk(
                figure(appearance, percent), Tokens.Ink.muted,
                "monochrome held its own preference over an imminent cutoff at \(percent)"
            )
        }

        for percent in [0, 0.80, 0.95, 1] {
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
                    assertDifferentInk(
                        figure(appearance, percent), Tokens.Ink.body,
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
    /// genuinely below the caution threshold, so the figure is the body ink while
    /// the meter is the resting grey — which is the D3 rule doing its job, not the
    /// panel contradicting itself.
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
                assertDifferentInk(
                    figure(appearance, percent), Tokens.Ink.body,
                    "\(ramp.rawValue) drew an unreadable \(percent) as a healthy figure"
                )
            }
        }

        appearance.colorRamp = .usage
        assertSameInk(figure(appearance, .nan), warning, "a NaN under the usage ramp")
        assertSameInk(figure(appearance, -.infinity), Tokens.Ink.body, "a reading below zero is a quiet row")
    }

    // MARK: - The menu bar tint

    /// The threshold the strip goes colourful at is the user's, not the 0.95 the
    /// palette changes band at. Asserted in both directions, because a hardcoded
    /// 0.95 is wrong twice over: it withholds the colour from a user who wanted
    /// warning at 0.60, and spends it on one who left it where it ships.
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
            XCTAssertNil(appearance.menuBarTint(for: 0.94), colour.rawValue)
            assertSameInk(
                try XCTUnwrap(appearance.menuBarTint(for: 0.95)), warning,
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

    // MARK: - The mark's ink

    /// The first branch, and the one the old arrangement got wrong everywhere but
    /// the panel: a mark that is not reporting is the muted ink, whatever else is
    /// set. Loading, failed, expired, locked, not connected, switched off — all
    /// one state, drawn in the ink the row's own name and caption take beside it.
    ///
    /// Every ramp and both switch positions, because the point of this branch is
    /// that nothing above it can reach it. A brand hue that survived into a
    /// signed-out row would put the loudest treatment on the row with the least
    /// to say.
    @MainActor
    func testAMarkThatIsNotReportingIsTheMutedInkUnderEverySetting() {
        let appearance = settings("mark-ink-muted")
        for ramp in AppearanceSettings.ColorRamp.allCases {
            appearance.colorRamp = ramp
            for colours in [true, false] {
                appearance.coloursBrandMarks = colours
                for serviceID in ["claude", "gemini", "chatgpt", "there-is-no-such-service"] {
                    assertSameInk(
                        appearance.markInk(for: serviceID, isLive: false), Tokens.Ink.muted,
                        "\(serviceID) under \(ramp.rawValue) with colour \(colours ? "on" : "off"), not reporting"
                    )
                }
            }
        }
    }

    /// The third branch and the two things that suppress it.
    ///
    /// The switch is the user's. `.provider` is the double-up rule: under that
    /// ramp the meter and the figure are already painted the brand, so a brand
    /// mark would make three shades of one hue out of a single row — a fully
    /// coloured row, which is what "chroma means measurement or state" exists to
    /// prevent. The meter wins because the meter is the thing the ramp was
    /// switched to colour.
    @MainActor
    func testALiveMarkCarriesTheBrandsHueUntilSomethingSuppressesIt() throws {
        let appearance = settings("mark-ink-live")
        let claude = try XCTUnwrap(BrandMark.mark(for: "claude"), "the fixture brand has no mark")

        appearance.colorRamp = .usage
        assertSameInk(appearance.markInk(for: "claude", isLive: true), claude.liveInk, "a live Claude under .usage")
        assertDifferentInk(
            appearance.markInk(for: "claude", isLive: true), Tokens.Ink.mark,
            "a live Claude drew the neutral mark ink with nothing suppressing its hue"
        )

        appearance.coloursBrandMarks = false
        assertSameInk(
            appearance.markInk(for: "claude", isLive: true), Tokens.Ink.mark,
            "the switch is off and the mark kept its hue"
        )

        appearance.coloursBrandMarks = true
        appearance.colorRamp = .provider
        assertSameInk(
            appearance.markInk(for: "claude", isLive: true), Tokens.Ink.mark,
            "the meter is already painted the brand and the mark took it a second time"
        )

        // The other three ramps spend no brand hue on the meter, so the mark is
        // free to carry it.
        for ramp: AppearanceSettings.ColorRamp in [.usage, .accent, .mono] {
            appearance.colorRamp = ramp
            assertSameInk(
                appearance.markInk(for: "claude", isLive: true), claude.liveInk,
                "a live Claude under \(ramp.rawValue)"
            )
        }
    }

    /// A brand with no hue is the general rule evaluated at zero chroma, and at
    /// zero chroma the live band's lightness *is* `Ink.mark` — so the seven
    /// achromatic brands draw exactly what they drew before this rule existed. A
    /// service with no mark at all has no hue to lend and lands in the same
    /// place, rather than on the user's accent.
    @MainActor
    func testABrandWithNoHueAndAServiceWithNoMarkBothLandOnTheMarkInk() {
        let appearance = settings("mark-ink-achromatic")
        assertSameInk(
            appearance.markInk(for: "chatgpt", isLive: true), Tokens.Ink.mark,
            "an achromatic brand's live ink is not the mark ink"
        )
        assertSameInk(
            appearance.markInk(for: "there-is-no-such-service", isLive: true), Tokens.Ink.mark,
            "a service with no vector mark was given a colour to draw its lettermark in"
        )
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
