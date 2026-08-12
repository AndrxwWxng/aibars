import XCTest
import SwiftUI
@testable import aibarsCore

/// The row's arithmetic, asserted rather than eyeballed.
///
/// `MenuBarExtra` sizes its window to the height its content reports, so a row
/// that answers a different height once a quota lands resizes the panel under
/// the pointer. `RowGeometry` is given no content at all, which makes that
/// invariant structural — and these tests are what keep it structural, because
/// the way it gets lost is somebody adding a parameter that happens to be a
/// reading.
///
/// The height cases are written twice on purpose: once as a literal, and once
/// as the sum of `Tokens.lineBox` and the named gaps it is actually built from.
/// A literal alone accepts any new total silently; a sum alone accepts a gap
/// being renamed into a different gap of the same value. Both together fail
/// loudly, which is the point.
final class RowGeometryTests: XCTestCase {

    /// A scratch domain per test, so one test's writes cannot decide another's
    /// starting state.
    @MainActor
    private func settings(_ name: String, seed: [String: Any] = [:]) -> AppearanceSettings {
        let domain = "aibars.row-geometry-tests.\(name)"
        guard let store = UserDefaults(suiteName: domain) else {
            XCTFail("could not open a scratch defaults domain")
            return AppearanceSettings(store: .standard)
        }
        store.removePersistentDomain(forName: domain)
        for (key, value) in seed { store.set(value, forKey: key) }
        return AppearanceSettings(store: store)
    }

    /// The panel builds one of these per row out of the settings it is drawing
    /// under. Spelled here so a test says which *setting* it is varying rather
    /// than which of seven arguments.
    @MainActor
    private func geometry(
        _ appearance: AppearanceSettings,
        lines: RowGeometry.Lines
    ) -> RowGeometry {
        RowGeometry(
            metrics: appearance.metrics,
            showsPercentage: appearance.showsPercentage,
            meterStyle: appearance.meterStyle,
            logoStyle: appearance.logoStyle,
            logoSize: CGFloat(appearance.logoSize),
            panelWidth: CGFloat(appearance.panelWidth),
            lines: lines
        )
    }

    /// The title line, reproduced from its three claimants rather than from the
    /// number it currently comes to. It is held at the action buttons' height,
    /// which is taller than either type size at every density — so this is 18
    /// everywhere today, and it is written as the `max` so that a change to any
    /// one of the three moves every height case with it.
    private func titleLine(_ metrics: AppearanceSettings.Metrics) -> CGFloat {
        max(
            Tokens.lineBox(metrics.titleSize),
            max(Tokens.lineBox(metrics.figureSize), Tokens.Control.rowIconButton)
        )
    }

    /// The leading column's height: the taller of the logo and the dial, plus
    /// the 1pt nudge onto the title's cap-height band.
    /// The leading column's height. No nudge: the mark box and the title box are
    /// the same 18pt at the defaults, and the 1pt lift onto a band the mark was
    /// already on was written into both `RowGeometry` and `ProviderRow` — a 1pt
    /// lie told in two files, and 1pt of reserved height per row that nothing
    /// drew.
    private func leadingLine(logo: CGFloat, ring: CGFloat) -> CGFloat {
        max(logo, ring)
    }

    /// Metrics built by hand, for the cases that have to reach a value no
    /// density can produce. Cozy at 100% unless a case says otherwise, so a
    /// test that overrides one length is varying exactly that length.
    private func handBuilt(
        rowVerticalPadding: CGFloat = 10,
        contentSpacing: CGFloat = 6,
        titleSize: CGFloat = 13,
        detailSize: CGFloat = 11,
        captionSize: CGFloat = 10,
        barHeight: CGFloat = 5,
        ringDiameter: CGFloat = 22
    ) -> AppearanceSettings.Metrics {
        AppearanceSettings.Metrics(
            rowVerticalPadding: rowVerticalPadding,
            rowHorizontalPadding: Tokens.Space.gutter,
            rowGap: 2,
            contentSpacing: contentSpacing,
            titleSize: titleSize,
            detailSize: detailSize,
            captionSize: captionSize,
            barHeight: barHeight,
            secondaryBarHeight: 3,
            ringDiameter: ringDiameter
        )
    }

