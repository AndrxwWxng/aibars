import SwiftUI
import AppKit
import UniformTypeIdentifiers

// ---------------------------------------------------------------------------
// What this file uses of the history model, written down because it is the only
// contract between them and nothing here may widen it.
//
// `UsageHistoryStore` (@MainActor, ObservableObject, `shared` — optional):
//     isEnabled: Bool                                   the recording switch
//     revision: Int                                     bumped when anything moved
//     func series() -> [HistorySeriesID]
//     func samples(for: HistorySeriesID, since: Date) -> [HistorySample]
//     func days(for: HistorySeriesID, since: Date) -> [HistoryDay]
//     func exportCSV(since: Date) -> String
//     func forget(_ providerID: String)
//
// `HistoryRetention.sample` / `.day` — how long each grain survives. Read
//     rather than repeated, because this pane tells the user those numbers and a
//     second copy of them is a sentence that goes quietly out of date.
//
// `HistoryQuery.buckets` — the samples reduced to an even rail of peaks.
//
// Recording, persistence, pruning and the CSV are the store's. The plot is
// `HistoryChart`'s. What is left, and what this file owns, is: which series is
// on screen, over what span, at which grain, what a day of it amounts to in a
// table, and the three things a person can do to an archive — stop adding to
// it, take a copy, throw it away.
// ---------------------------------------------------------------------------

/// How far back the pane is looking.
///
/// Four spans rather than a pair of date fields. A menu bar app's history
/// answers "what did today look like" and "is this week worse than last", and
/// two calendar pickers answer neither any faster.
///
/// Pure, so the spans, their grain and their bucketing can be asserted without
/// hosting a view: everything downstream is handed the `DateInterval` and the
/// bucket count this produces rather than the case itself.
public enum HistoryRange: String, CaseIterable, Identifiable {
    case day, week, month, quarter

    public var id: String { rawValue }

    /// What the segmented control says. Short enough that four of them fit
    /// across a settings form without the control truncating its own labels.
    public var title: String {
        switch self {
        case .day:     return "24h"
        case .week:    return "7d"
        case .month:   return "30d"
        case .quarter: return "90d"
        }
    }

    /// Calendar days the span covers, counting today.
    public var days: Int {
        switch self {
        case .day:     return 1
        case .week:    return 7
        case .month:   return 30
        case .quarter: return 90
        }
    }

    /// What the chart is drawn from over this span.
    public enum Grain {
        /// The readings themselves, reduced to a bucket's peak.
        case readings
        /// One point per day, at that day's peak — which is all that survives
        /// once the readings behind it have been pruned.
        case dailyPeaks
    }

    /// Derived from what the store actually keeps rather than decided here: a
    /// span longer than the readings survive cannot be drawn from readings, and
    /// a chart that quietly showed the last fortnight of a ninety-day range
    /// would be reporting the retention policy as though it were the data.
    public var grain: Grain {
        Double(days) * 24 * 60 * 60 > HistoryRetention.sample ? .dailyPeaks : .readings
    }

    /// How many buckets the chart's rail is divided into, at `.readings` grain.
    ///
    /// Chosen so a bucket is a round unit of time rather than so the counts are
    /// tidy: a quarter of an hour over a day, two hours over a week. The peak
    /// inside a bucket is what gets drawn, so the unit is also the finest spike
    /// the chart can still show.
    public var bucketCount: Int {
        switch self {
        case .day:     return 96
        case .week:    return 84
        // Unused at this grain — a day range is already one point per day — but
        // returning the day count keeps the property total and honest rather
        // than making a caller at the wrong grain fall into a zero.
        case .month:   return 30
        case .quarter: return 90
        }
    }

    /// The span, ending now.
    ///
    /// `.day` is a rolling twenty-four hours: it is the range picked to see what
    /// has happened since this morning, and snapping it to midnight would leave
    /// it nearly empty at 00:05. The others start at the beginning of a day,
    /// because they are read as a table of days, and a rolling 7×24h shows eight
    /// of them with the first and last half-height for no reason a reader can
    /// see.
    public func interval(ending now: Date = Date(), calendar: Calendar = .current) -> DateInterval {
        let start: Date
        switch self {
        case .day:
            start = now.addingTimeInterval(-24 * 60 * 60)
        default:
            // The fallback is the rolling span rather than a trap: a calendar
            // that cannot subtract days is not a reason to lose the pane.
            start = calendar.date(byAdding: .day, value: -(days - 1), to: now)
                .map(calendar.startOfDay(for:))
                ?? now.addingTimeInterval(-Double(days) * 24 * 60 * 60)
        }
        // `DateInterval` traps on an end before its start, and a clock that
        // moved backwards between these two lines is enough to arrange that.
        return DateInterval(start: min(start, now), end: now)
    }
}

