import SwiftUI

// ---------------------------------------------------------------------------
// Ninety days of one usage window, one square a day.
//
// Three things are settled here and nowhere else, and they are the three a
// heatmap normally gets wrong:
//
// 1. **The scale is luminance, not hue.** `Tokens.Heat` is one neutral getting
//    darker in light and lighter in dark, and the only cells that take a colour
//    are the ones at or over the user's own warning line. The reasoning is on
//    the token; what is enforced here is that `ink(for:)` has exactly one branch
//    that reaches `AppearanceSettings.tint`, and it is the `.alarm` one.
// 2. **The box never moves.** The grid is `Tokens.Heat.width` × `.height`
//    whatever landed in it — no cells, three days, ninety — and the readout over
//    it is one reserved line in two states. A pane that grew when its data
//    arrived, or when the pointer crossed it, is the defect this whole rollout
//    has been about.
// 3. **A cap hit is a shape.** A day the window crossed its cap loses its
//    corners rather than gaining a sixth colour, so it survives greyscale, a
//    deuteranope and `ColorRamp.mono` — the same channel `MeterFill` uses for
//    the same reason.
//
// The grid is one focus target and not ninety. Ninety tab stops between a
// picker and a toggle is hostile, so the container is `.focusable()` and the
// arrows walk a pinned day inside it.
// ---------------------------------------------------------------------------

/// Which of the six inks a cell takes.
///
/// Pure and separate from the view, for the reason every threshold decision in
/// this app is: a band is where the drawing is right or wrong, and it should not
/// need a host to be asserted.
public enum HeatmapBand: Int, CaseIterable, Equatable {
    /// No readings that day.
    case empty
    case quiet, light, moderate, heavy
    /// At or over the user's own warning threshold. The one band that carries a
    /// hue, and the reason the other four do not.
    case alarm

    /// The four filled neutral steps are even quarters of the range below the
    /// warning line, so moving the threshold in Appearance moves the whole ramp
    /// with it and the legend under the grid stays true. Fixed absolute stops
    /// would leave a user who set their warning to 0.60 with two bands they can
    /// never reach and a legend that lies about the other two.
    ///
    /// A day whose peak is exactly zero is `.quiet` and never `.empty`: it had
    /// readings and they all said zero, which is a different fact from a mac
    /// that was asleep, and a grid that drew them the same would be the one
    /// place in the app that conflates them.
    ///
    /// A non-finite peak — nothing upstream sends one; `HistorySample` clamps and
    /// the database's ratio clamps — answers `.empty` rather than surviving into
    /// a comparison it would lose. A non-finite or non-positive `warning` is the
    /// same kind of input from the other side, and it is answered without ever
    /// dividing by it: everything above nothing is over a threshold of nothing.
    public static func band(peak: Double?, warning: Double) -> HeatmapBand {
        guard let peak, peak.isFinite else { return .empty }
        guard warning.isFinite, warning > 0 else { return peak > 0 ? .alarm : .quiet }
        if peak >= warning { return .alarm }
        switch peak / warning {
        case ..<0.25: return .quiet
        case ..<0.50: return .light
        case ..<0.75: return .moderate
        default:      return .heavy
        }
    }
}

/// The grid itself: a reserved line of readout, then seven rows of fourteen
/// squares under a column of weekday labels.
///
/// It takes cells rather than a store and a date. Which ninety days these are,
/// and which calendar laid them out, are the pane's decisions — the same two
/// decisions `HistoryQuery.heatmap` takes a calendar for — and a view that
/// worked them out again would be a second copy of them.
public struct HistoryHeatmap: View {
    /// The days the grid draws, oldest first, at most one per day.
    ///
    /// Empty is a legitimate state and is drawn as the full grid with nothing in
    /// it: it is what the pane holds before its first read lands, and a grid that
    /// waited for data before reserving its box would resize under the reader.
    public let cells: [HistoryHeatmapCell]
    /// The provider's own colour, for the `.provider` ramp. Only `.alarm` ever
    /// reaches it.
    public let accent: Color
    public let calendar: Calendar
    @ObservedObject public var appearance: AppearanceSettings

    public init(
        cells: [HistoryHeatmapCell],
        accent: Color,
        calendar: Calendar,
        appearance: AppearanceSettings
    ) {
        self.cells = cells
        self.accent = accent
        self.calendar = calendar
        self.appearance = appearance
    }