    // MARK: - The height ladder

    /// The shipped configuration, drawing everything a row can draw.
    @MainActor
    func testCozyBarFiveWithMeterWindowAndForecast() {
        let appearance = settings("cozy-full")
        appearance.density = .cozy
        appearance.textScale = 1.0
        appearance.meterThickness = 5
        let metrics = appearance.metrics
        XCTAssertEqual(metrics.barHeight, 5, "the bar is not the 5pt this case is named for")

        let expected = titleLine(metrics)
            + metrics.contentSpacing
            + metrics.barHeight
            + metrics.captionGap
            + Tokens.lineBox(metrics.detailSize)
            + metrics.contentSpacing
            + Tokens.lineBox(metrics.captionSize)
            + 2 * metrics.rowVerticalPadding

        let row = geometry(appearance, lines: [.meter, .window, .forecast])
        XCTAssertEqual(row.height, expected, "the height stopped matching the terms it is built from")
        // 18 title + 6 spacing + 5 bar + 3 caption gap + 14 window
        //    + 6 spacing + 13 forecast + 20 padding.
        XCTAssertEqual(row.height, 85, "the shipped three-line row is \(row.height)pt, not 85")
    }

    /// Dropping the pace line drops it and the pitch that separated it, and
    /// nothing else.
    @MainActor
    func testDroppingTheForecastDropsExactlyItsOwnBlock() {
        let appearance = settings("cozy-no-forecast")
        appearance.density = .cozy
        appearance.textScale = 1.0
        appearance.meterThickness = 5
        let metrics = appearance.metrics

        let full = geometry(appearance, lines: [.meter, .window, .forecast])
        let row = geometry(appearance, lines: [.meter, .window])

        XCTAssertEqual(
            row.height,
            full.height - metrics.contentSpacing - Tokens.lineBox(metrics.captionSize),
            "dropping the forecast moved something other than the forecast"
        )
        XCTAssertEqual(row.height, 66, "the two-line row is \(row.height)pt, not 66")
    }

    /// Dropping the countdown as well takes the caption gap with it: the gap
    /// exists only between a meter and the line under it, so a meter on its own
    /// must not keep paying for one.
    ///
    /// And at this height the row stops being sized by its text at all — a 30pt
    /// logo is taller than a title line and a bar together, so the leading column
    /// becomes the floor. That is the honest total, and the term-by-term line
    /// below says which of the two won.
    @MainActor
    func testDroppingTheCountdownLeavesTheLeadingColumnHoldingTheRow() {
        let appearance = settings("cozy-meter-only")
        appearance.density = .cozy
        appearance.textScale = 1.0
        appearance.meterThickness = 5
        appearance.logoStyle = .tile
        appearance.logoSize = 30
        let metrics = appearance.metrics

        let text = titleLine(metrics) + metrics.contentSpacing + metrics.barHeight
        let leading = leadingLine(logo: 30, ring: 0)
        XCTAssertGreaterThan(leading, text, "this case is only interesting while the logo is the taller one")

        let row = geometry(appearance, lines: [.meter])
        XCTAssertEqual(row.height, max(leading, text) + 2 * metrics.rowVerticalPadding)
        // 30 leading column, since 18 + 6 + 5 of text does not reach it, + 20 padding.
        XCTAssertEqual(row.height, 50, "the meter-only row is \(row.height)pt, not 50")
    }

    /// The same row with the mark switched off, which is the pure text stack
    /// with nothing propping it up.
    @MainActor
    func testWithNoLeadingColumnTheTextStackIsTheWholeHeight() {
        let appearance = settings("cozy-meter-only-no-logo")
        appearance.density = .cozy
        appearance.textScale = 1.0
        appearance.meterThickness = 5
        appearance.logoStyle = .hidden
        let metrics = appearance.metrics

        let row = geometry(appearance, lines: [.meter])
        XCTAssertEqual(
            row.height,
            titleLine(metrics) + metrics.contentSpacing + metrics.barHeight + 2 * metrics.rowVerticalPadding
        )
        XCTAssertEqual(row.height, 49, "the meter-only row without a mark is \(row.height)pt, not 49")
    }

