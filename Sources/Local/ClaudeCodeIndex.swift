import Foundation

/// One slice of Claude Code usage: a window, a day, or a single model.
public struct ClaudeCodeBucket: Equatable, Sendable {
    public let turns: Int
    public let inputTokens: Int
    public let outputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    /// What these turns would have cost at the API's published list prices, or
    /// nil when any turn in the bucket ran on a model `ModelPricing` has no
    /// rates for. A sum over only the priced turns would read as a smaller bill
    /// rather than an incomplete one, and the first thing a new model does is
    /// arrive without a price.
    public let estimatedUSD: Double?

    public init(
        turns: Int,
        inputTokens: Int,
        outputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        estimatedUSD: Double?
    ) {
        self.turns = turns
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.estimatedUSD = estimatedUSD
    }

    /// Nothing recorded. Distinct from "nothing known": the index throws when
    /// it cannot read the log directory at all, so an empty bucket means the
    /// logs were read and held no turns for that window.
    public static let empty = ClaudeCodeBucket(
        turns: 0,
        inputTokens: 0,
        outputTokens: 0,
        cacheCreationTokens: 0,
        cacheReadTokens: 0,
        estimatedUSD: 0
    )
}

/// Everything the panel needs to say about local Claude Code usage.
public struct ClaudeCodeTotals: Equatable, Sendable {
    /// The current five-hour block, empty when the last one has run out. This
    /// is the local approximation of Claude's own window — the logs carry no
    /// reset time, so it is derived from the turns themselves.
    public let sessionWindow: ClaudeCodeBucket
    /// The current calendar day, in the user's own time zone.
    public let today: ClaudeCodeBucket
    /// The last seven calendar days including today, and the last thirty.
    /// Rolling rather than calendar-aligned: a figure that drops to nothing on
    /// the first of the month says nothing about the rate someone is working at.
    public let week: ClaudeCodeBucket
    public let month: ClaudeCodeBucket
    /// Model id to its share of `month`.
    public let byModel: [String: ClaudeCodeBucket]
    /// When the most recent turn was written, however long ago that is. Kept
    /// outside the windows so "nothing today" can be told apart from "nothing
    /// since March".
    public let lastTurnAt: Date?

    public init(
        sessionWindow: ClaudeCodeBucket,
        today: ClaudeCodeBucket,
        week: ClaudeCodeBucket,
        month: ClaudeCodeBucket,
        byModel: [String: ClaudeCodeBucket],
        lastTurnAt: Date?
    ) {
        self.sessionWindow = sessionWindow
        self.today = today
        self.week = week
        self.month = month
        self.byModel = byModel
        self.lastTurnAt = lastTurnAt
    }

    public static let empty = ClaudeCodeTotals(
        sessionWindow: .empty,
        today: .empty,
        week: .empty,
        month: .empty,
        byModel: [:],
        lastTurnAt: nil
    )
}

/// An incremental index over the transcripts `ClaudeCodeScanner` reads.
///
/// The scanner turns one file into turns. This turns a directory of them into
/// four windows, once a minute, for ever — which is a different problem. The
/// corpus on a working machine is thousands of files and gigabytes of text: on
/// the one this was built against, 3,171 files and 1.1 GB. Reading that on
/// every refresh is not something a menu bar app can do.
///
/// So the index keeps a watermark per file — size, modification date, byte
/// offset — and each refresh hands the scanner only the offset it stopped at.
/// A file that is unchanged and already read through is not opened at all, and
/// a file last written before the lookback window is never opened again. On
/// that corpus the first sweep takes about eight seconds and every refresh
/// after it about seventy milliseconds.
///
/// What survives between refreshes is not the log but its sum: token counts
/// aggregated per local day and model, plus the individual turns of the last
/// few hours, which is all the five-hour window needs. It is written as a
/// single defaults value — on that same corpus, where every transcript had
/// been touched inside the window, just under a megabyte of it, nearly all
/// watermarks — and only when a sweep actually found something. That is what
/// makes a relaunch cost one decode rather than one re-read of a gigabyte.
///
/// Marked `@unchecked Sendable` deliberately: every mutable field is reached
/// only under `lock`, which lets the provider hand this to a detached task
/// without the compiler having to take that on faith.
public final class ClaudeCodeIndex: @unchecked Sendable {
    // MARK: - Shape of the sweep

