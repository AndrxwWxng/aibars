import Foundation

/// One kept reading of one usage window.
///
/// Deliberately not `UsageSample`. That one is the forecast's input: it is
/// trimmed to the last half hour, it is thrown away when a service signs out,
/// and its shape follows whatever the fit currently wants. This one is kept for
/// months, so the two are allowed to move apart.
public struct HistorySample: Equatable, Codable, Sendable {
    public let at: Date
    /// 0...1. Clamped here rather than trusted, the same way `UsageSample`
    /// does it: a NaN loses every comparison it takes part in, so it would
    /// survive `max` and quietly become a day's peak.
    public let percent: Double

    public init(at: Date, percent: Double) {
        self.at = at
        self.percent = percent.isFinite ? min(max(percent, 0), 1) : 0
    }

    private enum CodingKeys: String, CodingKey {
        case at
        case percent
    }

    /// History outlives the version that wrote it, so what comes back off disk
    /// is untrusted input like any other and decoding goes through the clamping
    /// initialiser.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            at: try container.decode(Date.self, forKey: .at),
            percent: try container.decode(Double.self, forKey: .percent)
        )
    }
}

/// What one day of readings amounts to: the unit a heatmap cell colours and a
/// long chart plots.
public struct HistoryDay: Equatable, Codable, Sendable {
    /// Midnight, in the calendar the roll-up was given. The calendar carries the
    /// time zone, which is why it is passed in rather than read from the
    /// machine — a day boundary is a display decision and a test needs to pin it.
    public let day: Date
    /// The highest reading of the day. The one figure worth colouring a cell by:
    /// how close the day came to stopping work.
    public let peak: Double
    /// The mean of the readings, not a time-weighted average. It is therefore a
    /// summary of what was observed, and `samples` says how much of the day that
    /// was.
    public let mean: Double
    /// How many times the window reached its cap that day, counted as crossings
    /// rather than as readings at the cap. Counting readings would make the
    /// number a measure of the polling interval — a heatmap that says a capped
    /// afternoon is worse on a fast refresh than on a slow one is measuring the
    /// app, not the subscription.
    public let capHits: Int
    /// How many readings the other three rest on. Published because a mean over
    /// two samples and a mean over two hundred are not the same claim, and only
    /// the caller knows whether it wants to say so.
    public let samples: Int

    public init(day: Date, peak: Double, mean: Double, capHits: Int, samples: Int) {
        self.day = day
        self.peak = peak
        self.mean = mean
        self.capHits = capHits
        self.samples = samples
    }
}

/// One square on a heatmap: a day, what it came to, and where it sits.
///
/// Where it sits is carried rather than left to the drawing, because the grid's
/// two coordinates are the same calendar decision the day boundary is — a week
/// that opens on Saturday is one `firstWeekday` away — and a view that worked
/// them out again would be a second copy of it.
public struct HistoryHeatmapCell: Equatable, Sendable, Identifiable {
    /// Midnight, in the calendar the grid was laid out in.
    public let day: Date
    /// The day's highest reading, or nil for a day with no readings at all. Nil
    /// and not zero, for the reason it is nil everywhere else in this file.
    public let peak: Double?
    public let capHits: Int
    public let samples: Int
    /// Which week column, counting from the grid's own first week.
    public let column: Int
    /// Which weekday row, 0 at the calendar's own `firstWeekday`.
    public let row: Int

    public init(day: Date, peak: Double?, capHits: Int, samples: Int, column: Int, row: Int) {
        self.day = day
        self.peak = peak
        self.capHits = capHits
        self.samples = samples
        self.column = column
        self.row = row
    }

    public var id: Date { day }
}

/// Which series a sample belongs to: one account's one window.
///
/// Two keys, not one, because a service's windows run at their own rates —
/// Claude's five-hour window and its weekly cap are separate lines on a chart
/// and separate rows in a store. `providerID` is the account id ("claude#2"),
/// never the service, for the reason it is everywhere else: two subscriptions
/// are spent independently.
public struct HistorySeriesID: Hashable, Codable, Sendable {
    public let providerID: String
    /// A stable key for the window, not its label. The label is prose the
    /// provider chose and may be reworded between releases; a key that moved
    /// would orphan every reading filed under the old one.
    public let windowKey: String