    /// The dense end: a 4pt bar, no pace line, and a caption gap that has hit
    /// its own floor of 2 rather than following `contentSpacing / 2` down to 1.
    @MainActor
    func testCompactBarFourWithoutAForecast() {
        let appearance = settings("compact")
        appearance.density = .compact
        appearance.textScale = 1.0
        appearance.meterThickness = 4
        let metrics = appearance.metrics
        XCTAssertEqual(metrics.barHeight, 4)
        XCTAssertEqual(metrics.captionGap, 2, "compact's caption gap is off its floor")

        let expected = titleLine(metrics)
            + metrics.contentSpacing
            + metrics.barHeight
            + metrics.captionGap
            + Tokens.lineBox(metrics.detailSize)
            + 2 * metrics.rowVerticalPadding

        let row = geometry(appearance, lines: [.meter, .window])
        XCTAssertEqual(row.height, expected)
        // 18 title + 4 spacing + 4 bar + 2 caption gap + 13 window + 12 padding.
        XCTAssertEqual(row.height, 53, "the compact two-line row is \(row.height)pt, not 53")
    }

    /// Under the ring the dial *is* the meter, and it is already paid for in the
    /// leading column. Charging the text column for it again would push every
    /// row of a ring panel down by a bar height that is never drawn.
    @MainActor
    func testTheRingDoesNotAlsoTakeASlotInTheTextColumn() {
        let appearance = settings("ring-meter-slot")
        appearance.meterStyle = .ring
        let withMeter = geometry(appearance, lines: [.meter, .window])
        let withoutMeter = geometry(appearance, lines: [.window])
        XCTAssertEqual(withMeter.height, withoutMeter.height, "the ring row paid for its dial twice")
    }

    // MARK: - Content independence

    /// The invariant the whole type exists for, stated as a type-level fact:
    /// two rows configured the same way and drawing the same lines are the same
    /// value, whole. Not "the same height" — `Equatable` over every stored
    /// measurement, so a rail or a leading column drifting is the same failure.
    ///
    /// Two separate settings objects, in two separate domains, because "the same
    /// expression twice" would prove only that `==` works.
    @MainActor
    func testGeometryIsAPureFunctionOfItsInputs() {
        let one = settings("pure-one")
        let other = settings("pure-other")
        for preset in AppearanceSettings.Preset.allCases {
            one.apply(preset)
            other.apply(preset)
            for lines in Self.allLineSets {
                XCTAssertEqual(
                    geometry(one, lines: lines),
                    geometry(other, lines: lines),
                    "\(preset.id) measured two identical rows differently at \(lines.rawValue)"
                )
            }
        }
    }

    /// The other half of that: a line that is drawn has to cost something, or
    /// "the height is a function of the lines" is true only because the height
    /// ignores them.
    @MainActor
    func testEachLineTheRowDrawsCostsHeight() {
        let appearance = settings("lines-cost")
        appearance.logoStyle = .hidden
        let bare = geometry(appearance, lines: [])
        for lines in [RowGeometry.Lines.meter, .window, .forecast] {
            XCTAssertGreaterThan(
                geometry(appearance, lines: lines).height, bare.height,
                "drawing \(lines.rawValue) cost the row nothing"
            )
        }
        XCTAssertGreaterThan(
            geometry(appearance, lines: [.meter, .window, .forecast]).height,
            geometry(appearance, lines: [.meter, .window]).height
        )
    }

    /// A row still loading draws its meter slot and puts "Loading…" in the
    /// window line; a row with a reading draws a track and a countdown in the
    /// same two boxes. Same lines, so the same rails and the same height — at
    /// every preset, because this is what stops the panel resizing as answers
    /// arrive one provider at a time.
    @MainActor
    func testALoadingRowAndAnAnsweredRowMeasureTheSame() {
        let appearance = settings("loading")
        for preset in AppearanceSettings.Preset.allCases {
            appearance.apply(preset)
            let loading = geometry(appearance, lines: [.meter, .window])
            let answered = geometry(appearance, lines: [.meter, .window])
            XCTAssertEqual(loading, answered, "\(preset.id) measured a loading row differently")
        }
    }