/// The History pane of Settings: what one usage window has been doing, and what
/// can be done with the record of it.
///
/// The chart is the content and the archive controls sit under it, in that
/// order, because this pane is opened to look at something rather than to
/// configure something.
///
/// This outer view exists to resolve one optional. `UsageHistoryStore.shared` is
/// `nil` when the database could not be opened — a full disk, a container the
/// app cannot write — and a pane that force-unwrapped it would take the whole
/// settings window down over a feature the app is designed to run without.
public struct HistoryPane: View {
    private let store: UsageHistoryStore?

    /// Resolved in the init body rather than as a default argument, like every
    /// other pane in this window: a default argument is evaluated at the call
    /// site and `shared` is main-actor isolated, so writing it there would
    /// constrain who is allowed to build the pane.
    ///
    /// `nil` therefore means "use the app's store", which may itself be nil.
    /// There is no way to ask for the unavailable state deliberately, and no
    /// reason to want one: it is a state of the machine, not a setting.
    public init(store: UsageHistoryStore? = nil) {
        self.store = store ?? UsageHistoryStore.shared
    }

    public var body: some View {
        if let store {
            HistoryPaneContent(store: store, appearance: AppearanceSettings.shared)
        } else {
            Form {
                Section {
                    Text("aibars couldn't open the file it keeps history in, so nothing is being recorded. Everything else — the panel, alerts, forecasts — carries on without it.")
                        // A section whose whole content is one sentence is body
                        // text in a settings row, which is `Ramp.title`. The 12pt
                        // it used to take is retired: it sat a point under every
                        // native form beside it.
                        .font(.system(size: Tokens.Ramp.title))
                        // `Ink.muted` rather than `.secondary`: the ink ladder is
                        // explicit now, so a sentence that explains a state reads
                        // the same here as a caption does in the panel.
                        .foregroundStyle(Tokens.Ink.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } header: {
                    Text("History")
                } footer: {
                    SectionFooter("The file lives in Application Support. A disk with nothing left on it and a container the app has no permission to write are the two ways this happens.")
                }
            }
            .formStyle(.grouped)
        }
    }
}

/// The pane proper, once there is a store to read.
///
/// Modeless, like every other pane in this window. The recording switch writes
/// through to the store, which persists on change. The range and the series are
/// this view's own state and are deliberately not persisted: which window you
/// were looking at last week is not a preference.
private struct HistoryPaneContent: View {
    @ObservedObject var store: UsageHistoryStore
    @ObservedObject var appearance: AppearanceSettings

    /// The series the user picked, which is not the same as the one on screen:
    /// a series can vanish while this is open — signed out of, pruned, cleared —
    /// and `resolved(in:)` falls back rather than blanking the pane.
    @State private var chosen: HistorySeriesID?
    @State private var range: HistoryRange = .week
    @State private var isConfirmingClear = false
    /// The outcome of the last export, cleared before the next action: a note
    /// left over from a save five minutes ago reads as the answer to the button
    /// just pressed.
    @State private var exportNote: String?