    /// Days on the grid.
    ///
    /// Named here and passed to `HistoryQuery.heatmap` by the pane rather than
    /// left to that function's own default, so the number the grid reserves for,
    /// the number it announces to VoiceOver and the number it is filled with are
    /// one value. Fourteen columns hold ninety-five days, so this may rise to 95
    /// without the grid reflowing and cannot rise past it without `Tokens.Heat`
    /// moving too.
    public static let dayCount = 90

    /// Rows on the grid. Seven, because a week is seven days; written down
    /// because `Tokens.Heat.height` is `7 * pitch - gap` and the two have to be
    /// the same seven.
    static let weekdays = 7

    // MARK: - State

    /// The day under the pointer, if any. Cleared on exit rather than latched:
    /// the readout falls back to the pinned day, and to the legend under that.
    @State private var hovered: Date?
    /// The day the reader asked to keep. Clicking a cell pins it so the pointer
    /// can leave; clicking the pinned cell unpins.
    @State private var pinned: Date?
    @FocusState private var isFocused: Bool

    public var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Space.medium) {
            readoutLine
            HStack(alignment: .top, spacing: Tokens.Space.snug) {
                weekdayColumn
                grid
            }
        }
        // The same vertical air `HistoryChart` takes, and for the same reason:
        // the legend must not sit on the picker above it, and the caption under
        // the grid must not sit on the grid.
        .padding(.vertical, Tokens.Space.small)
        // One target, not ninety. `.onKeyPress` is macOS 14 and the floor here is
        // 13, so pin and unpin are the click only; the arrows walk the pinned day
        // and the value below is what says where it got to.
        .focusable()
        .focused($isFocused)
        .onMoveCommand { direction in
            switch direction {
            case .left:  step(-1)
            case .right: step(1)
            case .up:    step(-Self.weekdays)
            case .down:  step(Self.weekdays)
            @unknown default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Usage heatmap, last \(Self.dayCount) days")
        .accessibilityValue(focusValue)

        // No month labels along the top, deliberately. They would be a second
        // axis over a grid whose every square already names its own day in a
        // tooltip, in the readout and in its accessibility label — and they
        // would have to be reserved above the grid, which is the one dimension
        // `Tokens.Heat.height` exists to hold still.
    }

    // MARK: - The readout

    /// One line above the grid, in two states and one height: the legend at
    /// rest, and the day being pointed at while there is one. The same
    /// construction as `HistoryChart.readoutLine`, and for the identical reason —
    /// a readout that appeared on hover would grow the pane that summoned it.
    ///
    /// Hover beats pin while the pointer is on the grid. Pinning exists so the
    /// pointer can *leave*, not so it can be ignored while it is still there.
    private var readoutLine: some View {
        HStack(spacing: Tokens.Space.large) {
            if let cell = readoutCell {
                Text(Self.sentence(for: cell))
                    // A sentence with a date in it, so SF Pro with tabular digits
                    // rather than the figure face: "Mon 11 Aug" is not a number.
                    // `.regular`, written down rather than inherited, because this
                    // is the line that annotates the grid rather than a reading in
                    // its own right.
                    .font(.system(size: Tokens.Ramp.detail, weight: .regular))
                    .monospacedDigit()
                    // `.foregroundColor` and never `.foregroundStyle` on a `Text`:
                    // with a `Text` receiver the compiler binds the macOS 14
                    // overload that returns `Text` and silently raises the app's
                    // floor past the stated minimum.
                    .foregroundColor(Tokens.Ink.body)
                    .lineLimit(1)
                    .fixedSize()
                Spacer(minLength: 0)
            } else {
                legend
            }
        }
        .frame(height: Tokens.lineBox(Tokens.Ramp.title), alignment: .leading)
    }

    private var readoutCell: HistoryHeatmapCell? {
        guard let day = hovered ?? pinned else { return nil }
        return cells.first { $0.day == day }
    }

    /// `Less`, the five inks in order, `More`; then the cap-hit key, which is a
    /// shape rather than a sixth ink and so is shown as one.
    private var legend: some View {
        HStack(spacing: Tokens.Space.large) {
            HStack(spacing: Tokens.Space.snug) {
                legendWord("Less")
                ForEach(Array(Self.ramp.enumerated()), id: \.offset) { _, ink in
                    swatch(ink, radius: Tokens.Heat.radius)
                }
                legendWord("More")
            }
            HStack(spacing: Tokens.Space.snug) {
                swatch(Tokens.Heat.step4, radius: 0)
                legendWord("cap hit")
            }
            Spacer(minLength: 0)
        }
        // Read as one thing. Five swatches announced one at a time is five
        // announcements of "image", and the words between them are what the
        // legend actually says.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Legend: less to more, and a square corner for a day that crossed its cap")
    }

    private func legendWord(_ word: String) -> some View {
        Text(word)
            .font(.system(size: Tokens.Ramp.caption, weight: .regular))
            .foregroundColor(Tokens.Ink.muted)
            .lineLimit(1)
            .fixedSize()
    }

    /// A legend key is the same square the grid draws, at the same size. A key
    /// set smaller than the thing it explains is a different object.
    private func swatch(_ ink: Color, radius: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(ink)
            .frame(width: Tokens.Heat.cell, height: Tokens.Heat.cell)
    }

    /// The five neutral steps in reading order, which is also the order the
    /// legend prints them in and the order `HeatmapBand` declares them in.
    static let ramp: [Color] = [
        Tokens.Heat.empty,
        Tokens.Heat.step1,
        Tokens.Heat.step2,
        Tokens.Heat.step3,
        Tokens.Heat.step4
    ]

    // MARK: - The grid

    /// The weekday abbreviations down the left, on alternate rows.
    ///
    /// Every other row and not every row: the pitch is 13pt and a `Ramp.caption`
    /// line is 12pt of it, so seven labels would be a solid column of type beside
    /// a grid of squares and would read as the louder of the two. Four of them,
    /// starting at the calendar's own first weekday, is enough to find a row by.
    private var weekdayColumn: some View {
        VStack(alignment: .trailing, spacing: Tokens.Heat.gap) {
            ForEach(0..<Self.weekdays, id: \.self) { row in
                Text(Self.weekdayLabel(row, in: calendar))
                    .font(.system(size: Tokens.Ramp.caption, weight: .regular))
                    .foregroundColor(Tokens.Ink.muted)
                    // One line, and allowed to shrink rather than to widen: the
                    // abbreviation is the reader's locale's, and a locale that
                    // writes four letters must shrink its label instead of moving
                    // the grid.
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(width: Self.labelWidth, height: Tokens.Heat.cell, alignment: .trailing)
            }
        }
        // The row a square is on is in every cell's own label already, and a
        // column of weekday names read out before the data is a column of noise.
        .accessibilityHidden(true)
    }

    /// The gutter less the seam to the grid, so `weekdayGutter` is what the
    /// labels and their gap cost together: 24 − 4 = 20.
    static let labelWidth = Tokens.Heat.weekdayGutter - Tokens.Space.snug

    /// The abbreviation for a grid row, or nothing on the rows that are not
    /// labelled.
    ///
    /// Row 0 is the calendar's `firstWeekday`, so the index into the symbols is
    /// `(firstWeekday - 1 + row) % 7` — `firstWeekday` is 1-based and the symbol
    /// array is 0-based from Sunday.
    static func weekdayLabel(_ row: Int, in calendar: Calendar) -> String {
        guard row % 2 == 0 else { return "" }
        let symbols = calendar.shortWeekdaySymbols
        guard symbols.count == weekdays else { return "" }
        return symbols[(calendar.firstWeekday - 1 + row) % weekdays]
    }

    private var grid: some View {
        // Built once here rather than looked up inside two nested `ForEach`es,
        // which would be ninety-eight scans of ninety cells per pass.
        let slots = Self.slots(for: cells)
        return VStack(spacing: Tokens.Heat.gap) {
            ForEach(0..<Self.weekdays, id: \.self) { row in
                HStack(spacing: Tokens.Heat.gap) {
                    ForEach(0..<Tokens.Heat.columns, id: \.self) { column in
                        slot(slots[row][column])
                    }
                }
            }
        }
        // Stated as well as built, so a cell or a gap that moved is a failing
        // measurement here rather than a form that quietly reflows around it.
        .frame(width: Tokens.Heat.width, height: Tokens.Heat.height)
    }

    @ViewBuilder
    private func slot(_ cell: HistoryHeatmapCell?) -> some View {
        if let cell {
            Button { pin(cell.day) } label: { square(cell) }
                .buttonStyle(.plain)
                // The same sentence the readout shows, so the reading is
                // available without the pointer having to find the line above the
                // grid — and in the idiom the day table beneath already uses.
                .help(Self.sentence(for: cell))
                .onHover { inside in
                    if inside { hovered = cell.day }
                    else if hovered == cell.day { hovered = nil }
                }
                .accessibilityLabel(Self.dayName(cell.day))
                .accessibilityValue(Self.reading(for: cell))
                .accessibilityAddTraits(.isButton)
        } else {
            // A day before the ninety opened, or after today. A hole and not an
            // empty square: an empty square means "no readings that day", and a
            // day outside the window is not a day with no readings.
            Color.clear
                .frame(width: Tokens.Heat.cell, height: Tokens.Heat.cell)
                .accessibilityHidden(true)
        }
    }

    private func square(_ cell: HistoryHeatmapCell) -> some View {
        // A day the window crossed its cap loses its corners. The shape is the
        // one channel that survives greyscale, `ColorRamp.mono` and a reader who
        // cannot separate the amber from the red — and `capHits` and `peak` are
        // different questions, so it cannot be folded into the ink: a day can sit
        // at 98% and never cross, and a day can cross and end low.
        let shape = RoundedRectangle(
            cornerRadius: cell.capHits > 0 ? 0 : Tokens.Heat.radius,
            style: .continuous
        )
        return shape
            .fill(ink(for: cell))
            .overlay {
                if pinned == cell.day {
                    // `strokeBorder` and not `stroke`: an inside ring stays within
                    // the square's own 11pt and cannot eat the 2pt seam, which is
                    // what would shift every cell after it.
                    shape.strokeBorder(
                        isFocused ? Color.accentColor : Tokens.Ink.body,
                        lineWidth: Tokens.Control.hairline
                    )
                }
            }
            .frame(width: Tokens.Heat.cell, height: Tokens.Heat.cell)
    }

    /// The ink a cell takes, which is the whole colour rule in six lines.
    ///
    /// `.alarm` goes through `AppearanceSettings.tint(for:providerAccent:)` and
    /// never at the warning colour directly, because that function already
    /// answers `warningColor` for *every* ramp at or above the threshold —
    /// including `.mono`, whose whole promise is that colour returns only above
    /// the warning line. A grid that reached for the hue itself would be a second
    /// opinion about a setting standing right next to it.
    func ink(for cell: HistoryHeatmapCell) -> Color {
        switch HeatmapBand.band(peak: cell.peak, warning: appearance.warningThreshold) {
        case .empty:    return Tokens.Heat.empty
        case .quiet:    return Tokens.Heat.step1
        case .light:    return Tokens.Heat.step2
        case .moderate: return Tokens.Heat.step3
        case .heavy:    return Tokens.Heat.step4
        // The band is `.alarm` only where `peak >= warning`, so the fallback is
        // unreachable; it is 1 rather than 0 so that an unreachable branch cannot
        // resolve to a *quiet* colour if it ever becomes reachable.
        case .alarm:    return appearance.tint(for: cell.peak ?? 1, providerAccent: accent)
        }
    }

    // MARK: - Where a cell sits

    /// The cells arranged as seven rows of fourteen, with `nil` in every slot the
    /// ninety days do not reach.
    static func slots(for cells: [HistoryHeatmapCell]) -> [[HistoryHeatmapCell?]] {
        var grid = [[HistoryHeatmapCell?]](
            repeating: [HistoryHeatmapCell?](repeating: nil, count: Tokens.Heat.columns),
            count: weekdays
        )
        let shift = shift(for: cells)
        for cell in cells {
            let column = cell.column + shift
            guard grid.indices.contains(cell.row),
                  (0..<Tokens.Heat.columns).contains(column)
            else { continue }
            grid[cell.row][column] = cell
        }
        return grid
    }

    /// How far right the query's columns are pushed so the newest week lands on
    /// the grid's last column.
    ///
    /// Ninety days spans fourteen weeks on five weekdays out of seven and
    /// thirteen on the other two — the grid opens on the week containing the
    /// oldest day, which is between 0 and 6 days before it, so the newest day
    /// sits at column (offset + 89) / 7, which is 12 or 13. Left as it comes, the
    /// blank week would be at the *right*, which is where today is: the grid
    /// would appear to end two days ago on Mondays and Tuesdays. Shifting instead
    /// puts the hole at the far left, where it is a fortnight nobody is looking
    /// at, and keeps today's column against the same edge every day of the week.
    static func shift(for cells: [HistoryHeatmapCell]) -> Int {
        guard let widest = cells.map(\.column).max() else { return 0 }
        return max(0, Tokens.Heat.columns - 1 - widest)
    }

    // MARK: - Pinning and the arrows

    private func pin(_ day: Date) {
        pinned = (pinned == day) ? nil : day
    }

    private func step(_ days: Int) {
        pinned = Self.moved(from: pinned, by: days, in: cells)
    }

    /// Where an arrow key lands.
    ///
    /// Index arithmetic and not calendar arithmetic: `cells` is one entry per
    /// day, oldest first, so ±1 is a day and ±7 is a week by construction — and
    /// it stays right across a clock change, which adding 86 400 seconds to a
    /// date would not.
    ///
    /// A first arrow press with nothing pinned pins the newest day, which is the
    /// cell a reader is looking at. Both ends clamp rather than wrap: a grid that
    /// jumped from today to three months ago because the reader pressed → once
    /// too often is a grid that lost its place.
    static func moved(from pinned: Date?, by step: Int, in cells: [HistoryHeatmapCell]) -> Date? {
        guard !cells.isEmpty else { return nil }
        guard let pinned, let index = cells.firstIndex(where: { $0.day == pinned }) else {
            return cells.last?.day
        }
        return cells[min(max(index + step, 0), cells.count - 1)].day
    }

    /// What the focused grid announces: the pinned day, or an instruction if
    /// nothing is pinned yet. A focus ring with no value on it is a control
    /// VoiceOver describes as empty.
    private var focusValue: String {
        guard let day = pinned, let cell = cells.first(where: { $0.day == day }) else {
            return "No day selected. Arrow keys select a day."
        }
        return "\(Self.dayName(cell.day)), \(Self.reading(for: cell))"
    }

    // MARK: - What a cell says

    /// "Mon 11 Aug · peaked 62%, 288 readings, 1 cap hit".
    ///
    /// The date is the same format `DayRow` uses, so a day named in the grid and
    /// the same day named in the table below are one string. Readings and cap
    /// hits are omitted when they are zero — a line that ends "0 cap hits" on
    /// eighty-nine days out of ninety is a line nobody finishes reading.
    public static func sentence(for cell: HistoryHeatmapCell) -> String {
        "\(dayName(cell.day)) · \(reading(for: cell))"
    }

    static func dayName(_ day: Date) -> String {
        day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
    }

    /// The reading half of the sentence, which is also the cell's accessibility
    /// value: a label and a value are the day and what it did, and saying the
    /// date twice is what makes a grid unbearable to hear.
    static func reading(for cell: HistoryHeatmapCell) -> String {
        guard let peak = cell.peak else { return "no readings" }
        var parts = ["peaked \(peak.formatted(.percent.precision(.fractionLength(0))))"]
        if cell.samples > 0 {
            parts.append(cell.samples == 1 ? "1 reading" : "\(cell.samples) readings")
        }
        if cell.capHits > 0 {
            parts.append(cell.capHits == 1 ? "1 cap hit" : "\(cell.capHits) cap hits")
        }
        return parts.joined(separator: ", ")
    }

    /// What the grid could not say for itself: how much of it is real.
    ///
    /// Always the count, and the retention sentence only while there is a gap to
    /// explain — a full grid does not need to be told it is full, and a sentence
    /// that never goes away is a sentence nobody reads.
    ///
    /// The three-day install is the case this exists for: eighty-seven empty
    /// squares are the truth, and without a line under them they read as three
    /// months of doing nothing.
    public static func coverage(filled: Int, of total: Int) -> String {
        if filled == 0 {
            return "No readings in the last \(total) days. aibars keeps a one-line summary of each day, so this fills in while it runs."
        }
        let days = filled == 1
            ? "1 of the last \(total) days has readings"
            : "\(filled) of the last \(total) days have readings"
        guard filled < total else { return "\(days)." }
        return "\(days). A day with nothing in it is empty rather than zero — readings are only taken while aibars is running, so a gap is a Mac that was asleep, not a quiet day."
    }
}