    public init(providerID: String, windowKey: String) {
        self.providerID = providerID
        self.windowKey = windowKey
    }

    /// The two parts flattened into one string a store can file rows under.
    ///
    /// Both halves are percent-encoded down to alphanumerics before they are
    /// joined, so the separator cannot occur inside either. Composing the key by
    /// hand would be shorter and wrong: account ids already carry "#", and a
    /// window key is whoever-wired-this-up's choice, so a raw join is one
    /// unlucky string away from two series sharing a row.
    /// `HistorySeriesID(storageKey: id.storageKey) == id`, always.
    public var storageKey: String {
        Self.encode(providerID) + Self.separator + Self.encode(windowKey)
    }

    /// `nil` for anything this type did not write. Callers enumerate stored keys
    /// to find out what history exists, so a key from an older shape has to be
    /// recognisable as unreadable rather than parsed into a series that never
    /// existed.
    public init?(storageKey: String) {
        let parts = storageKey.split(
            separator: Character(Self.separator),
            omittingEmptySubsequences: false
        )
        guard parts.count == 2,
              let providerID = String(parts[0]).removingPercentEncoding,
              let windowKey = String(parts[1]).removingPercentEncoding
        else { return nil }
        self.init(providerID: providerID, windowKey: windowKey)
    }

    /// A dot, because it is not alphanumeric and therefore never survives the
    /// encoding above, and because it reads as a path in a defaults key.
    private static let separator = "."

    private static func encode(_ part: String) -> String {
        // The allowed set is deliberately the narrowest useful one: everything
        // that is not a letter or a digit is escaped, including the "%" that
        // does the escaping, so the round trip is exact.
        part.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? part
    }
}

/// Every decision the history view makes, as pure functions over an array.
///
/// Kept apart from whatever stores the samples on purpose. Bucketing, reset
/// detection and the daily roll-up are where a history feature is actually
/// right or wrong, and none of them need a database, a file, or a clock to be
/// asserted against — so none of them are allowed to acquire one.
public enum HistoryQuery {
    /// At or above this, the window is treated as capped.
    ///
    /// Not 1.0: a provider reporting 4 999 of 5 000 has stopped being useful to
    /// the person watching, and demanding exactly the cap would make the figure
    /// depend on how a provider rounds its own arithmetic.
    public static let capThreshold = 0.99

    /// The samples reduced to `count` even buckets spanning `from`...`to`, each
    /// holding the highest reading that landed in it.
    ///
    /// A bucket nothing landed in is `nil`, not 0 — the same rule the meter
    /// follows. "No reading" and "at zero" are different facts, and a chart that
    /// draws the second when it means the first invents a night of idleness the
    /// user never had.
    ///
    /// The peak rather than the mean, because averaging a bucket hides the spike,
    /// and the spike is the only thing in it anyone would have acted on.
    ///
    /// Buckets are half-open — a sample landing exactly on a boundary opens the
    /// later one — except the last, which is closed at both ends. Samples
    /// outside the range are ignored rather than pinned to an end bucket.
    ///
    /// Empty when the range is empty or backwards, or `count` is not positive:
    /// there is nothing to divide, and a row of nils would let the caller's
    /// mistake through silently.
    public static func buckets(
        _ samples: [HistorySample],
        from: Date,
        to: Date,
        count: Int
    ) -> [Double?] {
        guard count > 0 else { return [] }
        let span = to.timeIntervalSince(from)
        guard span > 0 else { return [] }

        let step = span / Double(count)
        var peaks = [Double?](repeating: nil, count: count)

        for sample in samples {
            let offset = sample.at.timeIntervalSince(from)
            guard offset >= 0, offset <= span else { continue }
            // The last bucket is closed at both ends. `to` is normally now, the
            // sample taken at it is the newest reading there is, and dropping
            // the newest reading off the end of the chart is the one failure a
            // user would spot immediately.
            let index = min(count - 1, Int(offset / step))
            // `?? 0` cannot fabricate a value: percentages are clamped to 0...1,
            // so an empty bucket receiving a reading of zero still becomes zero
            // rather than staying nil.
            peaks[index] = max(peaks[index] ?? 0, sample.percent)
        }
        return peaks
    }