    /// How much of the log one refresh is allowed to read.
    ///
    /// Sized so a first sweep finishes in one go. A tighter budget spreads the
    /// same work over several refreshes, which costs no less and leaves the
    /// figures climbing towards the truth for minutes after launch. The cap is
    /// here so that a corpus larger than any seen so far cannot make one
    /// refresh run away, not to pace the ordinary case — and it is checked
    /// between files, so a single enormous transcript is still read whole.
    private static let bytesPerRefresh = 1 << 30
    /// How long individual turns are kept whole. An hour more than the window
    /// they serve, which is all that is needed now that `blockStart` carries
    /// the chain: no turn older than the block's start can belong to it.
    private static let turnRetention: TimeInterval = 6 * 60 * 60
    /// The length of Claude's usage window.
    private static let sessionWindow: TimeInterval = 5 * 60 * 60
    /// How long a transcript has to sit untouched before its last turn is taken
    /// as final. See `FileMark.pending` for what that is for.
    private static let settleDelay: TimeInterval = 5 * 60

    // MARK: - State

    private let root: URL
    private let store: UserDefaults
    private let lookback: TimeInterval
    private let calendar: Calendar
    private let lock = NSLock()

    /// Watermark per transcript, keyed by path relative to `root`.
    private var files: [String: FileMark] = [:]
    /// Committed turns, summed per local day and model.
    private var days: [DayKey: TokenCounts] = [:]
    /// Committed turns of the last `turnRetention`, kept whole for the window.
    private var recent: [IndexedTurn] = []
    /// The latest turn seen, ever. Not trimmed with the rest.
    private var lastTurnAt: Date?
    /// Where the current five-hour block began.
    ///
    /// Carried rather than recomputed because blocks chain: each one opens five
    /// hours after the last, so on a day of continuous work the boundary is a
    /// consequence of the morning's first turn. `recent` holds hours, not days,
    /// so the chain has to be remembered rather than derived.
    private var blockStart: Date?
    private var loaded = false
    private var dirty = false

    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    /// `store` is injectable so tests get a scratch domain rather than the
    /// user's settings, and `root` so they get a fixture tree rather than
    /// whatever this machine happens to have in `~/.claude`. The root the app
    /// passes is `ClaudeCodeScanner.defaultRoot()`, which knows about
    /// `CLAUDE_CONFIG_DIR`; there is no second answer to that question here.
    public init(
        root: URL,
        store: UserDefaults,
        lookback: TimeInterval = 30 * 24 * 60 * 60
    ) {
        self.root = root.standardizedFileURL
        self.store = store
        // Taken as given rather than floored at thirty days: `month` is clamped
        // to whatever was actually read, so a short lookback yields a short
        // month rather than a thirty-day figure covering a week of log.
        self.lookback = max(lookback, 0)
        self.calendar = Calendar.current
    }

    // MARK: - Refresh

    /// Reads whatever was appended since the last call and answers the totals.
    ///
    /// Throws only when the log directory itself cannot be read — a transcript
    /// that disappears mid-sweep, or that the scanner cannot open, is skipped.
    /// The distinction matters: "Claude Code is not installed here" is
    /// something to tell the user, one unreadable file is not.
    public func refresh(now: Date) throws -> ClaudeCodeTotals {
        lock.lock()
        defer { lock.unlock() }

        if !loaded {
            load()
            loaded = true
        }

        try sweep(now: now)
        trim(now: now)
        // Totals before persistence: answering is what advances the block.
        let answer = totals(now: now)
        persistIfNeeded()
        return answer
    }

    // MARK: - Sweeping the log directory