    /// The rails are the panel's column, not the row's: they are the same width
    /// on a row with three digits, a row with one, and a row with none at all.
    @MainActor
    func testTheRailsDoNotDependOnWhichLinesARowDraws() {
        let appearance = settings("rails-per-line")
        let reference = geometry(appearance, lines: [])
        for lines in Self.allLineSets {
            let row = geometry(appearance, lines: lines)
            XCTAssertEqual(row.headlineRail, reference.headlineRail)
            XCTAssertEqual(row.secondaryRail, reference.secondaryRail)
            XCTAssertEqual(row.leadingWidth, reference.leadingWidth)
            XCTAssertEqual(row.textColumnWidth, reference.textColumnWidth)
        }
    }

    // MARK: - The rails

    /// Asserted against the tokens rather than against 35, so a change to the
    /// advance ratio or to the figure multiplier moves the test with it instead
    /// of being caught by it.
    @MainActor
    func testTheHeadlineRailIsThreeDigitsAHairlineAndAUnit() {
        let appearance = settings("headline-rail")
        for density in AppearanceSettings.Density.allCases {
            appearance.density = density
            let metrics = appearance.metrics
            XCTAssertEqual(
                geometry(appearance, lines: [.meter, .window]).headlineRail,
                Tokens.figureWidth(metrics.figureSize, digits: 3)
                    + Tokens.Space.hairline
                    + Tokens.figureWidth(metrics.unitSize, digits: 1),
                "\(density.rawValue) reserves a headline rail that is not three digits, a hairline and a unit"
            )
        }
    }

    /// With percentages off the column closes for the whole panel, so nothing
    /// reserves an empty gutter down the trailing edge.
    @MainActor
    func testPercentagesOffCloseBothRailsForEveryRow() {
        let appearance = settings("no-percentages")
        appearance.showsPercentage = false
        for style in [AppearanceSettings.MeterStyle.bar, .ring] {
            appearance.meterStyle = style
            for lines in Self.allLineSets {
                let row = geometry(appearance, lines: lines)
                XCTAssertEqual(row.headlineRail, 0, "\(style.rawValue) kept a headline rail with percentages off")
                XCTAssertEqual(row.secondaryRail, 0, "\(style.rawValue) kept a secondary rail with percentages off")
            }
        }
    }

    /// The one exception, and it is not a leak: under `numberOnly` the figure is
    /// the meter, so closing its rail would configure the row down to a name
    /// with no usage on it at all.
    @MainActor
    func testNumberOnlyKeepsItsRailWithPercentagesOff() {
        let appearance = settings("number-only")
        appearance.meterStyle = .numberOnly
        appearance.showsPercentage = false
        let row = geometry(appearance, lines: [.meter, .window])
        XCTAssertEqual(row.headlineRail, appearance.metrics.headlineRail)
        XCTAssertEqual(row.secondaryRail, appearance.metrics.secondaryRail)
    }

    // MARK: - The leading column

    @MainActor
    func testNoLogoAndNoDialMeansNoLeadingColumnAtAll() {
        let appearance = settings("leading-none")
        appearance.logoStyle = .hidden
        for style in [AppearanceSettings.MeterStyle.bar, .numberOnly] {
            appearance.meterStyle = style
            let row = geometry(appearance, lines: [.meter, .window])
            XCTAssertEqual(row.leadingWidth, 0, "\(style.rawValue) indented a row with nothing in front of it")
            // The 11pt gap goes with the column: an indent in front of nothing
            // reads as a broken layout rather than as a text list.
            XCTAssertEqual(
                row.textColumnWidth,
                CGFloat(appearance.panelWidth) - 2 * appearance.metrics.rowHorizontalPadding
            )
        }
    }

