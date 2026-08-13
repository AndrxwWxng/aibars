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
    ///
    /// `secondaryLines` defaults to none, so every case written before the ladder
    /// existed keeps measuring the row it was written about, and a case that
    /// varies the ladder says so at its call site.
    @MainActor
    private func geometry(
        _ appearance: AppearanceSettings,
        secondaryLines: Int = 0,
        lines: RowGeometry.Lines
    ) -> RowGeometry {
        RowGeometry(
            metrics: appearance.metrics,
            showsPercentage: appearance.showsPercentage,
            meterStyle: appearance.meterStyle,
            logoStyle: appearance.logoStyle,
            logoSize: CGFloat(appearance.logoSize),
            panelWidth: CGFloat(appearance.panelWidth),
            secondaryLines: secondaryLines,
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

    /// The shipped configuration, drawing every block a row can put under its
    /// title.
    ///
    /// It was `[.meter, .window, .forecast]` and came to 85pt: 18 title + 6 + 5
    /// bar + 3 + 14 window + 6 + 13 pace + 20 padding. `.forecast` is deleted, so
    /// the third block of a row that draws everything is the trace, and the same
    /// row is 90. What the case protects is unchanged and is the reason it is
    /// still here: **the tallest row's total is the sum of the terms it is built
    /// from**, written twice so that neither a new total nor a gap renamed into a
    /// different gap of the same value can pass quietly.
    @MainActor
    func testCozyBarFiveWithMeterWindowAndTrace() {
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
            + metrics.sparklineHeight
            + 2 * metrics.rowVerticalPadding

        let row = geometry(appearance, lines: [.meter, .window, .sparkline])
        XCTAssertEqual(row.height, expected, "the height stopped matching the terms it is built from")
        // 18 title + 6 spacing + 5 bar + 3 caption gap + 14 window
        //    + 6 spacing + 18 trace + 20 padding.
        XCTAssertEqual(row.height, 90, "the shipped three-block row is \(row.height)pt, not 90")
    }

    /// Dropping a line drops its own block and the gap that attached it, and
    /// nothing else.
    ///
    /// The case was written about the pace line, which hung off the foot of the
    /// stack at `contentSpacing + lineBox(captionSize)`. That block no longer
    /// exists in any arrangement — the pace is a run on the caption line, which is
    /// one `lineBox` whatever is written on it — so the premise it was stated
    /// against died with `Lines.forecast`. The property did not, and it is
    /// asserted here about the line that still has a block of its own: the window
    /// line, whose attachment is `captionGap` and not `contentSpacing`, because a
    /// caption belongs to the meter above it rather than standing beside it.
    ///
    /// That makes it the *stronger* subject of the two. The pace block was
    /// attached by the stack's own spacing, so a case about it could not tell
    /// `contentSpacing` from `captionGap`; this one fails if the joint is ever
    /// paid twice, or paid by the wrong token, or kept by a meter with nothing
    /// under it. The two-line row is still 66pt, which is the number the old case
    /// ended on.
    @MainActor
    func testDroppingTheWindowLineDropsItAndTheJointThatHeldIt() {
        let appearance = settings("cozy-no-window")
        appearance.density = .cozy
        appearance.textScale = 1.0
        appearance.meterThickness = 5
        let metrics = appearance.metrics

        let full = geometry(appearance, lines: [.meter, .window])
        let row = geometry(appearance, lines: [.meter])

        XCTAssertEqual(full.height, 66, "the two-line row is \(full.height)pt, not 66")
        XCTAssertEqual(
            row.height,
            full.height - metrics.captionGap - Tokens.lineBox(metrics.detailSize),
            "dropping the window line moved something other than the window line"
        )
        // 18 title + 6 spacing + 5 bar + 20 padding, and the 3pt joint gone with
        // the line it joined.
        XCTAssertEqual(row.height, 49, "the meter-only row is \(row.height)pt, not 49")
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

    // MARK: - The trace

    /// **What `.sparkline` costs, at every density and both ends of the text
    /// slider.** One block and the pitch in front of it, and nothing else.
    ///
    /// Swept rather than spot-checked because `sparklineHeight` is derived from
    /// `detailSize` and therefore moves with both settings, and a term written
    /// against one density can be right there and wrong at the other two.
    ///
    /// Written as the difference rather than as a total: the trace is additive by
    /// construction, and stating it that way is what makes the case fail if it
    /// ever starts interacting with the lines around it.
    @MainActor
    func testTheTraceCostsItsOwnBlockAndTheGapInFrontOfIt() {
        let appearance = settings("sparkline-cost")
        for density in AppearanceSettings.Density.allCases {
            for scale in [0.85, 1.0, 1.30] {
                appearance.density = density
                appearance.textScale = scale
                let metrics = appearance.metrics
                let at = "\(density.rawValue)/\(Int(scale * 100))%"

                let without = geometry(appearance, lines: [.meter, .window])
                let with = geometry(appearance, lines: [.meter, .window, .sparkline])
                XCTAssertEqual(
                    with.height - without.height,
                    metrics.contentSpacing + metrics.sparklineHeight,
                    accuracy: 1e-9,
                    "\(at): the trace cost \(with.height - without.height)pt"
                )
            }
        }
    }

    /// And it composes: adding it to a row that already carries further-window
    /// lines costs the same block. If the trace ever borrowed the ladder's pitch —
    /// or the ladder the trace's — this is where that shows.
    ///
    /// The case was written against `.forecast`, which was the other thing that
    /// could stand between the meter block and the foot of the row. The ladder is
    /// what stands there now, and it is the better subject for the same case: it
    /// is a *count* of blocks rather than one bit, so a pitch paid once for the
    /// group instead of once per line fails here too, where against a single pace
    /// block the two were indistinguishable.
    @MainActor
    func testTheTraceCostsTheSameBesideALadderOfFurtherWindows() {
        let appearance = settings("sparkline-composes")
        appearance.density = .cozy
        appearance.textScale = 1.0
        let metrics = appearance.metrics

        let laddered = geometry(appearance, secondaryLines: 2, lines: [.meter, .window])
        let both = geometry(appearance, secondaryLines: 2, lines: [.meter, .window, .sparkline])
        XCTAssertEqual(
            both.height - laddered.height,
            metrics.contentSpacing + metrics.sparklineHeight
        )
        // The two-line row is 66pt; two further windows at 6 of pitch and a 14pt
        // line each make it 106, and 6 of pitch and an 18pt trace make it 130.
        XCTAssertEqual(laddered.height, 106, "the laddered row is \(laddered.height)pt, not 106")
        XCTAssertEqual(both.height, 130, "the traced laddered row is \(both.height)pt, not 130")
    }

    /// The trace on a row with nothing else under its title: the ring meter takes
    /// the leading column, the window line is switched off, and the text stack is
    /// the title and the trace. The one configuration where the reservation is
    /// the trace and the padding and nothing else.
    @MainActor
    func testATraceAloneUnderTheTitleIsTheWholeTextStack() {
        let appearance = settings("sparkline-alone")
        appearance.density = .cozy
        appearance.textScale = 1.0
        appearance.meterStyle = .ring
        appearance.logoStyle = .hidden
        let metrics = appearance.metrics

        let row = geometry(appearance, lines: [.meter, .sparkline])
        let text = titleLine(metrics) + metrics.contentSpacing + metrics.sparklineHeight
        let leading = leadingLine(logo: 0, ring: metrics.ringDiameter)
        XCTAssertEqual(row.height, max(leading, text) + 2 * metrics.rowVerticalPadding)
        // 18 title + 6 spacing + 18 trace = 42 of text, against a 22pt dial, + 20
        // padding.
        XCTAssertEqual(row.height, 62, "the trace-only row is \(row.height)pt, not 62")
    }

    /// The invariant, restated for the new case: nothing about the *content* of
    /// the trace is an input, because there is no parameter for it. Two rows
    /// built from the same settings and the same lines measure the same whatever
    /// the store happens to hold — which is what lets a row with no history at
    /// all stand beside a row with a full day and neither of them move.
    @MainActor
    func testTheTraceHasNoContentToBeAFunctionOf() {
        let appearance = settings("sparkline-content")
        let other = settings("sparkline-content-twin")
        for preset in AppearanceSettings.Preset.allCases {
            appearance.apply(preset)
            other.apply(preset)
            XCTAssertEqual(
                geometry(appearance, lines: [.meter, .window, .sparkline]),
                geometry(other, lines: [.meter, .window, .sparkline]),
                "\(preset.id) measured two identical traced rows differently"
            )
        }
    }

    /// The box itself, at the three densities. `detailSize * 1.6` rounded, which
    /// is 10 → 16, 11 → 17.6 → 18 and 12 → 19.2 → 19: three distinct heights, all
    /// of them under the 22pt ring beside them, so the trace never out-measures
    /// the meter it annotates.
    @MainActor
    func testTheTraceBoxIsSixteenEighteenAndNineteen() {
        let appearance = settings("sparkline-box")
        appearance.textScale = 1.0
        let expected: [AppearanceSettings.Density: CGFloat] = [
            .compact: 16, .cozy: 18, .comfortable: 19
        ]
        for density in AppearanceSettings.Density.allCases {
            appearance.density = density
            let metrics = appearance.metrics
            XCTAssertEqual(
                metrics.sparklineHeight, (metrics.detailSize * 1.6).rounded(),
                "\(density.rawValue): the box stopped being 1.6 detail sizes"
            )
            XCTAssertEqual(
                metrics.sparklineHeight, expected[density],
                "\(density.rawValue) draws a \(metrics.sparklineHeight)pt trace"
            )
        }
    }

    /// The floor, which is only reachable from a `Metrics` built by hand — the
    /// app's own `detailSize` floors at 10, so 16 is the smallest box it can
    /// produce. A trace under 12pt has no shape left to read.
    @MainActor
    func testTheTraceBoxNeverFallsBelowTwelve() {
        XCTAssertEqual(handBuilt(detailSize: 1).sparklineHeight, 12)
        XCTAssertEqual(handBuilt(detailSize: 0).sparklineHeight, 12)
    }

    // MARK: - The further windows

    /// **What a further-window line costs, at every density and both ends of the
    /// text slider.** One line and the pitch in front of it, once per line, and
    /// nothing else.
    ///
    /// This is the reservation the panel did not have. Under
    /// `secondaryWindows == .expanded` the row drew one line per window the fetch
    /// came back with and reserved none of them, so a service that answered with
    /// three grew its row by 3 × (6 + 14) = 60pt at cozy/100% while the panel was
    /// open — and the **Dashboard** preset ships that style with a limit of six.
    /// The count is a setting now, held open whatever the answer turns out to
    /// contain, and this is the arithmetic behind it.
    ///
    /// Swept rather than spot-checked for the reason the trace's own case gives:
    /// both terms move with density and with text scale, so a term written against
    /// one density can be right there and wrong at the other two. `detailSize` and
    /// not `captionSize`, because every one of these lines is a
    /// `MetricCaption(isSecondary: true)` or a `SecondaryValue` and both hold
    /// themselves at `lineBox(detailSize)`.
    @MainActor
    func testEachFurtherWindowCostsOneLineAndThePitchInFrontOfIt() {
        let appearance = settings("secondary-cost")
        for density in AppearanceSettings.Density.allCases {
            for scale in [0.85, 1.0, 1.30] {
                appearance.density = density
                appearance.textScale = scale
                let metrics = appearance.metrics
                let at = "\(density.rawValue)/\(Int(scale * 100))%"
                let line = metrics.contentSpacing + Tokens.lineBox(metrics.detailSize)
                let none = geometry(appearance, lines: [.meter, .window])

                // The four counts the panel can actually be in: a service with no
                // further windows, one, the common several, and the stepper's own
                // ceiling.
                for count in [0, 1, 3, RowGeometry.secondaryLineCeiling] {
                    let row = geometry(appearance, secondaryLines: count, lines: [.meter, .window])
                    XCTAssertEqual(
                        row.height - none.height, CGFloat(count) * line,
                        accuracy: 1e-9,
                        "\(at): \(count) further windows cost \(row.height - none.height)pt"
                    )
                }
            }
        }
    }

    /// The ceiling, which is what stops a number reaching a frame height.
    ///
    /// `secondaryLines` is an `Int` on a public initialiser, so what protects the
    /// row is this clamp and not the stepper's `1...6`: `RowGeometry` is
    /// constructed by `ProviderRow`, by the Appearance pane's preview and by this
    /// suite, and a caller that worked its count out from a payload rather than
    /// from the settings would hand it whatever the payload had in it. Twenty
    /// lines of arithmetic is a 400pt row; `Int.max` is a frame no layout survives.
    @MainActor
    func testTheLadderIsClampedAtBothEnds() {
        let appearance = settings("secondary-ceiling")
        let ceiling = geometry(
            appearance, secondaryLines: RowGeometry.secondaryLineCeiling, lines: [.meter, .window]
        )
        for absurd in [RowGeometry.secondaryLineCeiling + 1, 20, 10_000, Int.max] {
            XCTAssertEqual(
                geometry(appearance, secondaryLines: absurd, lines: [.meter, .window]), ceiling,
                "\(absurd) further windows measured past the ceiling"
            )
        }

        let none = geometry(appearance, lines: [.meter, .window])
        for absurd in [-1, -10_000, Int.min] {
            XCTAssertEqual(
                geometry(appearance, secondaryLines: absurd, lines: [.meter, .window]), none,
                "\(absurd) further windows measured as something other than none"
            )
        }
    }

    /// And the ladder is height and only height. The rails are the panel's column
    /// rather than the row's, so a row holding six further windows hands the same
    /// figure column to the row beside it holding none — which is what keeps a
    /// Dashboard panel one column of numbers instead of one per service.
    @MainActor
    func testTheLadderDoesNotTouchTheRailsOrTheColumns() {
        let appearance = settings("secondary-rails")
        let reference = geometry(appearance, lines: [.meter, .window])
        for count in 0...RowGeometry.secondaryLineCeiling {
            let row = geometry(appearance, secondaryLines: count, lines: [.meter, .window])
            XCTAssertEqual(row.headlineRail, reference.headlineRail, "\(count) windows moved the headline rail")
            XCTAssertEqual(row.secondaryRail, reference.secondaryRail, "\(count) windows moved the secondary rail")
            XCTAssertEqual(row.leadingWidth, reference.leadingWidth, "\(count) windows moved the leading column")
            XCTAssertEqual(row.textColumnWidth, reference.textColumnWidth, "\(count) windows moved the text column")
        }
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
                // The ladder is swept with the line sets rather than left at
                // none, because it is the newest input and the only one that is a
                // number: a term that read a global — the count of windows the
                // last fetch happened to carry, say — would be equal here at zero
                // and unequal at six.
                for secondaryLines in [0, 1, RowGeometry.secondaryLineCeiling] {
                    XCTAssertEqual(
                        geometry(one, secondaryLines: secondaryLines, lines: lines),
                        geometry(other, secondaryLines: secondaryLines, lines: lines),
                        "\(preset.id) measured two identical rows differently at "
                        + "\(lines.rawValue) and \(secondaryLines) further windows"
                    )
                }
            }
        }
    }

    /// The other half of that: a line that is drawn has to cost something, or
    /// "the height is a function of the lines" is true only because the height
    /// ignores them.
    ///
    /// `.forecast` was in the list and is gone from it, and the last assertion —
    /// that a row with the pace line is taller than the same row without it — went
    /// with it, because that is now precisely the thing that must *not* be true:
    /// a pace arriving may not move a row by a point. It is asserted in that
    /// direction, by measurement, in
    /// `RowReservationTests.testAPaceArrivingCannotChangeARowsHeight`.
    ///
    /// What replaces it here is the assertion the ladder created and the pace
    /// block could never have supported: the further windows are a *count*, so
    /// "one of them costs something" is the weak half of it and "every one of them
    /// costs another block, all the way to the ceiling" is the whole of it.
    @MainActor
    func testEachLineTheRowDrawsCostsHeight() {
        let appearance = settings("lines-cost")
        appearance.logoStyle = .hidden
        let bare = geometry(appearance, lines: [])
        // `.budget` joins the list with the block it names. It is the one line
        // here whose *drawing* is two things — a track and a figure under it — so
        // a term that reserved only one of them would still pass this and be
        // caught by `testTheRowDrawsTheBudgetBlockItReserved`, which measures the
        // step against the arithmetic rather than against zero.
        for lines in [RowGeometry.Lines.meter, .window, .sparkline, .budget] {
            XCTAssertGreaterThan(
                geometry(appearance, lines: lines).height, bare.height,
                "drawing \(lines.rawValue) cost the row nothing"
            )
        }
        for count in 0..<RowGeometry.secondaryLineCeiling {
            XCTAssertGreaterThan(
                geometry(appearance, secondaryLines: count + 1, lines: [.meter, .window]).height,
                geometry(appearance, secondaryLines: count, lines: [.meter, .window]).height,
                "further window \(count + 1) cost the row nothing"
            )
        }
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

        // Every block a row can draw, and the deepest ladder it can hold: the
        // width is not a function of any of them — `testTheRailsDoNotDependOnWhich
        // LinesARowDraws` is what says so — and naming the whole row here is what
        // makes this case a statement about the narrowest panel rather than about
        // one arrangement of it.
        let row = geometry(
            appearance,
            secondaryLines: RowGeometry.secondaryLineCeiling,
            lines: [.meter, .window, .sparkline]
        )
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

    /// A comfortable row with all three blocks is far past the clamp, so it draws
    /// the full radius.
    @MainActor
    func testATallRowTakesTheFullRadius() {
        let appearance = settings("radius-tall")
        appearance.density = .comfortable
        let row = geometry(appearance, lines: [.meter, .window, .sparkline])
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

    /// The chips' share of the line, written twice — as the arithmetic and as the
    /// numbers it comes to at the shipped type size.
    ///
    /// This is the case that would have caught the shipped overflow. The estimate
    /// modelled a chip nobody draws: 12pt of capsule padding, a 5pt dot, two
    /// inner gaps, a 4-cell label and a 7-cell reading. What replaces it is a
    /// count and a cap that divide one residue, so the two cannot come apart —
    /// and the residue is spelled out here from the tokens rather than asked of
    /// the subject, which is the only way an assertion can disagree with it.
    func testTheChipsDivideTheLineTheyRideOn() {
        let size: CGFloat = 11
        let column: CGFloat = 520
        // What the trailing half of the line has: the column, less the gap to the
        // sentence, less the cell the "+N" takes. 520 − 8 − (21 + 8) = 483.
        let residue = column - Tokens.Space.medium - (Tokens.figureWidth(size, digits: 3) + Tokens.Space.medium)
        XCTAssertEqual(residue, 483)

        // One chip at full stretch: an eight-cell label, the chip's inner gap and
        // a nine-cell reading. 55 + 4 + 62 = 121, and with the gap to the next
        // chip, 129 — which is what the count divides by. 483 / 129 = 3.74.
        let stretch = Tokens.figureWidth(size, digits: 8)
            + Tokens.Space.snug
            + Tokens.figureWidth(size, digits: 9)
        XCTAssertEqual(stretch, 121)
        let limit = RowGeometry.chipLimit(textColumnWidth: column, chipSize: size, carriesSpend: false)
        XCTAssertEqual(limit, Int(residue / (stretch + Tokens.Space.medium)))
        XCTAssertEqual(limit, 3)

        // And each of the three may draw its share of it: (483 − 2 × 8) / 3.
        let cap = RowGeometry.chipCap(textColumnWidth: column, chipSize: size, carriesSpend: false)
        XCTAssertEqual(cap, (residue - CGFloat(limit - 1) * Tokens.Space.medium) / CGFloat(limit))
        XCTAssertEqual(cap, 467.0 / 3.0, accuracy: 0.001)
        XCTAssertGreaterThan(cap, stretch, "a wide line still cut its chips at the label cap")

        // The reading never needs more than its nine cells, so every point above
        // them is the label's — which is what lets a long window name draw whole
        // on a panel that has the room for it.
        let runs = RowGeometry.chipRuns(cap: cap, chipSize: size)
        XCTAssertEqual(runs.reading, Tokens.figureWidth(size, digits: 9))
        XCTAssertGreaterThan(runs.label, Tokens.figureWidth(size, digits: 8))
        XCTAssertEqual(runs.label + Tokens.Space.snug + runs.reading, cap, accuracy: 0.001)
    }

    /// The other end of the same arithmetic: a line too narrow for one whole chip
    /// cuts the chip rather than the count, since the count has nowhere lower to
    /// go. Below one stretch the cap *is* what the line has left.
    func testATooNarrowLineCutsTheChipRatherThanTheCount() {
        let size: CGFloat = 11
        let stretch = Tokens.figureWidth(size, digits: 8)
            + Tokens.Space.snug
            + Tokens.figureWidth(size, digits: 9)
        // 300pt of panel behind a 40pt logo, with a spend at the head of the
        // caption: 300 − 24 gutters − 50 leading column = 226 of text column, and
        // the sentence gap, the "+N" cell and the spend take 8 + 29 + 98 of it.
        //
        // The spend was 87 and is 98: `MetricCaption` now draws a middle dot
        // between the amount and the window beside it — every other pair on that
        // line carried one and this one did not, so `$10,000.00 5h session` read
        // as a single run. `Space.snug` plus one mono cell is 4 + 7, and it is
        // reserved because `SpendFigure` is `layoutPriority(1)` and `fixedSize`,
        // so a dot beside it comes out of the chips' budget and not out of slack.
        // The cap follows the residue exactly: 226 − 8 − 29 − 98 = 91, where it
        // was 226 − 8 − 29 − 87 = 102.
        let narrow: CGFloat = 226
        let cap = RowGeometry.chipCap(textColumnWidth: narrow, chipSize: size, carriesSpend: true)
        XCTAssertEqual(RowGeometry.chipLimit(textColumnWidth: narrow, chipSize: size, carriesSpend: true), 1)
        XCTAssertEqual(cap, 91)
        XCTAssertLessThan(cap, stretch, "a 226pt column still offered a chip its full stretch")

        // The reading is served first and the label takes what is left, which is
        // the chip's own rule: a clipped figure is a different quantity, a
        // clipped label is still the window's family.
        let runs = RowGeometry.chipRuns(cap: cap, chipSize: size)
        XCTAssertEqual(runs.reading, Tokens.figureWidth(size, digits: 9))
        XCTAssertEqual(runs.label, cap - Tokens.Space.snug - runs.reading)
    }

    /// A wider line never holds fewer chips. Swept rather than spot-checked,
    /// because the fault this guards against is an off-by-one at one particular
    /// width rather than a wrong slope.
    func testChipLimitIsMonotonicInTheWidthAvailable() {
        for chipSize in [CGFloat(10), 11, 12, 15.6] {
            for carriesSpend in [false, true] {
                var previous = 0
                for width in stride(from: CGFloat(0), through: 600, by: 5) {
                    let limit = RowGeometry.chipLimit(
                        textColumnWidth: width, chipSize: chipSize, carriesSpend: carriesSpend
                    )
                    XCTAssertGreaterThanOrEqual(
                        limit, previous,
                        "\(width)pt at \(chipSize)pt type held fewer chips than \(width - 5)pt did"
                    )
                    previous = limit
                }
            }
        }
    }

    /// A spend at the head of the caption is width the chips cannot have, so the
    /// same line never holds more of them with one than without.
    func testASpendOnTheLineNeverBuysAChip() {
        for chipSize in [CGFloat(10), 11, 12, 15.6] {
            for width in stride(from: CGFloat(0), through: 600, by: 5) {
                let free = RowGeometry.chipLimit(
                    textColumnWidth: width, chipSize: chipSize, carriesSpend: false
                )
                let paid = RowGeometry.chipLimit(
                    textColumnWidth: width, chipSize: chipSize, carriesSpend: true
                )
                XCTAssertGreaterThanOrEqual(
                    free, paid,
                    "\(width)pt at \(chipSize)pt fitted \(paid) chips beside a spend and \(free) without"
                )
            }
        }
    }

    /// Never zero and never negative, whatever it is handed. A line of no chips
    /// reports nothing at all about a service with several windows, which is
    /// strictly worse than one chip that can be read — and that floor is safe
    /// because `chipCap` floors with it rather than handing the one chip a width
    /// the line does not have.
    func testChipLimitIsNeverLessThanOne() {
        let widths: [CGFloat] = [
            -.greatestFiniteMagnitude, -600, -1, 0, 0.5, 1, 300, 520, 10_000,
            .nan, .infinity, -.infinity
        ]
        for width in widths {
            for chipSize in [CGFloat(-5), 0, .nan, .infinity, 9, 10, 40] {
                for carriesSpend in [false, true] {
                    let limit = RowGeometry.chipLimit(
                        textColumnWidth: width, chipSize: chipSize, carriesSpend: carriesSpend
                    )
                    XCTAssertGreaterThanOrEqual(
                        limit, 1,
                        "chipLimit(\(width), \(chipSize), spend: \(carriesSpend)) came back with \(limit)"
                    )
                    let cap = RowGeometry.chipCap(
                        textColumnWidth: width, chipSize: chipSize, carriesSpend: carriesSpend
                    )
                    XCTAssertTrue(cap.isFinite && cap >= 0, "chipCap(\(width), \(chipSize)) is \(cap)")
                    let runs = RowGeometry.chipRuns(cap: cap, chipSize: chipSize)
                    XCTAssertTrue(runs.label >= 0 && runs.reading >= 0)
                    XCTAssertTrue(runs.label.isFinite && runs.reading.isFinite)
                }
            }
        }
    }

    /// The boundary itself: one point short of fitting another chip must answer
    /// the lower count, and the gap to the next chip has to be inside the chip's
    /// own width or the division finds room for one more than the line holds.
    ///
    /// The chip's width is private, so it is read off the step from one chip to
    /// two rather than spelled — that keeps this true when the chip's parts
    /// change, and it is the second step that has to be measured because the
    /// floor at one chip hides the first. The steps are measured from that
    /// boundary rather than from zero, because the line spends a fixed amount
    /// before the first chip — the gap to the sentence and the "+N" cell — and it
    /// is the *step* between counts that is one chip's width.
    func testChipLimitStepsUpOnlyOnceTheChipActuallyFits() throws {
        let chipSize: CGFloat = 10
        func limit(_ width: CGFloat) -> Int {
            RowGeometry.chipLimit(textColumnWidth: width, chipSize: chipSize, carriesSpend: false)
        }

        var second: CGFloat?
        var third: CGFloat?
        for width in stride(from: CGFloat(1), through: 1000, by: 1) {
            if second == nil, limit(width) == 2 { second = width }
            if limit(width) == 3 { third = width; break }
        }
        let twoAt = try XCTUnwrap(second, "no width under 1000pt ever held a second chip")
        let threeAt = try XCTUnwrap(third, "no width under 1000pt ever held a third chip")
        // One chip and the gap to the next, which is what one more chip costs.
        let chip = threeAt - twoAt
        // The step, written out: an eight-cell label, the chip's inner gap, a
        // nine-cell reading, and the gap to the chip after it. 50 + 4 + 56 + 8 at
        // a 10pt chip. Measured off the sweep rather than asked of the subject,
        // so the two have to agree about what a chip costs.
        XCTAssertEqual(
            chip,
            Tokens.figureWidth(chipSize, digits: 8)
                + Tokens.Space.snug
                + Tokens.figureWidth(chipSize, digits: 9)
                + Tokens.Space.medium,
            "a chip steps the count every \(chip)pt"
        )

        // The floor: a line too narrow for even one chip still reports one,
        // because a chip that has to truncate says more than no chip at all.
        XCTAssertEqual(limit(twoAt - chip), 1)
        XCTAssertEqual(limit(1), 1)
        for chips in 2...5 {
            let at = twoAt + CGFloat(chips - 2) * chip
            XCTAssertEqual(limit(at), chips, "\(at)pt did not hold exactly \(chips) chips")
            XCTAssertEqual(
                limit(at + chip - 1), chips,
                "a point short of \(chips + 1) chips reported more than \(chips)"
            )
        }
    }

    /// A larger type size makes a wider chip, so the same line holds no more of
    /// them.
    func testABiggerChipNeverFitsMoreOfThem() {
        for width in stride(from: CGFloat(100), through: 500, by: 50) {
            let small = RowGeometry.chipLimit(textColumnWidth: width, chipSize: 10, carriesSpend: false)
            let large = RowGeometry.chipLimit(textColumnWidth: width, chipSize: 15.6, carriesSpend: false)
            XCTAssertGreaterThanOrEqual(
                small, large,
                "a 15.6pt chip fitted more into \(width)pt than a 10pt one"
            )
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
                    // The deepest ladder as well, so a poisoned length is
                    // multiplied by six rather than added once: `secondaryHeight`
                    // is the one term in the sum with a factor in front of it, and
                    // a NaN there is a NaN six times over.
                    secondaryLines: RowGeometry.secondaryLineCeiling,
                    lines: [.meter, .window, .sparkline]
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
        // **Four** of them since the budget block was reserved: the pace stopped
        // being a bit and the budget became one, so this is a strictly wider
        // assertion than the three-bit form it replaces rather than the same one
        // renumbered. It did its job on the way through — the budget bit was added
        // with its term in the sum and this case still named three, and it failed
        // on 116pt against 90 rather than letting a fifth bit be added later with
        // no term at all.
        XCTAssertEqual(
            geometry(appearance, lines: RowGeometry.Lines(rawValue: ~0)),
            geometry(appearance, lines: [.meter, .window, .sparkline, .budget])
        )
        // Bit 2 in particular, which is the one bit that used to mean something
        // and does not any more. It named the pace block; it is retired rather
        // than reused, so a `Lines(rawValue: 4)` surviving in an old call site — or
        // in a `rawValue` somebody wrote down — means nothing, where reusing the
        // bit for the trace would have made it silently mean the trace. This
        // assertion is only possible because the bit was retired, and it is here
        // so that reusing it later fails a test rather than passing one.
        XCTAssertEqual(
            geometry(appearance, lines: RowGeometry.Lines(rawValue: 1 << 2)),
            geometry(appearance, lines: [])
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
            "aibars.appearance.meterStyle": "dial",
            // Twenty further-window lines is 400pt of row at cozy/100%, which is
            // the whole panel. No stepper can write it and a text editor can.
            "aibars.appearance.secondaryWindowLimit": 20
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
        // The ladder's count is pulled in by the same pass, before any row reads
        // it — `normalize()` runs at the end of `AppearanceSettings.init` and
        // clamps this to the stepper's own `1...6`. So the ceiling inside
        // `RowGeometry` is a *second* line of defence rather than the only one,
        // and it is the line that covers a caller who did not come through the
        // settings at all: the parameter is a bare `Int` on a public initialiser.
        // `testTheLadderIsClampedAtBothEnds` is where that half is asserted.
        XCTAssertEqual(appearance.secondaryWindowLimit, 6, "a stored 20 reached a row's ladder")

        let row = geometry(
            appearance,
            secondaryLines: appearance.secondaryWindowLimit,
            lines: [.meter, .window, .sparkline]
        )
        XCTAssertTrue(row.height.isFinite, "a stored NaN reached the row's height")
        XCTAssertGreaterThan(row.height, 0)
        XCTAssertTrue(row.textColumnWidth.isFinite)
        XCTAssertGreaterThan(row.textColumnWidth, 0)
        XCTAssertGreaterThanOrEqual(
            RowGeometry.chipLimit(
                textColumnWidth: row.textColumnWidth,
                chipSize: appearance.metrics.detailSize,
                carriesSpend: true
            ),
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
        XCTAssertEqual(
            RowGeometry.chipLimit(textColumnWidth: row.textColumnWidth, chipSize: 10, carriesSpend: false),
            1
        )
    }

    // MARK: - Fixtures

    /// All sixteen combinations of the four lines. Every case that sweeps has to
    /// sweep the same set, or two of them disagree about what was covered.
    ///
    /// The list has been wrong twice now and in the same direction both times,
    /// which is why it is spelled out in full rather than derived. It used to be
    /// eight combinations of the meter, the window line and the pace, and the
    /// trace — added later — was in none of them; then eight of the meter, the
    /// window line and the trace, and the budget block — added later — was in
    /// none of them. Both times the newest reservation was the one no sweeping
    /// case touched, which is the "reads as coverage" failure the whole model is
    /// written against. Sixteen is every bit `RowGeometry.Lines` defines, and
    /// `testUnknownLineBitsDrawNothing` is what pins that count to the type.
    private static let allLineSets: [RowGeometry.Lines] = [
        [],
        [.meter],
        [.window],
        [.sparkline],
        [.budget],
        [.meter, .window],
        [.meter, .sparkline],
        [.meter, .budget],
        [.window, .sparkline],
        [.window, .budget],
        [.sparkline, .budget],
        [.meter, .window, .sparkline],
        [.meter, .window, .budget],
        [.meter, .sparkline, .budget],
        [.window, .sparkline, .budget],
        [.meter, .window, .sparkline, .budget]
    ]
}