    var body: some View {
        // One clock and one read of the store per pass, so the chart, the table
        // and the export cannot each be describing a slightly different window.
        // `store.revision` is observed, so a reading landing rebuilds this.
        let interval = range.interval()
        let all = store.series()
        let current = resolved(in: all)
        let days = current.map { store.days(for: $0, since: interval.start) } ?? []

        Form {
            chartSection(all: all, current: current, days: days, interval: interval)
            tableSection(current: current, days: days)
            archiveSection(all: all, interval: interval)
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete every reading aibars has kept?",
            isPresented: $isConfirmingClear,
            titleVisibility: .visible
        ) {
            Button("Clear History", role: .destructive) { clear(all) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every service, every window, however far back. Recording carries on, so the record starts again at the next refresh — and nothing about your subscriptions changes.")
        }
    }

    // MARK: - The chart

    @ViewBuilder
    private func chartSection(
        all: [HistorySeriesID],
        current: HistorySeriesID?,
        days: [HistoryDay],
        interval: DateInterval
    ) -> some View {
        Section {
            if all.isEmpty {
                Text(store.isEnabled
                     ? "Nothing recorded yet. aibars keeps a reading each time it refreshes, so this fills in while it runs."
                     : "Nothing recorded, and recording is switched off below.")
                    // Body text, the same size as the message the pane shows when
                    // it has no store at all: both are a section saying what state
                    // it is in, and two sizes for one role is how a form starts
                    // looking assembled from parts.
                    .font(.system(size: Tokens.Ramp.title))
                    .foregroundStyle(Tokens.Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                seriesPicker(all)
                rangePicker

                if let current {
                    // Built once and handed to both the ink and the line: at
                    // `.readings` grain this is a database read and a bucketing
                    // pass, and doing it twice in one body would be two.
                    let points = points(for: current, days: days, interval: interval)

                    HistoryChart(
                        series: [
                            HistoryChartSeries(
                                id: current.storageKey,
                                title: label(for: current),
                                colour: colour(for: current, points: points),
                                points: points
                            )
                        ],
                        range: interval.start...interval.end,
                        warningThreshold: appearance.warningThreshold
                    )

                    Text(grainNote(interval))
                        .font(.system(size: Tokens.Ramp.caption))
                        // Was `.tertiary`. There is no tertiary ink any more: a
                        // line either clears 4.5:1 on its own ground or it is not
                        // worth drawing, and a note explaining what a point on the
                        // chart is worth is worth drawing.
                        .foregroundStyle(Tokens.Ink.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("History")
        } footer: {
            SectionFooter("One usage window at a time. Every account is listed on its own — two logins to one service are spent at their own rates, and a line through both would describe neither.")
        }
    }

    private func seriesPicker(_ all: [HistorySeriesID]) -> some View {
        Picker("Window", selection: seriesSelection(in: all)) {
            ForEach(all, id: \.self) { series in
                Text(label(for: series)).tag(Optional(series))
            }
        }
    }

    private var rangePicker: some View {
        Picker("Range", selection: $range) {
            ForEach(HistoryRange.allCases) { span in
                Text(span.title).tag(span)
            }
        }
        .pickerStyle(.segmented)
    }

    /// The line's points, at whichever grain the range calls for.
    ///
    /// At `.readings` grain the readings are bucketed rather than drawn raw: a
    /// week at a thirty-second refresh is twenty thousand points through a 300pt
    /// rail, and the peak of a bucket is the only reading in it anyone would
    /// have acted on. An empty bucket is dropped rather than plotted at zero —
    /// the chart is told a series may have holes in it, and "nothing was
    /// recorded" is not "the window was empty".
    ///
    /// At `.dailyPeaks` the rollups are already one point per day, and are the
    /// only thing left once the readings behind them have been pruned.
    private func points(
        for series: HistorySeriesID,
        days: [HistoryDay],
        interval: DateInterval
    ) -> [HistorySample] {
        switch range.grain {
        case .dailyPeaks:
            return days.map { Self.point(at: $0.day, ratio: $0.peak) }
        case .readings:
            let count = range.bucketCount
            let peaks = HistoryQuery.buckets(
                store.samples(for: series, since: interval.start),
                from: interval.start,
                to: interval.end,
                count: count
            )
            return peaks.enumerated().compactMap { slot, peak in
                guard let peak else { return nil }
                // Spread across the whole rail rather than placed at the
                // bucket's own start: the chart divides its rail by `count - 1`,
                // so laying the points out the same way is what keeps the
                // pointer reading the bucket it is over.
                let fraction = count > 1 ? Double(slot) / Double(count - 1) : 0
                return Self.point(
                    at: interval.start.addingTimeInterval(interval.duration * fraction),
                    ratio: peak
                )
            }
        }
    }

    /// A chart point from a ratio.
    ///
    /// A day's peak and a bucket's peak are already ratios, which is exactly
    /// what a sample stores. The initialiser clamps, so a non-finite ratio does
    /// not need catching here.
    private static func point(at: Date, ratio: Double) -> HistorySample {
        HistorySample(at: at, percent: ratio)
    }

    /// The ramp colour of the highest point in the range, through the user's own
    /// appearance settings — so a range that hit the wall is drawn in the colour
    /// the row was in when it did, and someone who set the ramp to brand colours
    /// gets a brand-coloured line here too.
    ///
    /// The peak rather than the latest point, because the latest changes on
    /// every refresh and a line that quietly changes colour while you look at it
    /// is reporting the clock rather than the data.
    private func colour(for series: HistorySeriesID, points: [HistorySample]) -> Color {
        // `Ink.muted` is the fallback rather than `.secondary`: a provider that
        // has been signed out of has no brand colour left to lend, and a line
        // filled with a hierarchical style is a line whose colour depends on what
        // is drawing it.
        let accent = AppState.shared.provider(for: series.providerID)?.accentColor ?? Tokens.Ink.muted
        return appearance.tint(for: points.map(\.percent).max() ?? 0, providerAccent: accent)
    }

    /// What one point on the line is worth, said in the words the reader would
    /// use, and derived from the interval rather than written down beside the
    /// bucket count where the two could drift apart.
    private func grainNote(_ interval: DateInterval) -> String {
        switch range.grain {
        case .dailyPeaks:
            return "One point per day, at that day's peak. The readings themselves are kept for \(Self.dayCount(HistoryRetention.sample)) days, so anything longer is drawn from the daily summaries, which are kept for \(Self.dayCount(HistoryRetention.day)) days."
        case .readings:
            let bucket = interval.duration / Double(max(1, range.bucketCount))
            return "One point every \(Self.spanWords(bucket)), at the highest reading in it."
        }
    }

    private static func spanWords(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        if minutes < 60 { return "\(max(1, minutes)) minutes" }
        let hours = Int((seconds / (60 * 60)).rounded())
        return hours == 1 ? "hour" : "\(hours) hours"
    }

    private static func dayCount(_ seconds: TimeInterval) -> Int {
        Int((seconds / (24 * 60 * 60)).rounded())
    }

    // MARK: - Which series

    /// What is actually on screen: the stored choice while it still exists, the
    /// first series otherwise. A pane that empties itself because the series it
    /// was pointed at was pruned is a pane that looks broken.
    private func resolved(in all: [HistorySeriesID]) -> HistorySeriesID? {
        if let chosen, all.contains(chosen) { return chosen }
        return all.first
    }

    /// Reads back what is on screen rather than what was picked, so the picker
    /// cannot sit blank over a chart that is drawing something.
    private func seriesSelection(in all: [HistorySeriesID]) -> Binding<HistorySeriesID?> {
        Binding(
            get: { self.resolved(in: all) },
            set: { self.chosen = $0 }
        )
    }

    /// "Claude · work · 5-hour messages".
    ///
    /// The window's own label comes off the series, which is where the store
    /// keeps the provider's last word for it — the key it is filed under is
    /// deliberately not prose and is only shown when there is no label, which is
    /// the case for a series read back from a version that never stored one.
    ///
    /// The account only earns its place when there is a second account of that
    /// service to tell it apart from, and it is chosen in the order `ServiceRow`
    /// uses: what the user called it, then what the service says, then the
    /// browser profile the session came from.
    ///
    /// The provider can be gone entirely — history outliving a sign-out is much
    /// of why it is kept — and then the row is named by the id it was filed
    /// under. Ugly, and true; inventing a display name for an account that no
    /// longer exists would be worse.
    private func label(for series: HistorySeriesID) -> String {
        let window = series.windowKey
        let state = AppState.shared
        guard let provider = state.provider(for: series.providerID) else {
            return "\(series.providerID) · \(window)"
        }
        let account = state.accountCount(ofService: provider.serviceID) > 1
            ? accountName(for: provider, in: state)
            : nil
        return [provider.displayName, account, window]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    private func accountName(for provider: AnyUsageProvider, in state: AppState) -> String? {
        if let named = AppState.customAccountName(for: provider.id) { return named }
        if case .success(let data) = state.snapshots[provider.id],
           let label = data.accountLabel, !label.isEmpty {
            return label
        }
        return provider.browserOrigin ?? provider.accountID
    }

    // MARK: - The day rollup

    /// How many days get a row of their own.
    ///
    /// A quarter is ninety rows, which turns a settings pane into a scroll with
    /// the controls that govern it a screen and a half below the fold. A month
    /// of them is as much as anyone reads down a column, and the line under the
    /// table accounts for the rest rather than quietly dropping it.
    private static let dayLimit = 31

    @ViewBuilder
    private func tableSection(current: HistorySeriesID?, days: [HistoryDay]) -> some View {
        Section {
            // Newest first: the day being asked about is almost always today.
            let ordered = days.sorted { $0.day > $1.day }
            if ordered.isEmpty {
                Text(current == nil
                     ? "Nothing to summarise yet."
                     : "Nothing was recorded in the last \(range.title).")
                    .font(.system(size: Tokens.Ramp.title))
                    .foregroundStyle(Tokens.Ink.muted)
            } else {
                DayHeaderRow()
                ForEach(ordered.prefix(Self.dayLimit), id: \.day) { day in
                    DayRow(
                        day: day,
                        peakTint: peakTint(day, of: current)
                    )
                }
                if ordered.count > Self.dayLimit {
                    Text("\(ordered.count - Self.dayLimit) more days in this range. The CSV has all of them.")
                        .font(.system(size: Tokens.Ramp.caption))
                        .foregroundStyle(Tokens.Ink.muted)
                }
            }
        } header: {
            Text("By day")
        } footer: {
            // The columns named in the order they are drawn, because they are
            // headed by abbreviations: peak, mean, caps, N.
            SectionFooter("The highest a day reached, the mean of that day's readings, how many times the window crossed its cap, and how many readings the first two rest on. A day with nothing in it is missing rather than shown as zero — readings are only taken while aibars is running, so a gap is a Mac that was asleep, not a quiet day.")
        }
    }

    /// The peak's ink, from the same ramp the panel's figures use, so a day that
    /// hit the wall is the colour the row was in when it did.
    ///
    /// `figureTint` rather than `tint`, which is the difference between a figure
    /// and a meter: under the usage ramp a peak below caution is `Ink.body`, so
    /// thirty-one quiet days are a column of neutral digits and the amber one is
    /// the day worth looking at. A table where every peak carried a resting hue
    /// would spend all of its colour on the days that had nothing wrong with
    /// them. Under `.accent`, `.provider` and `.mono` it defers, because the user
    /// asked for a coloured column and gets one at every level.
    private func peakTint(_ day: HistoryDay, of series: HistorySeriesID?) -> Color {
        let accent = series
            .flatMap { AppState.shared.provider(for: $0.providerID) }?
            .accentColor ?? Tokens.Ink.muted
        return appearance.figureTint(for: day.peak, providerAccent: accent)
    }

    // MARK: - The archive

    private func archiveSection(all: [HistorySeriesID], interval: DateInterval) -> some View {
        Section {
            Toggle("Record usage history", isOn: $store.isEnabled)

            LabeledContent("Archive") {
                HStack(spacing: Tokens.Space.medium) {
                    Button("Export CSV…") { export(interval) }
                        .help("Saves every window, over the range shown above.")
                    Button("Clear History", role: .destructive) {
                        exportNote = nil
                        isConfirmingClear = true
                    }
                }
                .controlSize(.small)
                .disabled(all.isEmpty)
            }

            if let exportNote {
                Text(exportNote)
                    .font(.system(size: Tokens.Ramp.caption))
                    .foregroundStyle(Tokens.Ink.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Kept on this Mac")
        } footer: {
            // There is no slider here on purpose: retention is two constants the
            // store enforces on its own, and a control that promised to move
            // them would be a control over a number nothing reads.
            SectionFooter("Every reading is kept for \(Self.dayCount(HistoryRetention.sample)) days, and a one-line summary of each day for \(Self.dayCount(HistoryRetention.day)), in a file in Application Support that never leaves this Mac. Switching recording off leaves what is already stored. The export covers the range selected above, every window in it, at whichever grain has survived.")
        }
    }

    // MARK: - Clearing

    /// One account at a time, because that is the only delete the store offers —
    /// and it is the right one: signing out of a service is the ordinary way a
    /// history ends, and this is the same operation asked for all of them at
    /// once.
    private func clear(_ all: [HistorySeriesID]) {
        exportNote = nil
        for provider in Set(all.map(\.providerID)).sorted() {
            store.forget(provider)
        }
    }

    // MARK: - Export

    /// Writes what is on screen, as it was when the button was pressed.
    ///
    /// The text is built before the panel opens, so the file holds the range the
    /// user was looking at rather than whatever a refresh added while the save
    /// dialog was up.
    private func export(_ interval: DateInterval) {
        exportNote = nil
        let csv = store.exportCSV(since: interval.start)

        let panel = NSSavePanel()
        panel.nameFieldStringValue = Self.exportName(on: interval.end)
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.isExtensionHidden = false
        // `begin` rather than `runModal`: a modal run loop started from inside a
        // SwiftUI action reenters the update it was called from.
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            do {
                try csv.write(to: url, atomically: true, encoding: .utf8)
                self.exportNote = "Saved \(url.lastPathComponent)."
            } catch {
                self.exportNote = "Couldn't write that file: \(error.localizedDescription)"
            }
        }
    }

    private static func exportName(on date: Date) -> String {
        "aibars-usage-\(fileDate.string(from: date)).csv"
    }

    /// Deliberately not localised, and deliberately not a `FormatStyle`: this is
    /// a filename, and it is written year-first so that a folder of them sorts
    /// into the order they were taken in.
    private static let fileDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

// MARK: - The table

/// The column width the header and every row under it share, named once rather
/// than written into both: a table whose heading is three points off its own
/// column reads as a rendering fault.
private enum DayColumn {
    /// The history pane's figure rail: three digits at `Ramp.title` and a unit
    /// cell at `Ramp.caption`.
    ///
    /// Reserved rather than measured, like every other rail in the app — a
    /// reading arriving, a mean gaining a digit or a day dropping out of range
    /// cannot move the column it is in.
    ///
    /// The figures inside it are set a step down, at `Ramp.caption`, and that is
    /// what buys the rail its margin: five cells rather than four. The widest
    /// value the store can hand over is a day's reading count, which stops at
    /// `2,880` because a second reading inside
    /// `HistoryRetention.minimumInterval` is refused — and both figures are
    /// formatted, so a locale is free to spend a cell on a grouping separator or
    /// on the space it puts before a per-cent sign. Four cells at `Ramp.title`
    /// would fit `100%` here and truncate it in Paris. A percent itself cannot
    /// run away: `HistorySample` clamps to 0...1. Something wider than all of
    /// that came off a database edited by hand, and it truncates instead of
    /// widening the column, which is what reserving a rail is for.
    ///
    /// It is narrower than the words that used to head these columns, and the
    /// headings were shortened to it rather than the other way round: the rail
    /// belongs to the figure, and it is the figures that are read down.
    static let figure = Tokens.figureWidth(Tokens.Ramp.title, digits: 3)
        + Tokens.Space.hairline
        + Tokens.figureWidth(Tokens.Ramp.caption, digits: 1)
}

/// The headings over the table, in the one recipe this app heads a group with:
/// sentence case, `.medium`, `Ink.muted`, no tracking, unscaled. `SectionLabel`'s
/// recipe in the panel, at this table's size, because a label over a group of
/// rows and a label over a column of figures are the same object.
///
/// What went was the uppercasing and the letter spacing. SF has its optical
/// tracking baked in, so tracked small caps are a correction for a face this app
/// does not use, and an all-caps heading over a column is the treatment that
/// reads as a template rather than a design.
///
/// The size stays `Ramp.caption` where the panel's label is `Ramp.detail`: this
/// one heads a column of `Ramp.caption` figures, and a heading set larger than
/// the figures under it is a heading that has stopped being a label. `Ink.muted`
/// rather than a dimmer ink for the same reason it always was — a heading nobody
/// reads is texture.
///
/// The words are abbreviated to the figure rail. `Mean` is the figure the row
/// actually holds, and `Caps` is both shorter than `Resets` and truer — what is
/// counted is how many times the window crossed its cap, which is not the same
/// event as the window rolling over. `N` is the count the two figures beside it
/// rest on, which is what `N` means anywhere a mean is quoted.
private struct DayHeaderRow: View {
    /// The rule under the headings is a hairline, and a hairline is the first
    /// thing a low-contrast display loses.
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        VStack(spacing: Tokens.Space.snug) {
            HStack(spacing: Tokens.Space.gutter) {
                Text("Day")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Peak")
                    .frame(width: DayColumn.figure, alignment: .trailing)
                Text("Mean")
                    .frame(width: DayColumn.figure, alignment: .trailing)
                Text("Caps")
                    .frame(width: DayColumn.figure, alignment: .trailing)
                Text("N")
                    .frame(width: DayColumn.figure, alignment: .trailing)
            }
            .font(.system(size: Tokens.Ramp.caption, weight: Tokens.Ramp.emphasisWeight))
            .foregroundStyle(Tokens.Ink.muted)
            // A heading that wraps takes the row's height with it and stops lining
            // up with the column it names. The scale floor is there for a locale
            // or a font metric that measures a heading a point wider than this
            // platform does, not as room to head a column with a sentence.
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            // A heading over a table earns a rule, which the panel's section
            // labels no longer do — a word over a group of rows is a word, but a
            // word over a column of figures is a column head, and this is the
            // line that says where the heads stop and the readings start. It is
            // the app's one rule weight: 1pt, at `ruleOpacity`, stepping up under
            // increased contrast. A `Rectangle` rather than a `Divider` because a
            // `Divider` brings its own material and a second weight with it.
            Rectangle()
                .fill(Tokens.quiet(Tokens.ruleOpacity(increased: contrast == .increased)))
                .frame(height: Tokens.Control.hairline)
        }
    }
}

/// One day of one series: how high it got, what it averaged, how often it
/// crossed its cap, and how many readings the first two rest on.
private struct DayRow: View {
    let day: HistoryDay
    /// The ink on the peak cell, decided by the pane from the appearance
    /// settings — a row has no business holding a second opinion about what 92%
    /// looks like.
    let peakTint: Color

    var body: some View {
        HStack(spacing: Tokens.Space.gutter) {
            // A run with a word in it, so SF Pro with tabular digits rather than
            // the figure face: "Mon 11 Aug" is not a number.
            Text(day.day, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                .font(.system(size: Tokens.Ramp.title))
                .monospacedDigit()
                .lineLimit(1)
                // The row's subject, so `Ink.body` — which is the point of having
                // it: `Color.primary` on the new near-black is pure white, and a
                // column of thirty-one dates at 17:1 is the loudest thing in the
                // window for the least reason.
                .foregroundStyle(Tokens.Ink.body)
                .frame(maxWidth: .infinity, alignment: .leading)

            percentCell(day.peak, weight: Tokens.Ramp.emphasisWeight)
                .foregroundStyle(peakTint)

            percentCell(day.mean, weight: .regular)
                .foregroundStyle(Tokens.Ink.muted)

            countCell(day.capHits)
                // A window that crossed its cap is the one fact in this row worth
                // finding by eye; a day it did not is a zero like any other. The
                // step is up the ink ladder rather than down through an opacity:
                // a figure dimmed to 40% is a figure under 4.5:1, and this pass
                // has no ink that fails its own ground.
                .foregroundStyle(day.capHits > 0 ? Tokens.Ink.body : Tokens.Ink.muted)

            countCell(day.samples)
                .foregroundStyle(Tokens.Ink.muted)
        }
        .padding(.vertical, Tokens.Space.hairline)
        // Where the tenth of a percent the columns round away survives.
        .help(detail)
    }

    /// "peaked at 92.4%, from 288 readings".
    ///
    /// No used/limit pair: history is stored as ratios, deliberately, so that a
    /// provider rewording its units or changing its cap mid-range cannot make
    /// an archived row unreadable. The sample count is the honest thing to put
    /// beside a peak — it says how much of the day the figure rests on.
    private var detail: String {
        let percent = (day.peak * 100).formatted(.number.precision(.fractionLength(1)))
        guard day.samples > 0 else { return "peaked at \(percent)%" }
        let readings = day.samples == 1 ? "1 reading" : "\(day.samples) readings"
        return "peaked at \(percent)%, from \(readings)"
    }

    /// Formatted rather than interpolated, so the separator and the placement of
    /// the sign stay the reader's — and rounded to whole percent, which is the
    /// rule everywhere outside a hover readout: a tenth of a percent across a
    /// whole day is noise.
    ///
    /// The unit rides inside the run here rather than being set as a separate
    /// muted tick. That treatment is for a row's headline answer; a column of
    /// thirty-one of them is a column of ticks. The rail still reserves a cell
    /// for it, because the cell is what the `%` occupies either way.
    private func percentCell(_ ratio: Double, weight: Font.Weight) -> some View {
        Text(ratio, format: .percent.precision(.fractionLength(0)))
            .font(.system(size: Tokens.Ramp.caption, weight: weight, design: Tokens.Ramp.figureDesign))
            .lineLimit(1)
            .frame(width: DayColumn.figure, alignment: .trailing)
    }

    private func countCell(_ value: Int) -> some View {
        Text(value, format: .number)
            .font(.system(size: Tokens.Ramp.caption, design: Tokens.Ramp.figureDesign))
            .lineLimit(1)
            .frame(width: DayColumn.figure, alignment: .trailing)
    }
}