    /// The dial needs the column even with the mark switched off, because every
    /// row draws one and the text beside it has to start at the same x.
    @MainActor
    func testTheDialKeepsTheColumnWithTheLogoHidden() {
        let appearance = settings("leading-ring-only")
        appearance.logoStyle = .hidden
        appearance.meterStyle = .ring
        let metrics = appearance.metrics
        XCTAssertGreaterThan(metrics.ringDiameter, 0)

        let row = geometry(appearance, lines: [.meter, .window])
        XCTAssertEqual(row.leadingWidth, metrics.ringDiameter + Tokens.Space.leadingColumn)
        XCTAssertGreaterThan(row.leadingWidth, 0)
    }

    /// The inner gap exists only between two things: a mark and a dial pay for
    /// it, a mark on its own does not.
    @MainActor
    func testTheInnerGapAppearsOnlyBetweenAMarkAndADial() {
        let appearance = settings("leading-both")
        appearance.logoStyle = .tile
        appearance.logoSize = 24

        appearance.meterStyle = .bar
        let bar = geometry(appearance, lines: [.meter, .window])
        XCTAssertEqual(bar.leadingWidth, 24 + Tokens.Space.leadingColumn)

        appearance.meterStyle = .ring
        let ring = geometry(appearance, lines: [.meter, .window])
        XCTAssertEqual(
            ring.leadingWidth,
            24 + appearance.metrics.ringDiameter + Tokens.Space.leadingItems + Tokens.Space.leadingColumn
        )
    }

    /// The narrowest panel the settings allow, behind the widest leading column
    /// they allow. If the text column can go to zero here the row has nowhere to
    /// put a service name.
    @MainActor
    func testTheTextColumnSurvivesTheWidestLeadingColumnAtTheNarrowestPanel() {
        let appearance = settings("narrowest")
        appearance.density = .comfortable
        appearance.textScale = 1.30
        appearance.logoStyle = .tile
        appearance.logoSize = 40
        appearance.panelWidth = 300
        appearance.meterStyle = .ring

        let row = geometry(appearance, lines: [.meter, .window, .forecast])
        XCTAssertGreaterThan(row.textColumnWidth, 0, "the widest leading column swallowed the panel")
        // And not merely positive: a name and its figure share this line.
        XCTAssertGreaterThan(
            row.textColumnWidth, row.headlineRail + row.secondaryRail,
            "what is left of a 300pt panel cannot hold both rails"
        )
    }

    // MARK: - The card radius

    /// Eight is right for a tall row and wrong for a short one, whose corners it
    /// eats. Stated as the invariant rather than as two numbers.
    @MainActor
    func testTheCardRadiusIsAlwaysTheClampedRadius() {
        let appearance = settings("radius-invariant")
        for preset in AppearanceSettings.Preset.allCases {
            appearance.apply(preset)
            for lines in Self.allLineSets {
                let row = geometry(appearance, lines: lines)
                XCTAssertEqual(row.cardRadius, min(Tokens.Radius.row, row.height / 3))
                XCTAssertGreaterThan(row.cardRadius, 0)
            }
        }
    }

    /// A comfortable row with all three lines is far past the clamp, so it draws
    /// the full radius.
    @MainActor
    func testATallRowTakesTheFullRadius() {
        let appearance = settings("radius-tall")
        appearance.density = .comfortable
        let row = geometry(appearance, lines: [.meter, .window, .forecast])
        XCTAssertGreaterThan(row.height, 3 * Tokens.Radius.row)
        XCTAssertEqual(row.cardRadius, Tokens.Radius.row)
    }

    /// And a row short enough to be eaten gives the radius back. No density can
    /// produce one this short — the title line alone is held at the action
    /// buttons' 20pt and every density adds padding around it — so the clamp is
    /// exercised with metrics built by hand at zero padding, which is the only
    /// way to reach the branch at all.
    func testAShortRowClampsItsRadiusToAThirdOfItsHeight() {
        let row = RowGeometry(
            metrics: handBuilt(rowVerticalPadding: 0, contentSpacing: 3, titleSize: 11, detailSize: 10, captionSize: 9),
            showsPercentage: true,
            meterStyle: .bar,
            logoStyle: .hidden,
            logoSize: 0,
            panelWidth: 300,
            lines: []
        )
        XCTAssertLessThan(row.height, 3 * Tokens.Radius.row)
        XCTAssertEqual(row.cardRadius, row.height / 3)
        XCTAssertLessThan(row.cardRadius, Tokens.Radius.row)
    }

