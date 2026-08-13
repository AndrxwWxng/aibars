import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// The ninety-day grid, in the three places it can be wrong.
///
/// **The band.** Which of six inks a day takes is arithmetic over a peak and the
/// user's own warning threshold, and it is asserted directly — no host, no
/// store, no clock. The boundaries are walked at three thresholds rather than
/// one, because the four neutral steps are quarters *of the threshold* and a
/// function that had quietly hard-coded 0.95 would pass at 0.95 alone.
///
/// **The ramp.** A heatmap's whole claim is that a darker square means a busier
/// day. That is only true if the scale is monotonic in luminance, and this file
/// measures it in both appearances rather than trusting five hexes to have been
/// picked in order. It is also the assertion that stops somebody tidying the
/// ramp into a hue one, which is the change this design exists to refuse: a
/// green-through-red ramp will not satisfy it.
///
/// **The box.** The grid is `Tokens.Heat.width` × `.height` whatever landed in
/// it. Nothing here measures a colour by eye or a layout by pixel; what is
/// measured is the size a hosted grid reports, across the states its data can be
/// in — none, three days, ninety days, and every day at the cap.
///
/// The query behind it — ninety cells, the spring-forward Sunday, `firstWeekday`
/// — belongs to `HistoryQuery.heatmap` and is asserted in `HistoryQueryTests`.
/// It is not repeated here: two copies of one table is how one of them goes
/// stale.
final class HistoryHeatmapTests: XCTestCase {

    // MARK: - Harness

