import Combine
import Foundation
import SQLite3

/// How much of the past survives, and how close together readings may be.
///
/// A free-standing enum rather than statics on the store: the store is
/// main-actor isolated and these are read on the database's own queue, and a
/// settings pane that wants to say "14 days" should not have to ask an actor.
public enum HistoryRetention {
    /// Every reading, at the resolution it was taken. Two weeks is what a "this
    /// week against last week" comparison needs, and it is what the file can
    /// carry: measured, a minute-by-minute fortnight is about 20,000 rows and
    /// 1 MB per series, so a full panel of eleven services settles around
    /// 20 MB and stays there.
    public static let sample: TimeInterval = 14 * 24 * 60 * 60

    /// One row per series per day. Kept far longer than the samples that built
    /// it — 400 days rather than 365 so a year-over-year comparison has both
    /// ends of the year and a few days of slack.
    public static let day: TimeInterval = 400 * 24 * 60 * 60

    /// The closest two samples of one series may be.
    ///
    /// Someone holding ⌘R produces ten polls in as many seconds, all carrying
    /// the figure the provider cached. `UsageTrendStore` refuses them because
    /// they flatten its fit; this refuses them because fourteen days of them is
    /// a file nobody asked for.
    public static let minimumInterval: TimeInterval = 30

    /// Deleted rows free space inside the file but never give it back to the
    /// filesystem, so a store that only ever prunes only ever grows. Below this
    /// many rows the hole is not worth rewriting the database to close.
    public static let vacuumThreshold = 5_000
}

/// The key a window is filed under when the provider offers no identifier of
/// its own — which, today, is every provider.
///
/// An extension rather than a member, because `HistorySeriesID` belongs to the
/// query side of history and knows nothing about where rows are put; this is
/// the store's answer to "what do I call this window", and the store is the
/// only thing that has to be consistent about it forever.
public extension HistorySeriesID {
    /// Case, accents, spacing and punctuation are all dropped, so "Weekly · all
    /// models" and "Weekly (all models)" are one series rather than two. That is
    /// as far as a derived key can go: a genuine rewording still forks, and the
    /// only real fix is a provider that names its own windows.
    ///
    /// It is still much better than the position in the payload — Claude sorts
    /// its windows by how busy they are, so the "primary" metric is the 5-hour
    /// window on Monday and the weekly cap on Friday, and a key derived from
    /// position would file them as one series.
    ///
    /// The same function is what a caller matching a live metric back to a
    /// stored series should compare with, rather than comparing labels: the key
    /// is what the row is under.
    static func windowKey(for label: String) -> String {
        let folded = label.folding(
            options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive],
            locale: nil
        )
        var key = String.UnicodeScalarView()
        var separatorPending = false
        for scalar in folded.unicodeScalars {
            guard CharacterSet.alphanumerics.contains(scalar) else {
                separatorPending = true
                continue
            }
            if separatorPending, !key.isEmpty { key.append("-") }
            separatorPending = false
            key.append(scalar)
        }
        // A label that is nothing but punctuation would otherwise key every such
        // window in a provider to the empty string and merge them.
        return key.isEmpty ? "window" : String(key)
    }
}

public enum HistoryError: LocalizedError {
    case unavailable(String)
    /// The file was written by a later version of the app. Opening it anyway
    /// would mean writing rows a schema we do not know about has to make sense
    /// of, so this refuses instead.
    case unsupportedSchema(Int)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return "Could not open the usage history: \(message)"
        case .unsupportedSchema(let version):
            return "The usage history was written by a newer version of aibars (schema \(version))."
        }
    }
}

/// Every reading aibars has taken, on disk, with real retention.
///
/// SQLite rather than UserDefaults. The forecast's ring is six hours per
/// provider and fits in a plist; ninety days does not, and a plist is rewritten
/// whole on every write, so a minute-by-minute history would rewrite megabytes
/// every minute to append forty bytes.
///
/// Four things this is careful about, all of them cheap now and impossible to
/// retrofit later:
///
/// 1. **The series key is not the label.** A window is keyed by whatever stable
///    identifier the provider gives, falling back to a normalised label only
///    when it gives none — which, until `UsageMetric` carries a key of its own,
///    is every provider. The normalisation is in one place and the fallback is
///    one line, so the day a provider does name its windows there is somewhere
///    for the name to go.
/// 2. **The schema is versioned.** `PRAGMA user_version`, migrated on open, so
///    the shape can change without the history being thrown away.
/// 3. **`UNIQUE(series, ts)`.** Recording the same reading twice — two sweeps
///    racing, a retry after a timeout — leaves one row, not two, and does not
///    double-count the day it belongs to.
/// 4. **A reset marks a boundary, it does not clear the ring.** A window
///    rolling over is written down as a boundary on the reading that opened the
///    new window, and everything behind it stays exactly where it was. Clearing
///    at a reset would throw away precisely what a history view exists to show.
///
/// One connection, on one serial queue, in WAL so a read is never blocked
/// behind the writer. Writes are dispatched; the isolated reads are `sync`,
/// which also means a read issued after a write sees it, because the queue is
/// FIFO. The `nonisolated` members below use that same queue and are ordered
/// against the writer in the same way; what they add is that the caller need not
/// be the main actor, and that the three `async` ones suspend where the isolated
/// ones block.
@MainActor
public final class UsageHistoryStore: ObservableObject {
    /// The app's single instance. Optional because opening the file can fail —
    /// a full disk, a container the app cannot write — and a menu bar that
    /// reports usage must still open when its history cannot.
    public static let shared: UsageHistoryStore? = try? UsageHistoryStore()