    private func sweep(now: Date) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            throw ProviderError.configuration("No Claude Code logs at \(root.path).")
        }

        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            throw ProviderError.configuration("Could not read \(root.path).")
        }

        let cutoff = now.addingTimeInterval(-lookback)
        let keepWhole = now.addingTimeInterval(-Self.turnRetention)
        var budget = Self.bytesPerRefresh
        var present: Set<String> = []

        for case let url as URL in walker {
            guard url.pathExtension == "jsonl",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  let modified = values.contentModificationDate
            else { continue }

            guard let path = relativePath(of: url) else { continue }

            // A transcript last written before the window can hold nothing the
            // window covers, so it is never opened again — and its watermark
            // goes too, because keeping thousands of them is most of what the
            // stored index would weigh.
            guard modified >= cutoff else {
                if files.removeValue(forKey: path) != nil { dirty = true }
                continue
            }
            present.insert(path)

            let mark = files[path]
            // Nothing appended and nothing left over: the file is not opened.
            // This is the case for all but a handful of files on any refresh.
            //
            // The third clause is not redundant. A sweep that runs out of its
            // byte budget still records the size of the file it stopped short
            // of, because that is what it observed; without the check on the
            // offset the next sweep would read the size, see no change, and
            // skip the part it never read.
            if let mark,
               mark.size == size,
               mark.modified == modified,
               mark.offset >= UInt64(max(0, size)) {
                continue
            }
            guard budget > 0 else { continue }

            let from = mark?.offset ?? 0
            guard let scan = try? ClaudeCodeScanner.scan(file: url, from: from) else { continue }
            budget -= Int(scan.offset > from ? scan.offset - from : 0)

            var pending = mark?.pending
            for turn in scan.turns {
                // A turn dated before the window is already summed or already
                // gone, and one dated after the clock is a clock problem
                // rather than usage.
                guard turn.at >= cutoff, turn.at <= now else { continue }
                let indexed = IndexedTurn(turn)
                if let held = pending, held.messageID == indexed.messageID {
                    // The same message, written again: replace rather than add.
                    pending = indexed
                } else {
                    if let held = pending { commit(held, keepWhole: keepWhole) }
                    pending = indexed
                }
            }

            // Nothing has written to this file in minutes, so its last turn is
            // finished and there is nothing left to supersede it.
            if now.timeIntervalSince(modified) > Self.settleDelay, let held = pending {
                commit(held, keepWhole: keepWhole)
                pending = nil
            }

            note(pending?.at)
            files[path] = FileMark(
                size: size,
                modified: modified,
                offset: scan.offset,
                pending: pending
            )
            dirty = true
        }

        // Watermarks for transcripts that are no longer there. Their turns stay
        // in the daily sums — the work happened whether or not the file
        // survived — and they age out with everything else.
        let vanished = files.keys.filter { !present.contains($0) }
        if !vanished.isEmpty {
            for path in vanished { files.removeValue(forKey: path) }
            dirty = true
        }
    }

    private func relativePath(of url: URL) -> String? {
        let full = url.standardizedFileURL.path
        let base = root.path
        guard full.hasPrefix(base) else { return nil }
        let tail = full.dropFirst(base.count)
        let trimmed = tail.hasPrefix("/") ? tail.dropFirst() : tail
        return trimmed.isEmpty ? nil : String(trimmed)
    }

    private func commit(_ turn: IndexedTurn, keepWhole: Date) {
        let key = DayKey(day: calendar.startOfDay(for: turn.at), model: turn.model)
        days[key, default: .zero].add(turn)
        // Only turns the window could still reach are kept whole. Without this
        // the first sweep would hold a month of them in memory until the trim
        // at the end of the same refresh threw all but a few hours away.
        if turn.at >= keepWhole { recent.append(turn) }
        note(turn.at)
        dirty = true
    }

    private func note(_ date: Date?) {
        guard let date else { return }
        if let known = lastTurnAt, known >= date { return }
        lastTurnAt = date
        dirty = true
    }

    // MARK: - Trimming

    private func trim(now: Date) {
        let dayCutoff = calendar.startOfDay(for: now.addingTimeInterval(-lookback))
        let stale = days.keys.filter { $0.day < dayCutoff }
        if !stale.isEmpty {
            for key in stale { days.removeValue(forKey: key) }
            dirty = true
        }

        let turnCutoff = now.addingTimeInterval(-Self.turnRetention)
        let kept = recent.filter { $0.at >= turnCutoff }
        if kept.count != recent.count {
            recent = kept
            dirty = true
        }
    }

    // MARK: - Answering

    private func totals(now: Date) -> ClaudeCodeTotals {
        let startOfToday = calendar.startOfDay(for: now)
        let startOfWeek = calendar.date(byAdding: .day, value: -6, to: startOfToday) ?? startOfToday
        // Clamped to the lookback, because a window wider than what was read is
        // a window reporting zeroes for days it never opened.
        let read = calendar.startOfDay(for: now.addingTimeInterval(-lookback))
        let startOfMonth = max(
            calendar.date(byAdding: .day, value: -29, to: startOfToday) ?? startOfToday,
            read
        )

        // Held-back turns are in no daily sum yet, so every window adds them.
        let pending = files.values.compactMap(\.pending)

        var monthly: [String: TokenCounts] = [:]
        var weekly: [String: TokenCounts] = [:]
        var daily: [String: TokenCounts] = [:]

        for (key, counts) in days {
            if key.day >= startOfMonth { monthly[key.model, default: .zero].add(counts) }
            if key.day >= startOfWeek { weekly[key.model, default: .zero].add(counts) }
            if key.day >= startOfToday { daily[key.model, default: .zero].add(counts) }
        }
        for turn in pending {
            let day = calendar.startOfDay(for: turn.at)
            if day >= startOfMonth { monthly[turn.model, default: .zero].add(turn) }
            if day >= startOfWeek { weekly[turn.model, default: .zero].add(turn) }
            if day >= startOfToday { daily[turn.model, default: .zero].add(turn) }
        }

        var session: [String: TokenCounts] = [:]
        let candidates = (recent + pending).sorted { $0.at < $1.at }
        let start = Self.sessionBlockStart(
            of: candidates,
            seed: blockStart,
            now: now,
            calendar: calendar
        )
        if start != blockStart {
            blockStart = start
            dirty = true
        }
        if let start {
            for turn in candidates where turn.at >= start {
                session[turn.model, default: .zero].add(turn)
            }
        }

        var byModel: [String: ClaudeCodeBucket] = [:]
        for (model, counts) in monthly {
            byModel[model] = Self.bucket([model: counts])
        }

        return ClaudeCodeTotals(
            sessionWindow: Self.bucket(session),
            today: Self.bucket(daily),
            week: Self.bucket(weekly),
            month: Self.bucket(monthly),
            byModel: byModel,
            lastTurnAt: lastTurnAt
        )
    }

    /// When the block covering `now` began, or nil when the last one has run
    /// out and no new one has started.
    ///
    /// The logs carry no reset time, so the block is inferred the way Claude's
    /// own window behaves: it opens on the hour containing the first turn after
    /// a gap of a full window, it closes five hours later, and the next turn
    /// after that opens the next one. Where the account's real reset time is
    /// known — the Claude provider reads it from the API — that is the figure
    /// to state; this is what local logs can honestly say on their own.
    ///
    /// `seed` is the block the previous call landed on. It is what keeps the
    /// chain intact across a day of unbroken work, where the current boundary
    /// descends from a turn that fell out of `turns` hours ago.
    static func sessionBlockStart(
        of turns: [IndexedTurn],
        seed: Date?,
        now: Date,
        calendar: Calendar
    ) -> Date? {
        var start = seed
        var previous: Date?
        for turn in turns {
            let openNew: Bool
            if let start {
                openNew = turn.at.timeIntervalSince(start) >= sessionWindow
                    || (previous.map { turn.at.timeIntervalSince($0) >= sessionWindow } ?? false)
            } else {
                openNew = true
            }
            if openNew {
                start = calendar.dateInterval(of: .hour, for: turn.at)?.start ?? turn.at
            }
            previous = turn.at
        }
        guard let start, now.timeIntervalSince(start) < sessionWindow else { return nil }
        return start
    }

    /// Sums the counts and prices each model's share at its own rates.
    ///
    /// The cost is nil the moment one model in the bucket has no published
    /// price, rather than a total over the rest: see `ClaudeCodeBucket`.
    private static func bucket(_ counts: [String: TokenCounts]) -> ClaudeCodeBucket {
        var total = TokenCounts.zero
        var usd: Double? = 0
        for (model, part) in counts {
            total.add(part)
            guard let running = usd,
                  let cost = ModelPricing.cost(
                      input: part.input,
                      output: part.output,
                      // The log reports one cache-write figure and the table
                      // publishes one cache-write rate; the five-minute rate is
                      // that rate. A one-hour write bills higher and is not
                      // told apart here, so a bucket holding them reads low.
                      cacheWrite5m: part.cacheCreation,
                      cacheRead: part.cacheRead,
                      model: model
                  )
            else {
                usd = nil
                continue
            }
            usd = running + cost
        }
        return ClaudeCodeBucket(
            turns: total.turns,
            inputTokens: total.input,
            outputTokens: total.output,
            cacheCreationTokens: total.cacheCreation,
            cacheReadTokens: total.cacheRead,
            estimatedUSD: usd
        )
    }

    // MARK: - Persistence

    private func load() {
        guard let data = store.data(forKey: Key.state),
              let stored = try? decoder.decode(StoredState.self, from: data)
        else {
            // An older shape or a half-written value is not recoverable, and
            // leaving it means failing to read it at every launch from now on.
            store.removeObject(forKey: Key.state)
            return
        }
        files = Dictionary(
            stored.files.map { ($0.path, $0.mark) },
            uniquingKeysWith: { first, _ in first }
        )
        days = Dictionary(
            stored.days.map { (DayKey(day: $0.day, model: $0.model), $0.counts) },
            uniquingKeysWith: { first, _ in first }
        )
        recent = stored.recent
        lastTurnAt = stored.lastTurnAt
        blockStart = stored.blockStart
    }

    private func persistIfNeeded() {
        guard dirty else { return }
        dirty = false
        let stored = StoredState(
            files: files.map { StoredFile(path: $0.key, mark: $0.value) },
            days: days.map { StoredDay(day: $0.key.day, model: $0.key.model, counts: $0.value) },
            recent: recent,
            lastTurnAt: lastTurnAt,
            blockStart: blockStart
        )
        // A failed encode costs this launch's watermarks and nothing else; the
        // next refresh rebuilds them by reading the log again.
        guard let data = try? encoder.encode(stored) else { return }
        store.set(data, forKey: Key.state)
    }

    private enum Key {
        static let state = "aibars.claudeCode.index"
    }
}