    /// The calendar every grid below is laid out in: London, Gregorian, weeks
    /// opening on Monday. Pinned entirely, because every coordinate a cell
    /// carries is a function of all three and none of them may be the machine's.
    private func london(firstWeekday: Int = 2) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/London"))
        calendar.firstWeekday = firstWeekday
        return calendar
    }

    private func date(
        _ year: Int, _ month: Int, _ day: Int,
        in calendar: Calendar
    ) throws -> Date {
        var parts = DateComponents()
        parts.year = year
        parts.month = month
        parts.day = day
        parts.hour = 12
        return try XCTUnwrap(calendar.date(from: parts), "\(year)-\(month)-\(day) is not a date")
    }

    /// A settings object on a scratch domain. `AppearanceSettings.shared` writes
    /// to whoever ran the suite.
    @MainActor
    private func appearance() throws -> AppearanceSettings {
        let domain = "aibars.heatmap.tests.\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: domain) }
        let store = try XCTUnwrap(UserDefaults(suiteName: domain))
        return AppearanceSettings(store: store)
    }

    /// One colour resolved in a named appearance.
    ///
    /// `performAsCurrentDrawingAppearance` rather than assigning
    /// `NSAppearance.current`: the second is deprecated, and a deprecation
    /// warning is a build regression here.
    private func resolve(_ color: Color, dark: Bool) throws -> NSColor {
        let appearance = try XCTUnwrap(NSAppearance(named: dark ? .darkAqua : .aqua))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        return try XCTUnwrap(resolved, "the colour does not resolve in \(dark ? "dark" : "light")")
    }

    private func hex(_ color: Color, dark: Bool) throws -> UInt32 {
        let srgb = try resolve(color, dark: dark)
        func channel(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return channel(srgb.redComponent) << 16
             | channel(srgb.greenComponent) << 8
             | channel(srgb.blueComponent)
    }

    /// Ninety cells with the given days filled, newest last, in the pinned
    /// calendar. `filled` counts back from today, so `filled: 3` is the
    /// three-day-old install the empty state exists for.
    private func grid(
        filled: Int,
        peak: Double = 0.5,
        capHits: Int = 0,
        endingOn end: Date,
        in calendar: Calendar
    ) -> [HistoryHeatmapCell] {
        let last = calendar.startOfDay(for: end)
        let days: [HistoryDay] = (0..<filled).compactMap { back in
            guard let day = calendar.date(byAdding: .day, value: -back, to: last) else { return nil }
            return HistoryDay(day: day, peak: peak, mean: peak / 2, capHits: capHits, samples: 288)
        }
        return HistoryQuery.heatmap(
            days, endingOn: end, dayCount: HistoryHeatmap.dayCount, calendar: calendar
        )
    }

    @MainActor
    private func hosted<V: View>(_ view: V) -> NSView {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: 480, height: 240)
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        return host
    }

    // MARK: - The band

    /// Every boundary at the shipped threshold, written as the arithmetic that
    /// produced it rather than as nine loose constants: the four filled steps are
    /// quarters of 0.95, so they fall at 0.2375, 0.475 and 0.7125.
    func testTheBandsSitAtQuartersOfTheWarningThreshold() {
        let warning = 0.95
        XCTAssertEqual(HeatmapBand.band(peak: nil, warning: warning), .empty)
        XCTAssertEqual(HeatmapBand.band(peak: .nan, warning: warning), .empty)
        XCTAssertEqual(HeatmapBand.band(peak: .infinity, warning: warning), .empty)

        // 0 is a day whose readings all said zero, which is a different fact from
        // a mac that was switched off, and the one boundary a grid must not blur.
        XCTAssertEqual(HeatmapBand.band(peak: 0, warning: warning), .quiet)

        // 0.25 × 0.95 = 0.2375, and the case is `..<0.25`, so the boundary itself
        // is the *next* band up.
        XCTAssertEqual(HeatmapBand.band(peak: 0.2374, warning: warning), .quiet)
        XCTAssertEqual(HeatmapBand.band(peak: 0.2375, warning: warning), .light)
        // 0.50 × 0.95 = 0.475
        XCTAssertEqual(HeatmapBand.band(peak: 0.4749, warning: warning), .light)
        XCTAssertEqual(HeatmapBand.band(peak: 0.475, warning: warning), .moderate)
        // 0.75 × 0.95 = 0.7125
        XCTAssertEqual(HeatmapBand.band(peak: 0.7124, warning: warning), .moderate)
        XCTAssertEqual(HeatmapBand.band(peak: 0.7125, warning: warning), .heavy)

        XCTAssertEqual(HeatmapBand.band(peak: 0.9499, warning: warning), .heavy)
        XCTAssertEqual(HeatmapBand.band(peak: 0.95, warning: warning), .alarm, "at the line is over it")
        XCTAssertEqual(HeatmapBand.band(peak: 1.0, warning: warning), .alarm)
    }

    /// The bands follow the threshold rather than sitting at fixed stops. A user
    /// who moved their warning down to 0.60 has a whole grid rebanded under it,
    /// and a legend that still means what it says.
    func testTheBandsMoveWithTheThreshold() {
        // 0.55 is 91.7% of 0.60 and only 57.9% of 0.95 — one reading, two bands,
        // which is the entire point of dividing rather than comparing.
        XCTAssertEqual(HeatmapBand.band(peak: 0.55, warning: 0.60), .heavy)
        XCTAssertEqual(HeatmapBand.band(peak: 0.55, warning: 0.95), .moderate)
        XCTAssertEqual(HeatmapBand.band(peak: 0.60, warning: 0.60), .alarm)

        // 0.25 × 0.60 = 0.15, 0.50 × 0.60 = 0.30, 0.75 × 0.60 = 0.45.
        XCTAssertEqual(HeatmapBand.band(peak: 0.1499, warning: 0.60), .quiet)
        XCTAssertEqual(HeatmapBand.band(peak: 0.15, warning: 0.60), .light)
        XCTAssertEqual(HeatmapBand.band(peak: 0.30, warning: 0.60), .moderate)
        XCTAssertEqual(HeatmapBand.band(peak: 0.45, warning: 0.60), .heavy)
    }

    /// A threshold of zero, a negative one and a non-finite one are the three
    /// divisors that would take the ramp with them. None of them divides: above
    /// nothing is over the line, and nothing itself is not.
    func testAThresholdOfNothingIsNeverDividedBy() {
        for warning in [0.0, -1.0, Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(
                HeatmapBand.band(peak: 0.5, warning: warning), .alarm,
                "a peak over a threshold of \(warning) is over it"
            )
            XCTAssertEqual(
                HeatmapBand.band(peak: 0, warning: warning), .quiet,
                "a day at zero is not an alarm at any threshold"
            )
            XCTAssertEqual(HeatmapBand.band(peak: nil, warning: warning), .empty)
        }
    }

    // MARK: - The ramp

    /// Ninety squares only read as a scale if they are ordered by how much light
    /// they carry. This is that claim, measured: strictly darker in light,
    /// strictly lighter in dark, over the five steps in the order the legend
    /// prints them.
    ///
    /// A hue ramp cannot satisfy it. Green → yellow → red rises to 0.79 at yellow
    /// and falls to 0.21 at red, so any two of the three orderings break — which
    /// is why this assertion, and not a comment, is what holds the design.
    func testTheRampIsStrictlyMonotonicInLuminanceInBothAppearances() throws {
        for (name, dark, wantsRising) in [("light", false, false), ("dark", true, true)] {
            var previous: Double?
            var measured: [Double] = []
            for step in HistoryHeatmap.ramp {
                let value = Tokens.relativeLuminance(try resolve(step, dark: dark))
                measured.append(value)
                if let previous {
                    if wantsRising {
                        XCTAssertGreaterThan(
                            value, previous,
                            "the \(name) ramp does not rise: \(measured)"
                        )
                    } else {
                        XCTAssertLessThan(
                            value, previous,
                            "the \(name) ramp does not fall: \(measured)"
                        )
                    }
                }
                previous = value
            }
            // Five steps, and each one has to be visible as a step. The smallest
            // gap in either appearance is 0.0364, between `empty` and `step1` in
            // dark; a ramp whose steps closed to under a hundredth would be four
            // squares of one grey.
            let gaps = zip(measured, measured.dropFirst()).map { abs($1 - $0) }
            XCTAssertGreaterThan(
                gaps.min() ?? 0, 0.01,
                "two \(name) steps are the same square: \(gaps)"
            )
        }
    }

    /// The ramp's ends are existing tokens, not new colours: an empty cell is the
    /// meter's own track — which is what an empty cell already is elsewhere — and
    /// the darkest step is the ink everything that is context takes. A ramp with
    /// its own private endpoints is a sixth and seventh colour in an app that has
    /// spent two hues down to zero.
    func testTheRampStartsOnTheTrackAndEndsOnTheMutedInk() throws {
        for dark in [false, true] {
            XCTAssertEqual(
                try hex(Tokens.Heat.empty, dark: dark), try hex(Tokens.Meter.track, dark: dark),
                "an empty cell is not the meter's track in \(dark ? "dark" : "light")"
            )
            XCTAssertEqual(
                try hex(Tokens.Heat.step4, dark: dark), try hex(Tokens.Ink.muted, dark: dark),
                "the darkest step is not Ink.muted in \(dark ? "dark" : "light")"
            )
        }
    }

    /// The one branch that reaches a hue, and the four that must not.
    ///
    /// Asserted through the resolved sRGB rather than by comparing `Color`s: the
    /// four neutral bands have to *be* their tokens, and the alarm band has to be
    /// whatever `AppearanceSettings.tint` says — including under `.mono`, whose
    /// whole promise is that colour returns only above the warning line.
    @MainActor
    func testOnlyTheAlarmBandTakesAColour() throws {
        let settings = try appearance()
        settings.warningThreshold = 0.95
        let calendar = try london()
        let end = try date(2021, 4, 30, in: calendar)
        let view = HistoryHeatmap(
            cells: [], accent: .purple, calendar: calendar, appearance: settings
        )

        func cell(_ peak: Double?, capHits: Int = 0) -> HistoryHeatmapCell {
            HistoryHeatmapCell(
                day: end, peak: peak, capHits: capHits, samples: 1, column: 0, row: 0
            )
        }

        for dark in [false, true] {
            XCTAssertEqual(try hex(view.ink(for: cell(nil)), dark: dark),
                           try hex(Tokens.Heat.empty, dark: dark))
            XCTAssertEqual(try hex(view.ink(for: cell(0.10)), dark: dark),
                           try hex(Tokens.Heat.step1, dark: dark))
            XCTAssertEqual(try hex(view.ink(for: cell(0.30)), dark: dark),
                           try hex(Tokens.Heat.step2, dark: dark))
            XCTAssertEqual(try hex(view.ink(for: cell(0.50)), dark: dark),
                           try hex(Tokens.Heat.step3, dark: dark))
            XCTAssertEqual(try hex(view.ink(for: cell(0.80)), dark: dark),
                           try hex(Tokens.Heat.step4, dark: dark))
            XCTAssertEqual(
                try hex(view.ink(for: cell(0.99)), dark: dark),
                try hex(settings.tint(for: 0.99, providerAccent: .purple), dark: dark),
                "the alarm cell is holding its own opinion about the warning colour"
            )
        }

        // Under `.mono` every other cell is still a neutral step and the alarm
        // cell still carries a hue, because `tint` answers the warning colour for
        // every ramp above the line. Measured as chroma — the spread between the
        // largest and the smallest sRGB channel — rather than against a colour
        // constant, so what is asserted is "this cell is not a grey" and not "this
        // cell equals whatever the ramp currently returns", which would pass on a
        // grid that had gone entirely grey.
        settings.colorRamp = .mono
        for dark in [false, true] {
            let alarm = try resolve(view.ink(for: cell(0.99)), dark: dark)
            let heavy = try resolve(view.ink(for: cell(0.80)), dark: dark)
            XCTAssertGreaterThan(
                chroma(alarm), 0.25,
                "a monochrome panel that hides an imminent cutoff is a bug, not a preference"
            )
            XCTAssertLessThan(
                chroma(heavy), 0.06,
                "a cell below the warning line is carrying a hue in \(dark ? "dark" : "light")"
            )
        }
        XCTAssertEqual(
            try hex(view.ink(for: cell(0.50)), dark: true),
            try hex(Tokens.Heat.step3, dark: true),
            "the neutral ramp changed when the colour ramp did"
        )
    }

    /// How far a resolved colour is from a grey: the spread between its largest
    /// and its smallest sRGB channel.
    ///
    /// The palette's neutrals are cool rather than dead grey, so they are not
    /// zero — the widest is dark `Ink.muted` at 0xA0…0xAE, which is 14 of 255 or
    /// 0.055. Both alarm hues are an order out from there: dark amber 0xE08D1C is
    /// 196 of 255, and the palest of the four, dark red 0xFFA5A7, is still 90 of
    /// 255 or 0.353. The two bounds below sit either side of that gap.
    private func chroma(_ color: NSColor) -> CGFloat {
        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
        return (channels.max() ?? 0) - (channels.min() ?? 0)
    }

    // MARK: - The grid's box

    /// The dimensions asserted against the tokens and against the arithmetic
    /// behind them, both — so a grid that grew a column is a failing test rather
    /// than a settings form that quietly reflows.
    ///
    /// Fourteen columns of an 11pt cell with a 2pt seam between and none outside:
    /// 14 × 13 − 2 = 180. Seven rows the same way: 7 × 13 − 2 = 89.
    func testTheGridsReservedBoxIsOneHundredAndEightyByEightyNine() {
        XCTAssertEqual(Tokens.Heat.cell, 11)
        XCTAssertEqual(Tokens.Heat.gap, Tokens.Space.tight)
        XCTAssertEqual(Tokens.Heat.pitch, 13)
        XCTAssertEqual(Tokens.Heat.columns, 14)

        XCTAssertEqual(Tokens.Heat.width, 180)
        XCTAssertEqual(
            Tokens.Heat.width,
            CGFloat(Tokens.Heat.columns) * (Tokens.Heat.cell + Tokens.Heat.gap) - Tokens.Heat.gap
        )
        XCTAssertEqual(Tokens.Heat.height, 89)
        XCTAssertEqual(
            Tokens.Heat.height,
            CGFloat(HistoryHeatmap.weekdays) * (Tokens.Heat.cell + Tokens.Heat.gap) - Tokens.Heat.gap
        )

        // Fourteen columns hold ninety-five days, which is the ceiling the ninety
        // is under: ninety days opens on the week of its oldest day, up to six
        // days earlier, so the widest window the grid must hold is 6 + 90 = 96 —
        // one more than it has room for, and the reason `dayCount` is not a
        // setting.
        XCTAssertEqual(HistoryHeatmap.dayCount, 90)
        XCTAssertLessThanOrEqual(
            HistoryHeatmap.dayCount + HistoryHeatmap.weekdays - 1,
            Tokens.Heat.columns * HistoryHeatmap.weekdays,
            "ninety days no longer fits fourteen weeks"
        )
    }

    /// The measurement the whole pane rests on: the grid reports one size
    /// whatever is in it. Nothing — which is what the first pass holds — three
    /// days, ninety days, and ninety days every one of which hit its cap and so
    /// draws a different shape.
    @MainActor
    func testTheGridMeasuresTheSameWhateverLandedInIt() throws {
        let settings = try appearance()
        let calendar = try london()
        let end = try date(2021, 4, 30, in: calendar)

        let states: [(String, [HistoryHeatmapCell])] = [
            ("not read yet", []),
            ("three days", grid(filled: 3, endingOn: end, in: calendar)),
            ("ninety days", grid(filled: 90, endingOn: end, in: calendar)),
            ("ninety at the cap", grid(filled: 90, peak: 1, capHits: 4, endingOn: end, in: calendar))
        ]

        var measured: [(String, CGSize)] = []
        for (name, cells) in states {
            let host = hosted(HistoryHeatmap(
                cells: cells, accent: Tokens.Ink.muted, calendar: calendar, appearance: settings
            ))
            measured.append((name, host.fittingSize))
        }

        let sizes = Set(measured.map { "\($0.1.width)x\($0.1.height)" })
        XCTAssertEqual(
            sizes.count, 1,
            "the grid measures \(measured.map { "\($0.0): \($0.1)" }) — it resizes when its data lands"
        )

        // And the box is the reservation, not whatever the cells happened to add
        // up to. The readout is one `Ramp.title` line box over the grid, with
        // `Space.medium` between and `Space.small` above and below:
        // 3 + 13 + 8 + 89 + 6 + 6 = 125.
        let height = try XCTUnwrap(measured.first?.1.height)
        XCTAssertEqual(
            height,
            Tokens.lineBox(Tokens.Ramp.title) + Tokens.Space.medium + Tokens.Heat.height
                + 2 * Tokens.Space.small,
            accuracy: 0.5,
            "the grid is \(height)pt tall, which is not its reservation"
        )
    }

    /// The seven-by-fourteen arrangement, and the eight holes in it.
    ///
    /// The holes are holes and not empty squares: a day before the window opened
    /// is not a day with no readings, it is not in the picture at all.
    func testTheCellsLandInSevenRowsOfFourteenWithTheRestLeftEmpty() throws {
        let calendar = try london()
        let end = try date(2021, 4, 30, in: calendar)
        let cells = grid(filled: 0, endingOn: end, in: calendar)

        let slots = HistoryHeatmap.slots(for: cells)
        XCTAssertEqual(slots.count, HistoryHeatmap.weekdays)
        XCTAssertTrue(slots.allSatisfy { $0.count == Tokens.Heat.columns })
        XCTAssertEqual(
            slots.flatMap { $0 }.compactMap { $0 }.count, HistoryHeatmap.dayCount,
            "a cell was dropped or drawn twice"
        )
        // 7 × 14 − 90 = 8 slots the ninety days do not reach.
        XCTAssertEqual(slots.flatMap { $0 }.filter { $0 == nil }.count, 8)

        // Every cell where the query said it was, once the grid has been pushed
        // right.
        let shift = HistoryHeatmap.shift(for: cells)
        for cell in cells {
            XCTAssertEqual(
                slots[cell.row][cell.column + shift]?.day, cell.day,
                "the cell for \(cell.day) is not at row \(cell.row), column \(cell.column + shift)"
            )
        }
    }

    /// The newest week is always the last column, whichever weekday today is.
    ///
    /// Ninety days spans thirteen weeks on two weekdays out of seven and fourteen
    /// on the other five. Left as the query hands them over the blank week is at
    /// the right, which is where today is — so on those two days the grid would
    /// appear to stop several days ago. The shift moves the hole to the far left.
    func testTodayIsAlwaysInTheLastColumn() throws {
        let calendar = try london()
        // A week of end dates, so every offset between the window's first day and
        // the grid's first Monday is exercised.
        for day in 24...30 {
            let end = try date(2021, 4, day, in: calendar)
            let cells = grid(filled: 0, endingOn: end, in: calendar)
            let shift = HistoryHeatmap.shift(for: cells)
            let last = try XCTUnwrap(cells.last)
            XCTAssertEqual(
                last.column + shift, Tokens.Heat.columns - 1,
                "on \(end) today sits in column \(last.column + shift) of \(Tokens.Heat.columns)"
            )
            XCTAssertTrue(
                cells.allSatisfy { (0..<Tokens.Heat.columns).contains($0.column + shift) },
                "a shifted column fell off the grid on \(end)"
            )
        }
        XCTAssertEqual(HistoryHeatmap.shift(for: []), 0, "an empty grid cannot be shifted anywhere")
    }

    /// Four labels and not seven. The pitch is 13pt and a `Ramp.caption` line
    /// takes 12 of it, so a label on every row is a solid column of type beside a
    /// grid of squares — and it would be the louder of the two.
    func testTheWeekdayGutterLabelsAlternateRowsFromTheCalendarsOwnFirstDay() throws {
        let mondays = try london(firstWeekday: 2)
        let sundays = try london(firstWeekday: 1)

        let labelled = (0..<HistoryHeatmap.weekdays)
            .filter { !HistoryHeatmap.weekdayLabel($0, in: mondays).isEmpty }
        XCTAssertEqual(labelled, [0, 2, 4, 6])

        // Row 0 is the calendar's own first weekday, so the same row is a
        // different day in the two calendars.
        XCTAssertEqual(
            HistoryHeatmap.weekdayLabel(0, in: mondays), mondays.shortWeekdaySymbols[1],
            "row 0 of a week that opens on Monday is not Monday"
        )
        XCTAssertEqual(
            HistoryHeatmap.weekdayLabel(0, in: sundays), sundays.shortWeekdaySymbols[0],
            "row 0 of a week that opens on Sunday is not Sunday"
        )
        XCTAssertEqual(HistoryHeatmap.weekdayLabel(6, in: mondays), mondays.shortWeekdaySymbols[0])

        // The gutter is the labels and their seam together: 24 − 4 = 20.
        XCTAssertEqual(HistoryHeatmap.labelWidth, 20)
        XCTAssertEqual(
            HistoryHeatmap.labelWidth + Tokens.Space.snug, Tokens.Heat.weekdayGutter
        )
    }

    // MARK: - The arrows

    /// One day left and right, one week up and down, clamped at both ends, and
    /// the newest day on a first press with nothing pinned.
    ///
    /// Index arithmetic over the cells rather than calendar arithmetic over the
    /// dates, which is what keeps it right across the spring-forward Sunday this
    /// window contains — adding 86 400 seconds to 27 March 2021 in London lands
    /// at 01:00 on the 28th, not at its midnight.
    func testTheArrowsWalkTheGridADayAndAWeekAtATime() throws {
        let calendar = try london()
        let end = try date(2021, 4, 30, in: calendar)
        let cells = grid(filled: 0, endingOn: end, in: calendar)
        let today = try XCTUnwrap(cells.last).day
        let first = try XCTUnwrap(cells.first).day

        XCTAssertEqual(
            HistoryHeatmap.moved(from: nil, by: -1, in: cells), today,
            "a first arrow press must land on the cell the reader is looking at"
        )
        XCTAssertEqual(HistoryHeatmap.moved(from: nil, by: 7, in: cells), today)

        XCTAssertEqual(HistoryHeatmap.moved(from: today, by: -1, in: cells), cells[88].day)
        XCTAssertEqual(HistoryHeatmap.moved(from: today, by: -7, in: cells), cells[82].day)
        XCTAssertEqual(HistoryHeatmap.moved(from: cells[82].day, by: 7, in: cells), today)

        // Both ends clamp rather than wrap. A grid that jumped from today to
        // three months ago because → was pressed once too often is a grid that
        // lost its place.
        XCTAssertEqual(HistoryHeatmap.moved(from: today, by: 7, in: cells), today)
        XCTAssertEqual(HistoryHeatmap.moved(from: first, by: -7, in: cells), first)

        XCTAssertNil(HistoryHeatmap.moved(from: nil, by: 1, in: []))
        XCTAssertEqual(
            HistoryHeatmap.moved(from: Date(timeIntervalSince1970: 0), by: 1, in: cells), today,
            "a pinned day the grid no longer holds falls back to today rather than to nothing"
        )
    }

    // MARK: - What a cell says

    /// The sentence in the readout, the tooltip and the accessibility value is
    /// one string built once. Zero readings and zero cap hits are omitted: a line
    /// that ends "0 cap hits" on eighty-nine days out of ninety is a line nobody
    /// finishes reading.
    func testACellSaysWhatItHasAndOmitsWhatItHasNot() throws {
        let calendar = try london()
        let day = calendar.startOfDay(for: try date(2021, 4, 12, in: calendar))

        func cell(_ peak: Double?, samples: Int, capHits: Int) -> HistoryHeatmapCell {
            HistoryHeatmapCell(
                day: day, peak: peak, capHits: capHits, samples: samples, column: 0, row: 0
            )
        }

        XCTAssertEqual(HistoryHeatmap.reading(for: cell(nil, samples: 0, capHits: 0)), "no readings")
        XCTAssertEqual(
            HistoryHeatmap.reading(for: cell(0.62, samples: 288, capHits: 1)),
            "peaked \(0.62.formatted(.percent.precision(.fractionLength(0)))), 288 readings, 1 cap hit"
        )
        XCTAssertEqual(
            HistoryHeatmap.reading(for: cell(0.62, samples: 1, capHits: 2)),
            "peaked \(0.62.formatted(.percent.precision(.fractionLength(0)))), 1 reading, 2 cap hits"
        )
        // A day with a peak but no sample count is a hand-edited row; it still
        // has to say the one thing it knows.
        XCTAssertEqual(
            HistoryHeatmap.reading(for: cell(0, samples: 0, capHits: 0)),
            "peaked \(0.0.formatted(.percent.precision(.fractionLength(0))))"
        )

        // The date half is the format `DayRow` uses, so a day named in the grid
        // and the same day named in the table below are one string. Compared
        // against the format rather than against "Mon 12 Apr", which is one
        // locale's answer.
        let name = day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        XCTAssertEqual(HistoryHeatmap.dayName(day), name)
        XCTAssertEqual(
            HistoryHeatmap.sentence(for: cell(nil, samples: 0, capHits: 0)),
            "\(name) · no readings"
        )
    }

    // MARK: - The empty state

    /// The caption under a grid that is mostly holes. Exact strings, because this
    /// is the line that stops eighty-seven empty squares reading as three months
    /// of doing nothing.
    func testTheCoverageCaptionCountsWhatIsRealAndExplainsTheRest() {
        XCTAssertEqual(
            HistoryHeatmap.coverage(filled: 0, of: 90),
            "No readings in the last 90 days. aibars keeps a one-line summary of each day, so this fills in while it runs."
        )
        XCTAssertEqual(
            HistoryHeatmap.coverage(filled: 1, of: 90),
            "1 of the last 90 days has readings. A day with nothing in it is empty rather than zero — readings are only taken while aibars is running, so a gap is a Mac that was asleep, not a quiet day."
        )
        XCTAssertEqual(
            HistoryHeatmap.coverage(filled: 3, of: 90),
            "3 of the last 90 days have readings. A day with nothing in it is empty rather than zero — readings are only taken while aibars is running, so a gap is a Mac that was asleep, not a quiet day."
        )
        // A full grid does not need to be told it is full, and a sentence that
        // never goes away is a sentence nobody reads.
        XCTAssertEqual(
            HistoryHeatmap.coverage(filled: 90, of: 90),
            "90 of the last 90 days have readings."
        )
    }

    /// And the count it is given is the count of days that have readings, not of
    /// days that are non-zero: a day observed at zero is a day the app was
    /// running for.
    func testAThreeDayInstallDrawsNinetySquaresAndCountsThree() throws {
        let calendar = try london()
        let end = try date(2021, 4, 30, in: calendar)
        let cells = grid(filled: 3, peak: 0, endingOn: end, in: calendar)

        XCTAssertEqual(cells.count, HistoryHeatmap.dayCount, "the grid shrank to its data")
        XCTAssertEqual(
            cells.filter({ $0.peak != nil }).count, 3,
            "three days of readings at zero are three days of readings"
        )
        XCTAssertEqual(
            cells.filter({ HeatmapBand.band(peak: $0.peak, warning: 0.95) == .empty }).count, 87
        )
        XCTAssertEqual(
            cells.filter({ HeatmapBand.band(peak: $0.peak, warning: 0.95) == .quiet }).count, 3
        )
    }
}