    // MARK: - Published state

    /// Whether readings are written down at all.
    ///
    /// Turning this off stops recording and leaves what is already stored;
    /// deleting is `forget(_:)`, which is a different thing to want and should
    /// not happen as a side effect of a switch.
    @Published public var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Key.isEnabled) }
    }

    /// Bumped on the main actor after any write that changed something, so a
    /// chart can rebuild without polling. A counter rather than a date: two
    /// readings can land in the same second, and an observer only needs to know
    /// that something moved.
    @Published public private(set) var revision: Int = 0

    // MARK: - State

    private let database: HistoryDatabase
    private let queue = DispatchQueue(label: "dev.aibars.history", qos: .utility)
    private let defaults: UserDefaults
    private let calendar: Calendar
    private let now: () -> Date

    /// `directory`, `now` and `defaults` are injectable so tests get a scratch
    /// file, a clock they can move and a scratch domain, rather than the user's
    /// real history and a wall clock that makes fourteen days take fourteen
    /// days to arrange.
    public init(
        directory: URL? = nil,
        now: @escaping () -> Date = Date.init,
        defaults: UserDefaults = .standard
    ) throws {
        let folder = try directory ?? Self.defaultDirectory()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        self.database = try HistoryDatabase(url: folder.appendingPathComponent(Self.databaseFileName))
        self.defaults = defaults
        self.calendar = Calendar.current
        self.now = now
        // `object(forKey:)` rather than `bool(forKey:)`: the latter answers
        // false for a key nobody has written, which would ship with recording
        // switched off and no history to show a week later.
        self.isEnabled = defaults.object(forKey: Key.isEnabled) as? Bool ?? true
    }

    /// `~/Library/Application Support/aibars`. Created by the initialiser; the
    /// database and its WAL sidecars are the only things in it.
    ///
    /// Not private: `createdPaths(in:)` is built from it, and the test behind
    /// that one asserts this answer against the path `install.sh` prints.
    static func defaultDirectory() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("aibars", isDirectory: true)
    }

    /// The database, the two sidecars WAL leaves beside it, and the folder that
    /// holds all three — deepest first, which is the order they would be removed
    /// in.
    ///
    /// Published rather than left implicit because it is one half of a pair, and
    /// the other half is not Swift: `install.sh` prints uninstall instructions,
    /// and a `rm -rf` in a shell script is a copy of this list that no compiler
    /// checks. The database is not covered by `defaults delete` or by
    /// `security delete-generic-password`, so if it ever moves out from under the
    /// path that script names, four hundred days of rollups are orphaned on the
    /// disk of somebody who believed they had uninstalled the app. The guard is
    /// `UsageHistoryStoreTests.testTheUninstallListCoversEveryPathThisStoreCreates`,
    /// which fails on the day this answer stops matching the script's.
    ///
    /// `directory` is here for that test: it asks a store that was opened over a
    /// scratch folder to list what it can leave there, then checks the folder
    /// afterwards and finds nothing else.
    static func createdPaths(in directory: URL? = nil) throws -> [URL] {
        let folder = try directory ?? defaultDirectory()
        return fileNames.map { folder.appendingPathComponent($0) } + [folder]
    }

    /// The one file the readings live in, named once so that the initialiser and
    /// the list above cannot come to disagree about where it is.
    static let databaseFileName = "history.sqlite"

    /// The database, and the two files WAL opens beside it. The sidecars are
    /// transient — a clean close folds them back in — but a machine that lost
    /// power keeps them, so an uninstall has to account for them. The suffixes
    /// are SQLite's, not ours: it derives both from the database's own path.
    static let fileNames = [databaseFileName, databaseFileName + "-wal", databaseFileName + "-shm"]

    // MARK: - Recording

    /// Writes down every metered window in one payload.
    ///
    /// The id is passed separately from `data.providerID` because rows are
    /// keyed per account and the payload only knows which service it came from.
    ///
    /// A window with no cap is not recorded at all. ChatGPT and Copilot report
    /// status rather than a quota, and `UsageMetric.percent` answers 0 for one:
    /// storing that would draw fourteen days of a flat line at zero, which is
    /// an assertion about usage rather than an absence of one.
    public func record(_ data: UsageData, for providerID: String) {
        guard isEnabled else { return }
        // The reading was true when it was fetched, not when it reached here,
        // and a payload stamped in the future would hold every later reading
        // out on the minimum interval.
        let at = min(data.fetchedAt, now())
        let readings = ([data.primary] + data.secondary).compactMap {
            reading(from: $0, provider: providerID, at: at)
        }
        guard !readings.isEmpty else { return }

        let database = self.database
        queue.async { [weak self] in
            guard database.insert(readings) else { return }
            Task { @MainActor in self?.revision &+= 1 }
        }
    }

    /// Flattens one metric into what the database stores, or nil when there is
    /// nothing honest to store.
    private func reading(from metric: UsageMetric, provider: String, at: Date) -> HistoryDatabase.Reading? {
        guard metric.limit > 0, metric.limit.isFinite, metric.used.isFinite else { return nil }
        // The day is decided here, on the main actor, so the calendar stays on
        // one thread and the database layer never has to know about time zones.
        return HistoryDatabase.Reading(
            provider: provider,
            // The one line that changes when a metric starts carrying a key of
            // its own: prefer the provider's, normalise the label only as a
            // fallback.
            windowKey: HistorySeriesID.windowKey(for: metric.label),
            label: metric.label,
            unit: metric.unit,
            ts: Self.seconds(at),
            day: Self.seconds(calendar.startOfDay(for: at)),
            used: metric.used,
            cap: metric.limit,
            percent: metric.percent,
            resetAt: metric.resetDate.map(Self.seconds) ?? 0
        )
    }

    /// Drops everything stored for one account. Called when a service is signed
    /// out, where keeping the history of a session the user has just revoked
    /// would be a surprise.
    public func forget(_ providerID: String) {
        let database = self.database
        queue.async { [weak self] in
            guard database.forget(provider: providerID) else { return }
            Task { @MainActor in self?.revision &+= 1 }
        }
    }

    // MARK: - Reading

    /// Every reading of one series since `date`, oldest first.
    public func samples(for series: HistorySeriesID, since date: Date) -> [HistorySample] {
        let floor = Self.seconds(date)
        return queue.sync {
            database.samples(provider: series.providerID, windowKey: series.windowKey, since: floor)
        }
    }

    /// One row per day of one series since `date`, oldest first.
    ///
    /// Rollups are maintained as readings land rather than rebuilt on a timer,
    /// so today's row is always as current as the last reading.
    public func days(for series: HistorySeriesID, since date: Date) -> [HistoryDay] {
        let floor = Self.seconds(calendar.startOfDay(for: date))
        return queue.sync {
            database.days(provider: series.providerID, windowKey: series.windowKey, since: floor)
        }
    }

    /// Every series with anything stored, provider first then window.
    public func series() -> [HistorySeriesID] {
        queue.sync { database.series() }
    }

    // MARK: - Reading without the main actor
    //
    // The three above are `queue.sync` on the main actor, which is affordable for
    // a settings pane somebody opened by hand and is not affordable for anything
    // the panel draws: eleven rows each asking for their own samples inside one
    // `body` pass is eleven synchronous SQLite queries on the thread doing the
    // drawing, some of them queued behind the insert transaction of the very
    // sweep that opened the panel.
    //
    // These three answer the same questions from the database's own queue and
    // hand the result back through a continuation, so the caller suspends instead
    // of blocking. They are `nonisolated`, so calling one does not hop to the
    // main actor first — that hop is the whole cost being avoided, and a method
    // that merely awaited an isolated one would reintroduce it in silence.
    //
    // What they may touch is decided by that: `database` and `queue` are
    // immutable and `Sendable`, so a nonisolated method may reach both. `calendar`
    // and `now` are the store's opinions about the machine's clock, and a caller
    // that wants a day boundary already had to make that decision to draw the
    // axis — so the dates come in as arguments rather than being computed here.

    /// The same samples as `samples(for:since:)`, already reduced to `count` even
    /// buckets, without ever occupying the main actor.
    ///
    /// Exactly what `HistoryQuery.buckets(samples(for:since:from), from:, to:,
    /// count:)` answers, refusals included: nothing to divide comes back as `[]`
    /// rather than as a row of nils.
    ///
    /// The bucketing runs on the database queue too. Handing back twenty thousand
    /// `HistorySample`s so that the main actor could reduce them to twenty-four
    /// doubles would move the allocation onto the thread this exists to keep free.
    public nonisolated func peaks(
        for series: HistorySeriesID,
        from: Date,
        to: Date,
        count: Int
    ) async -> [Double?] {
        guard count > 0, to > from else { return [] }
        let floor = Self.seconds(from)
        let database = self.database
        return await withCheckedContinuation { continuation in
            queue.async {
                let rows = database.samples(
                    provider: series.providerID, windowKey: series.windowKey, since: floor
                )
                continuation.resume(
                    returning: HistoryQuery.buckets(rows, from: from, to: to, count: count)
                )
            }
        }
    }

    /// One row per day of one series, off the main actor.
    ///
    /// The floor is a day rather than an instant, and the caller does the
    /// flooring: `days(for:since:)` uses this object's `calendar`, and a heatmap
    /// has already had to pick one to lay its columns out with.
    public nonisolated func days(
        for series: HistorySeriesID,
        sinceDayStarting day: Date
    ) async -> [HistoryDay] {
        let floor = Self.seconds(day)
        let database = self.database
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: database.days(
                    provider: series.providerID, windowKey: series.windowKey, since: floor
                ))
            }
        }
    }

    /// Every series with anything stored, off the main actor. The same answer
    /// `series()` gives, from a thread that is not drawing anything.
    public nonisolated func allSeries() async -> [HistorySeriesID] {
        let database = self.database
        return await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: database.series()) }
        }
    }

    // MARK: - Maintenance

    /// Prunes what has aged out, and reclaims the space if enough of it went.
    ///
    /// Not called from `record`: pruning fourteen days of rows is not work to
    /// do on the way through a one-minute refresh. The caller decides — at
    /// launch and once a day is enough.
    public func maintain() {
        let sampleFloor = Self.seconds(now().addingTimeInterval(-HistoryRetention.sample))
        let dayFloor = Self.seconds(now().addingTimeInterval(-HistoryRetention.day))
        let database = self.database
        queue.async { [weak self] in
            guard database.prune(samplesBefore: sampleFloor, daysBefore: dayFloor) else { return }
            Task { @MainActor in self?.revision &+= 1 }
        }
    }

    // MARK: - Export

    /// The history between `date` and `until` as CSV, at the finest grain that
    /// survives for each part of the range.
    ///
    /// Raw readings are kept for two weeks and day rollups for over a year, so
    /// an export of the last ninety days is mostly day rows with the recent end
    /// at full resolution. The `grain` column says which a row is, rather than
    /// the two shapes being silently mixed: on a day row the figures are that
    /// day's peak. The two never overlap — the switch is the day the oldest
    /// surviving reading falls in — so a consumer can plot the file as it comes
    /// without double-counting a day.
    ///
    /// `until` is inclusive at both grains and defaults to the end of time, so
    /// the one-argument call still means everything since `date`. Passing one
    /// makes the file the range the caller was looking at rather than the range
    /// that existed by the time the formatting finished — which is what lets this
    /// be handed to a task while a sweep carries on writing underneath it.
    ///
    /// `nonisolated`, and that is the point of the pair. This is a `queue.sync`
    /// over the whole range plus an ISO stamp and three `String(format:)` calls
    /// per row, and none of that belongs on the thread drawing the window whose
    /// button started it. Like the three accessors above it reaches `database`
    /// and `queue`; unlike them it also reads `calendar`, which is safe for the
    /// same reason — it is an immutable `let` of a `Sendable` type — and is
    /// needed because where the two grains meet is a day boundary.
    public nonisolated func exportCSV(since date: Date, until: Date = .distantFuture) -> String {
        let from = Self.seconds(date)
        let to = Self.seconds(until)
        // Lifted out so the closure below reaches nothing on the main actor.
        let calendar = self.calendar
        let rows: [HistoryDatabase.ExportRow] = queue.sync {
            // The oldest surviving reading decides where the grains meet, and
            // its own day goes out as readings rather than as its rollup: that
            // day may have been pruned into a fragment, but a reading that was
            // taken is never a claim about one that was not, and the whole
            // point of keeping fourteen days at full resolution is that they
            // come out at full resolution.
            let boundary = database.oldestSample().map { oldest in
                Self.seconds(calendar.startOfDay(for: Date(timeIntervalSince1970: TimeInterval(oldest))))
            }
            return database.export(since: from, until: to, samplesFrom: boundary)
        }

        var csv = "grain,provider,window,label,unit,at,used,limit,percent,resets\n"
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime]
        for row in rows {
            let fields = [
                row.grain,
                row.provider,
                row.windowKey,
                row.label,
                // Without it, "used 32.84 of 50" says nothing about whether the
                // reader is looking at dollars, messages or credits.
                row.unit,
                stamp.string(from: Date(timeIntervalSince1970: TimeInterval(row.at))),
                // `String(format:)` without a locale writes a decimal point in
                // every region, which is what a spreadsheet importing a CSV
                // expects and what a comma separator would break.
                String(format: "%.4f", row.used),
                String(format: "%.4f", row.limit),
                String(format: "%.2f", row.percent * 100),
                String(row.resets)
            ]
            csv += fields.map(Self.escaped).joined(separator: ",")
            csv += "\n"
        }
        return csv
    }

    /// RFC 4180 quoting. Provider labels carry commas ("Weekly, all models")
    /// and the odd quote, and one of them unescaped shifts every later column.
    private static func escaped(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    // MARK: - Helpers

    /// Seconds since 1970, as SQLite stores them. Clamped rather than converted
    /// straight through: `Int64(_:)` traps on a value out of range, and these
    /// dates are parsed out of a provider's JSON. The clamp is also what makes
    /// `Date.distantFuture` a usable ceiling — it lands at the year 3237 rather
    /// than overflowing.
    ///
    /// `nonisolated` because the accessors above are: it is arithmetic on its
    /// argument and reaches nothing on this object, and leaving it isolated would
    /// have made a date conversion the one thing that dragged them back onto the
    /// main actor.
    nonisolated private static func seconds(_ date: Date) -> Int64 {
        let value = date.timeIntervalSince1970.rounded()
        guard value.isFinite else { return 0 }
        return Int64(min(max(value, -4e10), 4e10))
    }

    private enum Key {
        static let isEnabled = "aibars.history.enabled"
    }
}