    /// Where history reads a fall as a window rolling over rather than as usage
    /// going down.
    ///
    /// 0.30 where `UsageForecast.resetDrop` is 0.20, because the two look at
    /// different spans. The fit sees half an hour, where a twenty-point fall is
    /// already implausible; history sees days at whatever spacing the app was
    /// running at, where a rolling window can genuinely shed more than that
    /// between two readings, and cutting there would shatter one window into
    /// several.
    ///
    /// A named constant rather than a default argument on `segments`, because it
    /// is not a fact about cutting a chart line: it is where the whole of history
    /// decides a window began. Anything else that cuts the same readings — a
    /// trace under a row, an export — has to cut here too, and a second literal
    /// 0.30 somewhere else is the app holding two opinions about the same event.
    public static let resetDrop = 0.30

    /// The samples in time order, cut wherever the window rolled over.
    ///
    /// A chart that joins the last reading of one window to the first of the
    /// next draws a vertical plunge through the middle of the day that never
    /// happened. Each returned segment is one window's life and is drawn as its
    /// own line; every segment is non-empty and they are in order.
    ///
    /// The cut is at `HistoryQuery.resetDrop`; the argument is here so a test can
    /// walk the boundary, not so a caller can hold its own view of it.
    public static func segments(
        _ samples: [HistorySample],
        resetDrop: Double = HistoryQuery.resetDrop
    ) -> [[HistorySample]] {
        let ordered = samples.sorted { $0.at < $1.at }
        guard let first = ordered.first else { return [] }
        // A drop of zero or less asks for a cut at every reading that did not
        // rise, which is nobody's intent; it is read as "do not cut".
        guard resetDrop > 0 else { return [ordered] }

        var result: [[HistorySample]] = []
        var current: [HistorySample] = [first]

        for sample in ordered.dropFirst() {
            if let previous = current.last, previous.percent - sample.percent >= resetDrop {
                result.append(current)
                current = []
            }
            current.append(sample)
        }
        result.append(current)
        return result
    }

    /// One entry per day that has readings, oldest first.
    ///
    /// Days with nothing in them are absent rather than zero-filled, for the
    /// reason an empty bucket is nil: the caller is the only one that knows
    /// whether a gap means the mac was off or the subscription was idle, and it
    /// cannot know that at all if this fills the gap in first.
    public static func rollUp(_ samples: [HistorySample], calendar: Calendar) -> [HistoryDay] {
        let ordered = samples.sorted { $0.at < $1.at }
        guard !ordered.isEmpty else { return [] }

        // Walked in order rather than grouped and then summarised, because a cap
        // hit is a crossing, and a crossing is only visible next to the reading
        // before it — which may belong to the previous day.
        var accumulators: [Date: Accumulator] = [:]
        // Starts false, so a series that opens at the cap counts one hit. The
        // crossing itself happened before aibars was watching, but a day spent
        // pinned at the cap reporting no hits at all is the worse answer.
        var wasAtCap = false

        for sample in ordered {
            let day = calendar.startOfDay(for: sample.at)
            let atCap = sample.percent >= capThreshold
            var accumulator = accumulators[day] ?? Accumulator()
            accumulator.add(sample.percent, crossedCap: atCap && !wasAtCap)
            accumulators[day] = accumulator
            wasAtCap = atCap
        }

        return accumulators
            .map { $0.value.day(startingAt: $0.key) }
            .sorted { $0.day < $1.day }
    }