    // MARK: - Presets

    /// Every shipped look has to produce a row that can be drawn: a positive
    /// height, and a text column with something left in it.
    @MainActor
    func testEveryPresetProducesADrawableRow() {
        let appearance = settings("presets")
        for preset in AppearanceSettings.Preset.allCases {
            appearance.apply(preset)
            for lines in Self.allLineSets {
                let row = geometry(appearance, lines: lines)
                XCTAssertGreaterThan(row.height, 0, "\(preset.id) has a row of no height at \(lines.rawValue)")
                XCTAssertTrue(row.height.isFinite, "\(preset.id) has a non-finite row height")
                XCTAssertGreaterThan(row.textColumnWidth, 0, "\(preset.id) left no text column")
                XCTAssertGreaterThanOrEqual(row.leadingWidth, 0)
                XCTAssertGreaterThanOrEqual(row.headlineRail, 0)
                XCTAssertGreaterThanOrEqual(row.secondaryRail, 0)
            }
        }
    }

    /// Every preset draws figures, so every preset reserves a rail — and the
    /// rail is the one its own metrics name, never a leftover from the last
    /// preset applied.
    @MainActor
    func testEveryPresetReservesItsOwnRails() {
        let appearance = settings("preset-rails")
        for preset in AppearanceSettings.Preset.allCases {
            appearance.apply(preset)
            let row = geometry(appearance, lines: [.meter, .window])
            XCTAssertEqual(row.headlineRail, appearance.metrics.headlineRail, "\(preset.id)")
            XCTAssertEqual(row.secondaryRail, appearance.metrics.secondaryRail, "\(preset.id)")
        }
    }

    // MARK: - chipLimit

    /// A wider line never holds fewer chips. Swept rather than spot-checked,
    /// because the fault this guards against is an off-by-one at one particular
    /// width rather than a wrong slope.
    func testChipLimitIsMonotonicInTheWidthAvailable() {
        for captionSize in [CGFloat(9), 10, 11, 14] {
            var previous = 0
            for width in stride(from: CGFloat(0), through: 600, by: 5) {
                let limit = RowGeometry.chipLimit(textColumnWidth: width, captionSize: captionSize)
                XCTAssertGreaterThanOrEqual(
                    limit, previous,
                    "\(width)pt at caption \(captionSize) held fewer chips than \(width - 5)pt did"
                )
                previous = limit
            }
        }
    }

    /// Never zero and never negative, whatever it is handed. A line of no chips
    /// reports nothing at all about a service with several windows, which is
    /// strictly worse than one chip that can be read.
    func testChipLimitIsNeverLessThanOne() {
        let widths: [CGFloat] = [
            -.greatestFiniteMagnitude, -600, -1, 0, 0.5, 1, 300, 520, 10_000,
            .nan, .infinity, -.infinity
        ]
        for width in widths {
            for captionSize in [CGFloat(-5), 0, .nan, .infinity, 9, 10, 40] {
                let limit = RowGeometry.chipLimit(textColumnWidth: width, captionSize: captionSize)
                XCTAssertGreaterThanOrEqual(
                    limit, 1,
                    "chipLimit(\(width), \(captionSize)) came back with \(limit)"
                )
            }
        }
    }