// MARK: - The connection

/// The connection, and everything that touches it.
///
/// Reached only from `UsageHistoryStore.queue`, which is serial — that queue is
/// the mutual exclusion, which is why nothing here takes a lock and why the
/// `@unchecked` is honest rather than a way past the compiler. Every method
/// swallows its own errors and answers whether anything changed: a reading that
/// could not be written down costs one point on a chart, and there is no
/// version of that worth failing a refresh over.
private final class HistoryDatabase: @unchecked Sendable {
    /// Bumped whenever the shape below changes. `migrate` applies every step
    /// above the number the file already carries.
    static let schemaVersion: Int32 = 1

    private let handle: OpaquePointer

    init(url: URL) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard status == SQLITE_OK, let opened = handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "code \(status)"
            sqlite3_close(handle)
            throw HistoryError.unavailable(message)
        }
        self.handle = opened
        do {
            // WAL so the main thread's reads are never blocked behind the
            // writer, and NORMAL because losing the last second of a usage
            // history to a power cut is not worth an fsync a minute.
            try exec("PRAGMA journal_mode = WAL")
            try exec("PRAGMA synchronous = NORMAL")
            try exec("PRAGMA busy_timeout = 2000")
            try migrate()
        } catch {
            sqlite3_close(opened)
            throw error
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    // MARK: - Schema

    private func migrate() throws {
        var version: Int32 = 0
        try query("PRAGMA user_version") { version = sqlite3_column_int($0, 0) }
        guard version <= Self.schemaVersion else { throw HistoryError.unsupportedSchema(Int(version)) }
        guard version < Self.schemaVersion else { return }

        try exec("BEGIN IMMEDIATE")
        do {
            if version < 1 { try createV1() }
            // `PRAGMA` takes no bound parameters, so this interpolates — of a
            // compile-time constant, never of anything read from the file.
            try exec("PRAGMA user_version = \(Self.schemaVersion)")
            try exec("COMMIT")
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    /// Three tables, and what each column is for where it is not obvious.
    ///
    /// `cap` rather than `limit` throughout: LIMIT is a keyword, and a column
    /// that has to be quoted at every call site eventually is not.
    ///
    /// `series` keeps the last reading it saw (`last_ts`, `last_pct`,
    /// `last_reset`) because both of the judgements made at write time — is this
    /// too soon, and did the window roll over — are about the step from the
    /// previous reading to this one, and reading it back out of `sample` would
    /// be a second query per metric per minute for a figure we had a moment ago.
    ///
    /// `sample.used` and `sample.cap` rather than a stored percentage: the same
    /// 400 messages are 80% of a Pro cap and 20% of a Max one, and only the pair
    /// survives a plan change. `boundary` marks the reading that opened a new
    /// window.
    ///
    /// `day` is the rollup, and it holds sums rather than averages so it can be
    /// updated one reading at a time. `hits` counts cap crossings, `resets`
    /// counts window rollovers; they are different questions — a window can roll
    /// over having never reached its cap, and a day can sit pinned at the cap
    /// without rolling over at all.
    private func createV1() throws {
        try exec("""
            CREATE TABLE IF NOT EXISTS series (
                id         INTEGER PRIMARY KEY,
                provider   TEXT NOT NULL,
                window_key TEXT NOT NULL,
                label      TEXT NOT NULL,
                unit       TEXT,
                last_ts    INTEGER NOT NULL DEFAULT 0,
                last_pct   REAL NOT NULL DEFAULT 0,
                last_reset INTEGER NOT NULL DEFAULT 0,
                UNIQUE (provider, window_key)
            )
            """)
        try exec("""
            CREATE TABLE IF NOT EXISTS sample (
                series   INTEGER NOT NULL,
                ts       INTEGER NOT NULL,
                used     REAL NOT NULL,
                cap      REAL NOT NULL,
                boundary INTEGER NOT NULL DEFAULT 0,
                UNIQUE (series, ts)
            )
            """)
        // The prune scans by time across every series, which the UNIQUE index
        // above cannot serve because it leads on the series.
        try exec("CREATE INDEX IF NOT EXISTS sample_ts ON sample (ts)")
        try exec("""
            CREATE TABLE IF NOT EXISTS day (
                series    INTEGER NOT NULL,
                day       INTEGER NOT NULL,
                peak      REAL NOT NULL,
                total     REAL NOT NULL,
                peak_used REAL NOT NULL,
                cap       REAL NOT NULL,
                samples   INTEGER NOT NULL,
                hits      INTEGER NOT NULL,
                resets    INTEGER NOT NULL,
                UNIQUE (series, day)
            )
            """)
    }

    // MARK: - Writing

    /// One payload's worth of readings, flattened by the store.
    struct Reading {
        let provider: String
        let windowKey: String
        let label: String
        let unit: String?
        let ts: Int64
        let day: Int64
        let used: Double
        let cap: Double
        let percent: Double
        /// 0 when the provider named no renewal date.
        let resetAt: Int64
    }

    /// Returns whether anything landed. One transaction for the batch: eleven
    /// providers with three windows each is thirty round trips per sweep, and
    /// each one of them would otherwise be its own fsync.
    func insert(_ readings: [Reading]) -> Bool {
        guard (try? exec("BEGIN IMMEDIATE")) != nil else { return false }
        var wrote = false
        for reading in readings {
            // A reading that fails is a reading lost, not a batch lost. Two
            // metrics whose labels normalise to the same key end up here too,
            // and the second is refused by UNIQUE (series, ts) rather than
            // doubling the day it belongs to.
            if (try? insert(one: reading)) == true { wrote = true }
        }
        guard (try? exec("COMMIT")) != nil else {
            try? exec("ROLLBACK")
            return false
        }
        return wrote
    }

    private func insert(one reading: Reading) throws -> Bool {
        // The label and unit are refreshed on every sighting, so the name a
        // chart shows is the one the provider uses now while the key it is
        // stored under never moves.
        try run("""
            INSERT INTO series (provider, window_key, label, unit) VALUES (?, ?, ?, ?)
            ON CONFLICT (provider, window_key)
            DO UPDATE SET label = excluded.label, unit = excluded.unit
            """, [.text(reading.provider), .text(reading.windowKey), .text(reading.label), .textOrNull(reading.unit)])

        var id: Int64 = 0
        var lastTS: Int64 = 0
        var lastPercent = 0.0
        var lastReset: Int64 = 0
        try query(
            "SELECT id, last_ts, last_pct, last_reset FROM series WHERE provider = ? AND window_key = ?",
            [.text(reading.provider), .text(reading.windowKey)]
        ) { statement in
            id = sqlite3_column_int64(statement, 0)
            lastTS = sqlite3_column_int64(statement, 1)
            lastPercent = sqlite3_column_double(statement, 2)
            lastReset = sqlite3_column_int64(statement, 3)
        }
        guard id != 0 else { return false }

        // Also the guard against a reading arriving out of order: an interval
        // that is negative fails this the same way a burst of refreshes does.
        guard lastTS == 0 || Double(reading.ts - lastTS) >= HistoryRetention.minimumInterval else {
            return false
        }

        // A window rolled over if the renewal date we were watching has passed
        // and the provider has named a later one. The requirement that the old
        // date be in the past is what makes this safe for a provider that
        // reports "resets in 5h" and so hands back a date that drifts forward
        // at every poll: a drifting date is always still in the future, and
        // without that clause every reading of such a provider would open a new
        // window. Where there is no date at all, a fall of `resetDrop` stands
        // in — the same threshold the forecast splits its fit on, so the two
        // agree about where a window began.
        let declared = reading.resetAt > 0 && lastReset > 0
            && lastReset <= reading.ts && reading.resetAt > lastReset
        let rolled = lastTS > 0 && (declared || lastPercent - reading.percent >= UsageForecast.resetDrop)

        // A cap hit is a crossing, counted next to the reading before it, which
        // is why it is counted here and not by grouping a day's rows later: the
        // reading before may belong to the previous day. `HistoryQuery.rollUp`
        // counts it the same way over raw samples, and the two have to agree —
        // a chart drawn from days and a chart drawn from readings are the same
        // chart at two zoom levels.
        let atCap = reading.percent >= HistoryQuery.capThreshold
        // A series whose first reading is already at the cap counts one hit.
        // The crossing happened before aibars was watching, but a day spent
        // pinned at the cap reporting no hits at all is the worse answer.
        let wasAtCap = lastTS > 0 && lastPercent >= HistoryQuery.capThreshold
        let crossed = atCap && !wasAtCap

        let inserted = try run("""
            INSERT OR IGNORE INTO sample (series, ts, used, cap, boundary) VALUES (?, ?, ?, ?, ?)
            """, [
                .integer(id), .integer(reading.ts), .real(reading.used), .real(reading.cap),
                .integer(rolled ? 1 : 0)
            ])
        // Nothing below runs for a reading already stored, which is what keeps
        // a double-record from counting twice in the day it belongs to.
        guard inserted == 1 else { return false }

        try run(
            "UPDATE series SET last_ts = ?, last_pct = ?, last_reset = ? WHERE id = ?",
            [.integer(reading.ts), .real(reading.percent), .integer(reading.resetAt), .integer(id)]
        )

        // The rollup is kept as readings land rather than rebuilt from the raw
        // rows on a timer. It costs one upsert per reading, today's row is
        // never stale, and — the reason it matters — a rollup that survives its
        // samples can never be recomputed from them once they are pruned.
        try run("""
            INSERT INTO day (series, day, peak, total, peak_used, cap, samples, hits, resets)
            VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)
            ON CONFLICT (series, day) DO UPDATE SET
                peak      = max(day.peak, excluded.peak),
                total     = day.total + excluded.total,
                peak_used = max(day.peak_used, excluded.peak_used),
                cap       = excluded.cap,
                samples   = day.samples + 1,
                hits      = day.hits + excluded.hits,
                resets    = day.resets + excluded.resets
            """, [
                .integer(id), .integer(reading.day), .real(reading.percent), .real(reading.percent),
                .real(reading.used), .real(reading.cap),
                .integer(crossed ? 1 : 0), .integer(rolled ? 1 : 0)
            ])
        return true
    }

    func forget(provider: String) -> Bool {
        var removed = 0
        let ids = "SELECT id FROM series WHERE provider = ?"
        removed += (try? run("DELETE FROM sample WHERE series IN (\(ids))", [.text(provider)])) ?? 0
        removed += (try? run("DELETE FROM day WHERE series IN (\(ids))", [.text(provider)])) ?? 0
        removed += (try? run("DELETE FROM series WHERE provider = ?", [.text(provider)])) ?? 0
        return removed > 0
    }

    func prune(samplesBefore sampleFloor: Int64, daysBefore dayFloor: Int64) -> Bool {
        var removed = 0
        removed += (try? run("DELETE FROM sample WHERE ts < ?", [.integer(sampleFloor)])) ?? 0
        removed += (try? run("DELETE FROM day WHERE day < ?", [.integer(dayFloor)])) ?? 0
        // A series whose every row has aged out is a name with nothing behind
        // it, and it would keep appearing in a picker for ever.
        removed += (try? run("""
            DELETE FROM series WHERE id NOT IN (
                SELECT series FROM sample UNION SELECT series FROM day
            )
            """)) ?? 0

        if removed > HistoryRetention.vacuumThreshold {
            // Outside any transaction, by SQLite's rule, and only after a prune
            // big enough to be worth rewriting the file for.
            try? exec("VACUUM")
        }
        return removed > 0
    }

    // MARK: - Reading

    func samples(provider: String, windowKey: String, since: Int64) -> [HistorySample] {
        var rows: [HistorySample] = []
        try? query("""
            SELECT sample.ts, sample.used, sample.cap
            FROM sample JOIN series ON series.id = sample.series
            WHERE series.provider = ? AND series.window_key = ? AND sample.ts >= ?
            ORDER BY sample.ts
            """, [.text(provider), .text(windowKey), .integer(since)]) { statement in
            rows.append(HistorySample(
                at: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                // The figures are stored as the provider gave them and divided
                // here. A stored percentage could not survive a plan change:
                // the same 400 messages are 80% of a Pro cap and 20% of a Max
                // one, and only the pair says which.
                percent: Self.ratio(used: sqlite3_column_double(statement, 1),
                                    cap: sqlite3_column_double(statement, 2))
            ))
        }
        return rows
    }

    func days(provider: String, windowKey: String, since: Int64) -> [HistoryDay] {
        var rows: [HistoryDay] = []
        try? query("""
            SELECT day.day, day.peak, day.total, day.samples, day.hits
            FROM day JOIN series ON series.id = day.series
            WHERE series.provider = ? AND series.window_key = ? AND day.day >= ?
            ORDER BY day.day
            """, [.text(provider), .text(windowKey), .integer(since)]) { statement in
            let samples = Int(sqlite3_column_int64(statement, 3))
            rows.append(HistoryDay(
                day: Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(statement, 0))),
                peak: sqlite3_column_double(statement, 1),
                // The stored total divided at the last moment, so the mean of a
                // day still being written to is the mean of what it holds now.
                mean: samples > 0 ? sqlite3_column_double(statement, 2) / Double(samples) : 0,
                capHits: Int(sqlite3_column_int64(statement, 4)),
                samples: samples
            ))
        }
        return rows
    }

    func series() -> [HistorySeriesID] {
        var rows: [HistorySeriesID] = []
        // The provider's own label for the window is stored and kept current,
        // but it is not handed back here: `HistorySeriesID` is an identity, and
        // an identity that carries prose is one rename away from two of it. The
        // label goes out in the export, where a person is reading the file; a
        // caller that wants to put a name on a series matches its own live
        // metric through `HistorySeriesID.windowKey(for:)` instead.
        try? query("SELECT provider, window_key FROM series ORDER BY provider, window_key") { statement in
            guard let provider = Self.text(statement, 0), let key = Self.text(statement, 1) else { return }
            rows.append(HistorySeriesID(providerID: provider, windowKey: key))
        }
        return rows
    }

    /// 0...1 from the pair as stored, clamped exactly as `UsageMetric.percent`
    /// clamps it: a NaN would survive `min`/`max` and become a day's peak.
    static func ratio(used: Double, cap: Double) -> Double {
        guard cap > 0, cap.isFinite, used.isFinite else { return 0 }
        return min(max(used / cap, 0), 1)
    }

    // MARK: - Export

    struct ExportRow {
        let grain: String
        let provider: String
        let windowKey: String
        let label: String
        let unit: String
        let at: Int64
        let used: Double
        let limit: Double
        /// 0...1. Carried rather than recomputed from the two figures beside
        /// it: on a day row the peak figure and the cap can come from different
        /// hours, and a plan that changed at noon would otherwise export a
        /// percentage neither reading ever had.
        let percent: Double
        let resets: Int
    }

    /// The oldest reading still stored, or nil when there are none.
    func oldestSample() -> Int64? {
        var oldest: Int64?
        try? query("SELECT min(ts) FROM sample") { statement in
            guard sqlite3_column_type(statement, 0) != SQLITE_NULL else { return }
            oldest = sqlite3_column_int64(statement, 0)
        }
        return oldest
    }

    /// Day rows below `samplesFrom`, raw rows at or above it, in time order,
    /// none of either past `until`. A nil boundary means there are no raw
    /// readings at all and the whole range is day rows.
    ///
    /// Two ceilings on the day query and they are different questions: `until` is
    /// the caller's range and is inclusive, `samplesFrom` is where the grain
    /// switches and is exclusive, because the day it names goes out as readings
    /// instead.
    func export(since: Int64, until: Int64, samplesFrom boundary: Int64?) -> [ExportRow] {
        var rows: [ExportRow] = []
        let dayCeiling = boundary ?? Int64.max
        try? query("""
            SELECT series.provider, series.window_key, series.label, series.unit,
                   day.day, day.peak_used, day.cap, day.peak, day.resets
            FROM day JOIN series ON series.id = day.series
            WHERE day.day >= ? AND day.day < ? AND day.day <= ?
            ORDER BY day.day, series.provider, series.window_key
            """, [.integer(since), .integer(dayCeiling), .integer(until)]) { statement in
            guard let provider = Self.text(statement, 0), let key = Self.text(statement, 1) else { return }
            rows.append(ExportRow(
                grain: "day",
                provider: provider,
                windowKey: key,
                label: Self.text(statement, 2) ?? key,
                unit: Self.text(statement, 3) ?? "",
                at: sqlite3_column_int64(statement, 4),
                used: sqlite3_column_double(statement, 5),
                limit: sqlite3_column_double(statement, 6),
                percent: sqlite3_column_double(statement, 7),
                resets: Int(sqlite3_column_int64(statement, 8))
            ))
        }

        guard let boundary else { return rows }
        try? query("""
            SELECT series.provider, series.window_key, series.label, series.unit,
                   sample.ts, sample.used, sample.cap, sample.boundary
            FROM sample JOIN series ON series.id = sample.series
            WHERE sample.ts >= ? AND sample.ts <= ?
            ORDER BY sample.ts, series.provider, series.window_key
            """, [.integer(max(since, boundary)), .integer(until)]) { statement in
            guard let provider = Self.text(statement, 0), let key = Self.text(statement, 1) else { return }
            let used = sqlite3_column_double(statement, 5)
            let cap = sqlite3_column_double(statement, 6)
            rows.append(ExportRow(
                grain: "sample",
                provider: provider,
                windowKey: key,
                label: Self.text(statement, 2) ?? key,
                unit: Self.text(statement, 3) ?? "",
                at: sqlite3_column_int64(statement, 4),
                used: used,
                limit: cap,
                percent: Self.ratio(used: used, cap: cap),
                resets: sqlite3_column_int64(statement, 7) != 0 ? 1 : 0
            ))
        }
        return rows
    }

    // MARK: - Statements

    /// What a bound parameter can be. An enum rather than overloads because
    /// most statements here bind a mixture, and a positional array keeps the
    /// binding in the same order as the question marks.
    enum Value {
        case integer(Int64)
        case real(Double)
        case text(String)
        case textOrNull(String?)
    }

    private func exec(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &message) == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(message)
            throw HistoryError.unavailable(text)
        }
    }

    /// Runs one statement to completion and answers how many rows it changed.
    @discardableResult
    private func run(_ sql: String, _ values: [Value] = []) throws -> Int {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        let status = sqlite3_step(statement)
        guard status == SQLITE_DONE || status == SQLITE_ROW else {
            throw HistoryError.unavailable(String(cString: sqlite3_errmsg(handle)))
        }
        return Int(sqlite3_changes(handle))
    }

    /// Runs a query, handing each row to `row`.
    private func query(_ sql: String, _ values: [Value] = [], row: (OpaquePointer) -> Void) throws {
        let statement = try prepare(sql, values)
        defer { sqlite3_finalize(statement) }
        while sqlite3_step(statement) == SQLITE_ROW {
            row(statement)
        }
    }

    private func prepare(_ sql: String, _ values: [Value]) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let prepared = statement else {
            let message = String(cString: sqlite3_errmsg(handle))
            sqlite3_finalize(statement)
            throw HistoryError.unavailable(message)
        }
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case .integer(let number):
                sqlite3_bind_int64(prepared, index, number)
            case .real(let number):
                // A NaN binds as NULL and comes back as 0, which would put a
                // hole in a chart rather than a wrong point. Nothing upstream
                // should send one; this is the last place to notice.
                sqlite3_bind_double(prepared, index, number.isFinite ? number : 0)
            case .text(let string):
                sqlite3_bind_text(prepared, index, string, -1, SQLITE_TRANSIENT)
            case .textOrNull(let string):
                if let string {
                    sqlite3_bind_text(prepared, index, string, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(prepared, index)
                }
            }
        }
        return prepared
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }
}