// MARK: - What the index keeps

/// A scanned turn, reduced to what the windows need and made storable.
///
/// `ClaudeCodeTurn` carries more than this — the session it belongs to,
/// whether it was a subagent — and none of it survives aggregation, so none of
/// it is written to disk. The message id does survive, because it is what tells
/// a message written twice from two messages.
struct IndexedTurn: Codable, Equatable {
    let at: Date
    let model: String
    let messageID: String
    let input: Int
    let output: Int
    let cacheCreation: Int
    let cacheRead: Int

    init(_ turn: ClaudeCodeTurn) {
        self.at = turn.at
        self.model = turn.model
        self.messageID = turn.messageID
        self.input = turn.inputTokens
        self.output = turn.outputTokens
        self.cacheCreation = turn.cacheCreationTokens
        self.cacheRead = turn.cacheReadTokens
    }

    /// Short keys because there is one of these per turn of the last several
    /// hours and they all go into a single defaults value.
    private enum CodingKeys: String, CodingKey {
        case at = "t"
        case model = "m"
        case messageID = "k"
        case input = "i"
        case output = "o"
        case cacheCreation = "w"
        case cacheRead = "r"
    }
}

private struct FileMark: Codable, Equatable {
    let size: Int
    let modified: Date
    let offset: UInt64
    /// The last turn read from this file, held back rather than summed.
    ///
    /// Claude Code writes an assistant message once per content block as it
    /// streams, each line repeating the message id and carrying a larger output
    /// count than the last — on the corpus this was built against, half of all
    /// assistant rows are such a repeat, and the first line of a pair can report
    /// six output tokens where the last reports seventeen thousand. So the last
    /// line for a message supersedes the ones before it, and a refresh that
    /// lands between the two has to be able to take the later figure. Holding
    /// the last turn back until either the next line arrives or the file has
    /// gone quiet is what makes that possible; without it a turn caught
    /// mid-stream would be recorded at a handful of tokens for ever.
    let pending: IndexedTurn?