    /// The boundary itself: one point short of fitting another chip must answer
    /// the lower count, and the gap to the next chip has to be inside the chip's
    /// own width or the division finds room for one more than the line holds.
    ///
    /// The chip's width is private, so it is read off the step from one chip to
    /// two rather than spelled — that keeps this true when the chip's furniture
    /// changes, and it is the second step that has to be measured because the
    /// floor at one chip hides the first.
    func testChipLimitStepsUpOnlyOnceTheChipActuallyFits() throws {
        let captionSize: CGFloat = 10
        var boundary: CGFloat?
        for width in stride(from: CGFloat(1), through: 1000, by: 1)
        where RowGeometry.chipLimit(textColumnWidth: width, captionSize: captionSize) == 2 {
            boundary = width
            break
        }
        // Two chips exactly, so half of it is one chip and its trailing gap.
        let chip = try XCTUnwrap(boundary, "no width under 1000pt ever held a second chip") / 2

        func limit(_ width: CGFloat) -> Int {
            RowGeometry.chipLimit(textColumnWidth: width, captionSize: captionSize)
        }
        // The floor: a line too narrow for even one chip still reports one,
        // because a chip that has to truncate says more than no chip at all.
        XCTAssertEqual(limit(chip - 1), 1)
        for chips in 1...4 {
            let n = CGFloat(chips)
            XCTAssertEqual(limit(n * chip), chips, "\(n * chip)pt did not hold exactly \(chips) chips")
            XCTAssertEqual(
                limit((n + 1) * chip - 1), chips,
                "a point short of \(chips + 1) chips reported more than \(chips)"
            )
        }
    }

    /// A larger caption makes a wider chip, so the same line holds no more of
    /// them. This is the estimate erring generous, which drops a chip rather
    /// than truncating one.
    func testABiggerCaptionNeverFitsMoreChips() {
        for width in stride(from: CGFloat(100), through: 500, by: 50) {
            let small = RowGeometry.chipLimit(textColumnWidth: width, captionSize: 9)
            let large = RowGeometry.chipLimit(textColumnWidth: width, captionSize: 14)
            XCTAssertGreaterThanOrEqual(small, large, "a 14pt caption fitted more chips into \(width)pt than a 9pt one")
        }
    }

    // MARK: - Values that cannot be drawn

    /// `min` and `max` both lose to a NaN, so one reaching a frame width takes
    /// the layout with it. Every length that can arrive as a `Double` from the
    /// settings is guarded, and this is the sweep that says so.
    func testNonFiniteLengthsNeverReachAMeasurement() {
        let poison: [CGFloat] = [.nan, .infinity, -.infinity, -1, -10_000]
        for value in poison {
            for style in AppearanceSettings.MeterStyle.allCases {
                let row = RowGeometry(
                    metrics: handBuilt(barHeight: value, ringDiameter: value),
                    showsPercentage: true,
                    meterStyle: style,
                    logoStyle: .tile,
                    logoSize: value,
                    panelWidth: value,
                    lines: [.meter, .window, .forecast]
                )
                XCTAssertTrue(row.height.isFinite, "\(value) as a length gave a \(row.height)pt row")
                XCTAssertGreaterThan(row.height, 0)
                XCTAssertTrue(row.leadingWidth.isFinite)
                XCTAssertGreaterThanOrEqual(row.leadingWidth, 0)
                XCTAssertGreaterThanOrEqual(row.textColumnWidth, 0)
                XCTAssertTrue(row.cardRadius.isFinite)
            }
        }
    }

    /// A panel narrower than its own gutters, or no panel at all, leaves no text
    /// column — but it must leave a measurable one rather than a negative width,
    /// which SwiftUI treats as unsatisfiable rather than as zero.
    func testAPanelTooNarrowToDrawInLeavesAZeroTextColumn() {
        for width in [CGFloat(0), 1, 10, -50, .nan] {
            let row = RowGeometry(
                metrics: handBuilt(),
                showsPercentage: true,
                meterStyle: .bar,
                logoStyle: .tile,
                logoSize: 30,
                panelWidth: width,
                lines: [.meter, .window]
            )
            XCTAssertGreaterThanOrEqual(row.textColumnWidth, 0, "a \(width)pt panel gave a negative text column")
            XCTAssertTrue(row.textColumnWidth.isFinite)
        }
    }

    /// A poisoned length in the *meter* costs the meter and nothing else: the
    /// caption gap goes with it, because the gap exists only between a meter and
    /// the line under it.
    func testAMeterThatCannotBeDrawnCostsOnlyItsOwnBlock() {
        let broken = handBuilt(barHeight: .nan)
        func row(_ lines: RowGeometry.Lines) -> RowGeometry {
            RowGeometry(
                metrics: broken,
                showsPercentage: true,
                meterStyle: .bar,
                logoStyle: .hidden,
                logoSize: 0,
                panelWidth: 356,
                lines: lines
            )
        }
        XCTAssertEqual(row([.meter, .window]).height, row([.window]).height)
    }