    /// `dayCount` days laid out as weeks, oldest first, ending on the day `end`
    /// falls in.
    ///
    /// One cell a day and not one more: the leading and trailing stubs of the
    /// first and last weeks are absent rather than handed over empty, because an
    /// empty cell means "no readings that day" and a day before the window began
    /// is not a day with no readings — it is not in the picture at all. A grid
    /// that wants a rectangle leaves the stubs as holes, which it can see from
    /// `column` and `row`, and that is a drawing decision that stays in the
    /// drawing.
    ///
    /// A day the caller has no `HistoryDay` for is a cell with a nil peak.
    /// Zero-filling here would be this function deciding that a mac that was
    /// switched off had a quiet day, which is the caller's judgement and, as it
    /// happens, wrong. Two rows for one day — a store edited by hand, a roll-up
    /// computed in a second time zone — collapse to one cell, since a grid has
    /// one square per day whatever the input says.
    ///
    /// The calendar is passed in for the reason `rollUp` takes one: a day
    /// boundary and a first weekday are display decisions, and a test has to be
    /// able to pin both.
    public static func heatmap(
        _ days: [HistoryDay],
        endingOn end: Date,
        dayCount: Int = 90,
        calendar: Calendar
    ) -> [HistoryHeatmapCell] {
        guard dayCount > 0 else { return [] }
        let last = calendar.startOfDay(for: end)
        guard let first = calendar.date(byAdding: .day, value: -(dayCount - 1), to: last) else {
            return []
        }
        // The Monday — or Sunday, or Saturday — the grid's first column opens on.
        // Derived from the calendar's own `firstWeekday`, so a grid in a locale
        // whose week starts on Saturday is not one that starts on Monday with the
        // rows shuffled.
        let offsetOfFirst = (calendar.component(.weekday, from: first) - calendar.firstWeekday + 7) % 7
        guard let gridStart = calendar.date(byAdding: .day, value: -offsetOfFirst, to: first) else {
            return []
        }

        var summaries: [Date: HistoryDay] = [:]
        for day in days { summaries[calendar.startOfDay(for: day.day)] = day }

        var cells: [HistoryHeatmapCell] = []
        cells.reserveCapacity(dayCount)
        for offset in 0..<dayCount {
            // Added a day at a time through the calendar rather than by
            // multiplying 86 400: a spring-forward day is twenty-three hours
            // long, so ninety days of arithmetic on a fixed second count walks an
            // hour off the boundary and eventually a whole cell off the grid.
            //
            // A calendar that cannot add a day to a date it produced itself is
            // not a calendar, but the cell is dropped rather than guessed if it
            // happens: a guessed date is a square under the wrong weekday, and a
            // grid with 89 squares is at least visibly a grid with 89 squares.
            guard let stepped = calendar.date(byAdding: .day, value: offset, to: first) else { continue }
            // And floored again, because a zone whose clocks move at midnight has
            // days where 00:00 itself does not exist.
            let day = calendar.startOfDay(for: stepped)
            let span = calendar.dateComponents([.day], from: gridStart, to: day).day ?? 0
            let summary = summaries[day]
            cells.append(HistoryHeatmapCell(
                day: day,
                // A stored row always rests on at least one reading, so a row
                // that exists is never a nil peak.
                peak: summary?.peak,
                capHits: summary?.capHits ?? 0,
                samples: summary?.samples ?? 0,
                column: span / 7,
                row: (calendar.component(.weekday, from: day) - calendar.firstWeekday + 7) % 7
            ))
        }
        return cells
    }

    /// Running totals for one day. A struct rather than four parallel
    /// dictionaries so that adding a figure to the roll-up later touches one
    /// place.
    private struct Accumulator {
        private var total = 0.0
        private var peak = 0.0
        private var capHits = 0
        private var count = 0

        mutating func add(_ percent: Double, crossedCap: Bool) {
            total += percent
            peak = max(peak, percent)
            if crossedCap { capHits += 1 }
            count += 1
        }

        /// Only ever called for a day that took at least one sample, so the
        /// divisor is never zero.
        func day(startingAt start: Date) -> HistoryDay {
            HistoryDay(
                day: start,
                peak: peak,
                mean: count > 0 ? total / Double(count) : 0,
                capHits: capHits,
                samples: count
            )
        }
    }
}