    private enum CodingKeys: String, CodingKey {
        case size = "s"
        case modified = "m"
        case offset = "o"
        case pending = "p"
    }
}

private struct DayKey: Hashable {
    let day: Date
    let model: String
}

private struct TokenCounts: Codable, Equatable {
    var turns = 0
    var input = 0
    var output = 0
    var cacheCreation = 0
    var cacheRead = 0

    static let zero = TokenCounts()

    mutating func add(_ turn: IndexedTurn) {
        turns += 1
        input += turn.input
        output += turn.output
        cacheCreation += turn.cacheCreation
        cacheRead += turn.cacheRead
    }

    mutating func add(_ other: TokenCounts) {
        turns += other.turns
        input += other.input
        output += other.output
        cacheCreation += other.cacheCreation
        cacheRead += other.cacheRead
    }

    private enum CodingKeys: String, CodingKey {
        case turns = "n"
        case input = "i"
        case output = "o"
        case cacheCreation = "w"
        case cacheRead = "r"
    }
}

/// The stored shapes all use one-letter keys. There is one `StoredFile` per
/// transcript inside the lookback window — thousands, on a machine that has
/// been used hard — and the whole state is one defaults value, so the key names
/// are a meaningful share of what gets written.
private struct StoredFile: Codable {
    let path: String
    let mark: FileMark

    private enum CodingKeys: String, CodingKey {
        case path = "p"
        case mark = "m"
    }
}

private struct StoredDay: Codable {
    let day: Date
    let model: String
    let counts: TokenCounts

    private enum CodingKeys: String, CodingKey {
        case day = "d"
        case model = "m"
        case counts = "c"
    }
}

private struct StoredState: Codable {
    let files: [StoredFile]
    let days: [StoredDay]
    let recent: [IndexedTurn]
    let lastTurnAt: Date?
    let blockStart: Date?

    private enum CodingKeys: String, CodingKey {
        case files = "f"
        case days = "d"
        case recent = "r"
        case lastTurnAt = "l"
        case blockStart = "b"
    }
}