    /// A `Lines` value is an `OptionSet` over an `Int`, so nothing stops a bit
    /// nobody defined from arriving in one. Unknown bits mean nothing and must
    /// not be read as a line.
    @MainActor
    func testUnknownLineBitsDrawNothing() {
        let appearance = settings("line-bits")
        XCTAssertEqual(
            geometry(appearance, lines: RowGeometry.Lines(rawValue: 1 << 9)),
            geometry(appearance, lines: [])
        )
        XCTAssertEqual(
            geometry(appearance, lines: RowGeometry.Lines(rawValue: (1 << 9) | 1)),
            geometry(appearance, lines: [.meter])
        )
        // Every bit set is every line the row knows how to draw, and no more.
        XCTAssertEqual(
            geometry(appearance, lines: RowGeometry.Lines(rawValue: ~0)),
            geometry(appearance, lines: [.meter, .window, .forecast])
        )
    }

    // MARK: - Persisted values are untrusted input

    /// The defaults domain is a file a user can edit and an old build can have
    /// written. A string where a length belongs, a NaN, a text scale forty times
    /// too large — none of them may reach a frame width, and none of them may
    /// stop the row being drawable.
    @MainActor
    func testMalformedStoredSettingsStillMeasureARow() {
        let appearance = settings("malformed", seed: [
            "aibars.appearance.density": "roomy",
            "aibars.appearance.logoSize": "enormous",
            "aibars.appearance.textScale": 47.0,
            "aibars.appearance.meterThickness": Double.nan,
            "aibars.appearance.meterStyle": "dial"
        ])
        // Unreadable cases fall back to their defaults rather than to whichever
        // case happens to be first.
        XCTAssertEqual(appearance.density, .cozy)
        XCTAssertEqual(appearance.meterStyle, .bar)
        XCTAssertEqual(appearance.logoSize, 18)
        // A number out of range is pulled in; a NaN is not a number and is not,
        // which is exactly why RowGeometry guards it rather than trusting it.
        XCTAssertEqual(appearance.textScale, 1.30)
        XCTAssertTrue(appearance.metrics.barHeight.isNaN)

        let row = geometry(appearance, lines: [.meter, .window, .forecast])
        XCTAssertTrue(row.height.isFinite, "a stored NaN reached the row's height")
        XCTAssertGreaterThan(row.height, 0)
        XCTAssertTrue(row.textColumnWidth.isFinite)
        XCTAssertGreaterThan(row.textColumnWidth, 0)
        XCTAssertGreaterThanOrEqual(
            RowGeometry.chipLimit(textColumnWidth: row.textColumnWidth, captionSize: appearance.metrics.captionSize),
            1
        )
    }

    /// A stored panel width that is not a number survives normalisation — `min`
    /// and `max` both pass a NaN through — so the panel is the last thing that
    /// can catch it, and it does.
    @MainActor
    func testAStoredNonNumericPanelWidthCannotBreakTheLayout() {
        let appearance = settings("nan-width", seed: ["aibars.appearance.panelWidth": Double.nan])
        XCTAssertTrue(appearance.panelWidth.isNaN, "normalize now clamps a NaN, and this test is measuring the wrong thing")

        let row = geometry(appearance, lines: [.meter, .window])
        XCTAssertEqual(row.textColumnWidth, 0)
        XCTAssertTrue(row.height.isFinite)
        XCTAssertEqual(RowGeometry.chipLimit(textColumnWidth: row.textColumnWidth, captionSize: 10), 1)
    }

    // MARK: - Fixtures

    /// All eight combinations of the three lines. Every case that sweeps has to
    /// sweep the same set, or two of them disagree about what was covered.
    private static let allLineSets: [RowGeometry.Lines] = [
        [],
        [.meter],
        [.window],
        [.forecast],
        [.meter, .window],
        [.meter, .forecast],
        [.window, .forecast],
        [.meter, .window, .forecast]
    ]
}
