import Foundation
import SQLite3
import SwiftUI

/// OpenCode's own hosted usage — the Go subscription and the Zen pay-as-you-go
/// gateway — read out of the database OpenCode already keeps on this Mac.
///
/// There is nothing to sign into and no request to make. OpenCode records every
/// assistant message it bills, with the cost it charged, in
/// `~/.local/share/opencode/opencode*.db`; that file is the whole source.
///
/// What this produces is *observed local spend*. OpenCode publishes no usage
/// API, so a Go account also used from a second machine reads low here, and a
/// session OpenCode has not finished writing is not yet visible. The row says
/// "this Mac" for exactly that reason: the caps below are the published plan
/// limits, which are facts about the product, but the numerator is only what
/// this machine saw.
public final class OpenCodeProvider: ObservableObject, UsageProvider {
    public let id: String
    /// The account this instance follows, when a service is signed into more
    /// than once. Nil is the only-account case.
    public let accountID: String?
    public var serviceID: String { "opencode" }
    public let displayName = "OpenCode"
    public let iconName = "terminal.fill"

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false

    private let userDefaults = UserDefaults.standard
    private let enabledKey: String
    /// Signing out of a provider with no credential can only mean "stop showing
    /// this", so the choice has to survive a relaunch on its own key — the
    /// database it reads will still be there next launch.
    private let dismissedKey: String
    private let reader = OpenCodeReader()

    public init(accountID: String? = nil) {
        self.accountID = accountID
        self.id = accountID.map { "opencode#\($0)" } ?? "opencode"
        self.enabledKey = "aibars.\(self.id).enabled"
        self.dismissedKey = "aibars.\(self.id).dismissed"
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = Self.canRead(userDefaults: userDefaults, dismissedKey: dismissedKey)
    }

    // MARK: - Where OpenCode keeps its data

    /// `$OPENCODE_DATA_DIR`, then `$XDG_DATA_HOME/opencode`, then
    /// `~/.local/share/opencode`. The environment is a parameter so the
    /// resolution can be exercised without touching the process it runs in.
    public static func dataDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let explicit = environment["OPENCODE_DATA_DIR"], !explicit.isEmpty {
            return URL(fileURLWithPath: (explicit as NSString).expandingTildeInPath, isDirectory: true)
        }
        if let xdg = environment["XDG_DATA_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: (xdg as NSString).expandingTildeInPath, isDirectory: true)
                .appendingPathComponent("opencode", isDirectory: true)
        }
        return home
            .appendingPathComponent(".local", isDirectory: true)
            .appendingPathComponent("share", isDirectory: true)
            .appendingPathComponent("opencode", isDirectory: true)
    }

    /// Every `opencode*.db` in the data directory, because OpenCode partitions
    /// by release channel — stable is `opencode.db`, the preview line is
    /// `opencode-next.db` — and a user on both has spend in both. Sidecars are
    /// excluded by the extension test: a WAL file is `opencode.db-wal`, whose
    /// path extension is `db-wal`.
    static func databases(in directory: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names
            .filter { $0.hasPrefix("opencode") && ($0 as NSString).pathExtension == "db" }
            .sorted()
            .map { directory.appendingPathComponent($0) }
    }

    private static func canRead(userDefaults: UserDefaults, dismissedKey: String) -> Bool {
        guard !userDefaults.bool(forKey: dismissedKey) else { return false }
        return !databases(in: dataDirectory()).isEmpty
    }

    // MARK: - UsageProvider

    public func fetchUsage() async throws -> UsageData {
        let directory = Self.dataDirectory()
        let databases = Self.databases(in: directory)
        guard !databases.isEmpty else {
            throw ProviderError.configuration(
                "No OpenCode database in \(directory.path). Run an OpenCode session, then refresh."
            )
        }

        let now = Date()
        let rows = try await reader.rows(in: databases, since: now.addingTimeInterval(-Self.retention))
        let hasGo = Self.hasGoSubscription(in: directory)
        return OpenCodeUsageParser.parse(rows: rows, hasGo: hasGo, now: now)
    }

    /// How far back the read reaches. The longest window drawn is a monthly
    /// cycle, which can run 31 days; the rest of the budget is there so the
    /// cycle's anchor day can be recovered from history rather than assumed.
    private static let retention: TimeInterval = 400 * 24 * 3600

    /// Go is an OAuth login; a Zen key is pasted. Both live under the same
    /// `opencode` key in `auth.json`, and `type` is what tells them apart.
    ///
    ///     { "opencode": { "type": "oauth", "access": "…", "refresh": "…" } }
    ///
    /// A missing or unreadable file is not an error: it only means no Go, and
    /// the Zen view of the same data still stands on its own.
    static func hasGoSubscription(in directory: URL) -> Bool {
        let url = directory.appendingPathComponent("auth.json")
        guard let data = try? Data(contentsOf: url) else { return false }
        return OpenCodeUsageParser.hasGoSubscription(authJSON: data)
    }

    public func authenticate() async throws {
        userDefaults.set(false, forKey: dismissedKey)
        let available = !Self.databases(in: Self.dataDirectory()).isEmpty
        await MainActor.run { self.isAuthenticated = available }
        guard available else {
            throw ProviderError.configuration(
                "No OpenCode database found. Run an OpenCode session, then try again."
            )
        }
    }

    /// There is no credential to revoke — the data is a file OpenCode owns — so
    /// the only honest meaning of signing out is "stop reading it".
    public func signOut() async throws {
        userDefaults.set(true, forKey: dismissedKey)
        await MainActor.run { self.isAuthenticated = false }
    }

    public func saveTokenManually(_ token: String, source: SessionSource = .manualPaste) throws {
        throw ProviderError.configuration(
            "OpenCode has no token to paste. aibars reads the local database at "
            + "\(Self.dataDirectory().path)."
        )
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: enabledKey)
    }
}

// MARK: - One billed message

/// One assistant message OpenCode billed, reduced to what a meter needs.
public struct OpenCodeMessage: Hashable {
    public let createdAt: Date
    /// OpenCode's own provider id: `opencode-go` for the subscription,
    /// `opencode` for the Zen gateway. Anything else is another vendor billing
    /// the user directly and belongs on that vendor's row, not this one.
    public let providerID: String
    /// What OpenCode says it charged, in dollars. Its own accounting, not a
    /// figure imputed from token counts and a price list.
    public let cost: Double
    /// Input, output, reasoning and cache added together, because `tokens.total`
    /// is absent on some rows and the parts are present on all of them.
    public let tokens: Int

    public init(createdAt: Date, providerID: String, cost: Double, tokens: Int) {
        self.createdAt = createdAt
        self.providerID = providerID
        self.cost = cost
        self.tokens = tokens
    }

    /// Decodes one `message.data` column, verified against a live
    /// `opencode.db`:
    ///
    ///     { "role": "assistant", "cost": 0.0051474,
    ///       "tokens": { "input": 26, "output": 347, "reasoning": 0,
    ///                   "cache": { "read": 78720, "write": 0 } },
    ///       "modelID": "…", "providerID": "minimax",
    ///       "time": { "created": 1786324596734, "completed": … } }
    ///
    /// Returns nil for anything that is not a billed assistant message. User
    /// and system messages carry no cost, and a row without a provider cannot
    /// be attributed to one.
    public static func decode(dataColumn json: String, createdAt: Date) -> OpenCodeMessage? {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              raw["role"] as? String == "assistant",
              let providerID = raw["providerID"] as? String, !providerID.isEmpty else {
            return nil
        }

        let cost = ProviderNumber.coerce(raw["cost"]) ?? 0
        // `time.created` is the message's own timestamp in milliseconds and
        // matched the column on every row sampled; the column is the fallback
        // because it is declared NOT NULL and the JSON field is not.
        let created = ProviderNumber.coerce((raw["time"] as? [String: Any])?["created"])
            .map { Date(timeIntervalSince1970: $0 / 1000) } ?? createdAt

        let counts = raw["tokens"] as? [String: Any] ?? [:]
        let cached = counts["cache"] as? [String: Any] ?? [:]
        let tokens = [
            counts["input"], counts["output"], counts["reasoning"],
            cached["read"], cached["write"]
        ].reduce(0.0) { $0 + (ProviderNumber.coerce($1) ?? 0) }

        return OpenCodeMessage(
            createdAt: created,
            providerID: providerID,
            cost: cost.isFinite ? cost : 0,
            tokens: tokens.isFinite ? Int(tokens.rounded()) : 0
        )
    }
}

// MARK: - Reading the database

/// Reads the OpenCode databases and remembers what it read.
///
/// An actor because the cache is the only thing keeping a per-minute refresh
/// from re-copying and re-parsing the database every time, and `fetchUsage`
/// can be entered from any task.
actor OpenCodeReader {
    /// A file's identity for cache purposes. The WAL sidecar is folded in
    /// deliberately: SQLite can leave the main database's size and mtime
    /// untouched for a long time while every new message lands in
    /// `opencode.db-wal`, so a stamp taken from the main file alone would
    /// report "nothing has changed" through a whole working session.
    struct Stamp: Equatable {
        let bytes: Int64
        let modified: Date
    }

    private struct Cached {
        let stamp: Stamp
        let rows: [OpenCodeMessage]
    }

    private var cache: [String: Cached] = [:]

    /// Rows from every database given, unioned and ordered oldest first. A
    /// database that cannot be read is skipped rather than fatal — one channel
    /// being locked or malformed should not blank out the other — but if none
    /// of them yielded anything, the first failure is thrown so the row can say
    /// why instead of showing a silent zero.
    func rows(in databases: [URL], since cutoff: Date) throws -> [OpenCodeMessage] {
        var rows: [OpenCodeMessage] = []
        var failure: Error?
        var read = false

        for database in databases {
            let key = database.path
            let stamp = Self.stamp(of: database)
            if let cached = cache[key], cached.stamp == stamp {
                rows.append(contentsOf: cached.rows)
                read = true
                continue
            }
            do {
                let fresh = try Self.read(database, since: cutoff)
                cache[key] = Cached(stamp: stamp, rows: fresh)
                rows.append(contentsOf: fresh)
                read = true
            } catch {
                if failure == nil { failure = error }
            }
        }

        if !read, let failure { throw failure }
        return rows.sorted { $0.createdAt < $1.createdAt }
    }

    private static func stamp(of database: URL) -> Stamp {
        var bytes: Int64 = 0
        var modified = Date.distantPast
        for path in [database.path, database.path + "-wal", database.path + "-shm"] {
            guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { continue }
            bytes += (attributes[.size] as? NSNumber)?.int64Value ?? 0
            if let date = attributes[.modificationDate] as? Date, date > modified { modified = date }
        }
        return Stamp(bytes: bytes, modified: modified)
    }

    /// The schema this query depends on, read off a live `opencode.db`:
    ///
    ///     CREATE TABLE `message` (
    ///       `id` text PRIMARY KEY, `session_id` text NOT NULL,
    ///       `time_created` integer NOT NULL, `time_updated` integer NOT NULL,
    ///       `data` text NOT NULL, …)
    ///
    /// It is checked before it is used rather than assumed. OpenCode migrates
    /// this database on its own schedule, and a renamed column should read as
    /// "aibars cannot read this yet", not as a user whose usage silently went
    /// to zero.
    private static func read(_ database: URL, since cutoff: Date) throws -> [OpenCodeMessage] {
        let snapshot = try SQLiteSnapshot(of: database)
        defer { snapshot.close() }

        var columns: Set<String> = []
        try snapshot.query("PRAGMA table_info(`message`)") { statement in
            if let name = SQLiteSnapshot.text(statement, 1) { columns.insert(name) }
        }
        let required: Set<String> = ["time_created", "data"]
        guard required.isSubset(of: columns) else {
            throw ProviderError.configuration(
                "\(database.lastPathComponent) does not have the message columns aibars reads "
                + "(\(required.sorted().joined(separator: ", "))). OpenCode may have changed its schema."
            )
        }

        // Two filters, both cheap, both re-checked in Swift. The timestamp is
        // milliseconds since the epoch and is interpolated rather than bound
        // because `SQLiteSnapshot.query` binds text only and this is an Int64
        // this file computed. The LIKE narrows the JSON decode to OpenCode's
        // own gateways: `data` is compact JSON with no space after the colon,
        // so the literal substring is what a hosted row actually contains. A
        // false positive costs one discarded decode; `OpenCodeMessage.decode`
        // and the parser both re-check the provider properly.
        let epochMilliseconds = Int64((cutoff.timeIntervalSince1970 * 1000).rounded())
        var rows: [OpenCodeMessage] = []
        try snapshot.query(
            """
            SELECT time_created, data FROM message
             WHERE time_created >= \(epochMilliseconds)
               AND data LIKE '%"providerID":"opencode%'
            """
        ) { statement in
            let created = Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, 0)) / 1000)
            guard let json = SQLiteSnapshot.text(statement, 1),
                  let message = OpenCodeMessage.decode(dataColumn: json, createdAt: created),
                  OpenCodeChannel.isHosted(message.providerID) else { return }
            rows.append(message)
        }
        return rows
    }
}

// MARK: - Which gateway a message went through

/// OpenCode bills its hosted models through two channels, and they are metered
/// differently: Go is a subscription with published caps, Zen is prepaid
/// credit with none.
enum OpenCodeChannel {
    static let go = "opencode-go"
    static let zen = "opencode"

    static func isHosted(_ providerID: String) -> Bool {
        providerID == go || providerID == zen
    }

    static func isGo(_ providerID: String) -> Bool {
        providerID == go
    }
}

// MARK: - Parsing

public enum OpenCodeUsageParser {
    /// The published Go plan limits, in dollars. These are facts about the
    /// product rather than anything read out of the database, which is what
    /// makes them honest denominators — the numerator is the part that is only
    /// as complete as this machine's history.
    enum GoPlan {
        static let sessionCap = 12.0
        static let sessionWindow: TimeInterval = 5 * 3600
        static let weeklyCap = 30.0
        static let monthlyCap = 60.0
    }

    /// `auth.json` is a flat map of provider id to credential. A Go login is an
    /// OAuth entry under `opencode`; a pasted Zen key is `{"type": "api"}`
    /// under the same id, and calling that a subscription would put three cap
    /// meters on an account that has none.
    public static func hasGoSubscription(authJSON: Data) -> Bool {
        guard let raw = try? JSONSerialization.jsonObject(with: authJSON) as? [String: Any],
              let entry = raw[OpenCodeChannel.zen] as? [String: Any] else { return false }
        return (entry["type"] as? String) == "oauth"
    }

    /// Everything the row shows, from local rows and one flag.
    ///
    /// `now` is a parameter rather than `Date()` because every window here is
    /// arithmetic on it, and arithmetic that reads the clock cannot be tested.
    public static func parse(rows: [OpenCodeMessage], hasGo: Bool, now: Date) -> UsageData {
        // Sorted here rather than trusted: three of the windows below read the
        // oldest row in a set to decide when it falls out, and this is a public
        // entry point that anyone may hand rows to in any order.
        let hosted = rows
            .filter { OpenCodeChannel.isHosted($0.providerID) }
            .sorted { $0.createdAt < $1.createdAt }
        let tagged = hosted.filter { OpenCodeChannel.isGo($0.providerID) }

        // Which rows the caps are drawn from. `opencode-go` is the tag a Go
        // message carries; the fallback exists because this was written against
        // a machine with Zen history and no Go login, so if a Go subscriber's
        // messages turn out to be recorded under the plain `opencode` id the
        // caps would otherwise sit at zero forever. It only ever applies when
        // auth.json has already confirmed the subscription, so a Zen-only user
        // is never billed against a cap they do not have.
        let goRows = (tagged.isEmpty && hasGo) ? hosted : tagged

        let monthly = monthlyCycle(anchor: goRows.first?.createdAt, now: now)
        // A lapsed subscriber keeps their history, so old Go rows alone do not
        // bring the caps back; usage inside the current cycle does.
        let showsCaps = hasGo || tagged.contains { $0.createdAt >= monthly.start }

        var metrics: [UsageMetric] = []

        if showsCaps {
            let sessionStart = now.addingTimeInterval(-GoPlan.sessionWindow)
            let inSession = goRows.filter { $0.createdAt >= sessionStart }
            metrics.append(UsageMetric(
                label: "Session",
                used: dollars(spend(inSession)),
                limit: GoPlan.sessionCap,
                unit: "USD",
                // The window rolls, so it does not reset: the first moment the
                // figure can fall is when its oldest charge ages out.
                resetDate: inSession.first.map { $0.createdAt.addingTimeInterval(GoPlan.sessionWindow) },
                windowLabel: "5h"
            ))

            let week = weeklyCycle(now: now)
            metrics.append(UsageMetric(
                label: "Weekly",
                used: dollars(spend(goRows, from: week.start)),
                limit: GoPlan.weeklyCap,
                unit: "USD",
                resetDate: week.reset,
                windowLabel: "Week"
            ))

            metrics.append(UsageMetric(
                label: "Monthly",
                used: dollars(spend(goRows, from: monthly.start)),
                limit: GoPlan.monthlyCap,
                unit: "USD",
                resetDate: monthly.reset,
                windowLabel: "Month"
            ))
        }

        // Spend has no ceiling, so `limit` stays 0: these are figures, not
        // meters, and Zen in particular is prepaid credit with no cap to draw
        // against. A period with nothing in it is left out rather than shown as
        // $0, which reads as a measured zero when it is really no data.
        let day = Calendar.current.startOfDay(for: now)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: day)
        let today = dollars(spend(hosted, from: day))
        if today > 0 {
            metrics.append(UsageMetric(label: "today", used: today, limit: 0, unit: "USD"))
        }
        if let yesterday {
            let amount = dollars(spend(hosted, from: yesterday, until: day))
            if amount > 0 {
                metrics.append(UsageMetric(label: "yesterday", used: amount, limit: 0, unit: "USD"))
            }
        }

        let monthStart = now.addingTimeInterval(-30 * 24 * 3600)
        let recent = hosted.filter { $0.createdAt >= monthStart }
        let spent30 = dollars(spend(recent))
        if spent30 > 0 {
            metrics.append(UsageMetric(label: "last 30 days", used: spent30, limit: 0, unit: "USD"))
        }
        let tokens30 = recent.reduce(0) { $0 + $1.tokens }
        if tokens30 > 0 {
            metrics.append(UsageMetric(
                label: "last 30 days", used: Double(tokens30), limit: 0, unit: "tokens"
            ))
        }

        // Nothing to report is a state, not a quota: a metric with no unit and
        // no ceiling renders as the sentence it is, rather than as a bar drawn
        // at zero on a service the user may never have used.
        let primary = metrics.first ?? UsageMetric(
            label: "No spend recorded on this Mac",
            used: 0,
            limit: 0
        )

        return UsageData(
            providerID: "opencode",
            fetchedAt: now,
            planName: showsCaps ? "Go" : (hosted.isEmpty ? nil : "Zen"),
            primary: primary,
            secondary: Array(metrics.dropFirst()),
            // Not an account name: the source is a file, and the one thing the
            // reader has to know about these figures is whose history they are.
            accountLabel: "this Mac",
            rawJSON: summary(hosted: hosted, go: goRows, showsCaps: showsCaps, now: now)
        )
    }

    // MARK: Windows

    /// The plan's week and month are stated in UTC, so the arithmetic is done
    /// there. The day tiles above use the user's own calendar, because "today"
    /// is a question about where the user is, not where the plan is.
    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        if let zone = TimeZone(identifier: "UTC") { calendar.timeZone = zone }
        return calendar
    }()

    /// The Go week runs from Monday 00:00 UTC.
    static func weeklyCycle(now: Date) -> (start: Date, reset: Date?) {
        var monday = DateComponents()
        monday.weekday = 2       // Gregorian weekdays start at Sunday = 1.
        monday.hour = 0
        monday.minute = 0
        monday.second = 0
        guard let next = utc.nextDate(after: now, matching: monday, matchingPolicy: .nextTime),
              let start = utc.date(byAdding: .day, value: -7, to: next) else {
            return (now, nil)
        }
        return (start, next)
    }

    /// The monthly cycle turns over on the day of the month the subscription
    /// first billed, which locally is the day of the earliest Go message there
    /// is. Falling back to the 1st is stated rather than hidden: with no Go
    /// history the anchor is unknown, and the calendar month is the only
    /// defensible guess.
    static func monthlyCycle(anchor: Date?, now: Date) -> (start: Date, reset: Date?) {
        let day = anchor.map { utc.component(.day, from: $0) } ?? 1

        func occurrence(monthsFromNow: Int) -> Date? {
            guard let base = utc.date(byAdding: .month, value: monthsFromNow, to: now) else { return nil }
            var components = utc.dateComponents([.year, .month], from: base)
            // A cycle anchored on the 31st still has to turn over in February.
            components.day = min(day, utc.range(of: .day, in: .month, for: base)?.count ?? 28)
            components.hour = 0
            components.minute = 0
            components.second = 0
            return utc.date(from: components)
        }

        guard var start = occurrence(monthsFromNow: 0) else { return (now, nil) }
        var reset = occurrence(monthsFromNow: 1)
        if start > now {
            reset = start
            start = occurrence(monthsFromNow: -1) ?? start
        }
        return (start, reset)
    }

    // MARK: Sums

    private static func spend(
        _ rows: [OpenCodeMessage],
        from start: Date = .distantPast,
        until end: Date = .distantFuture
    ) -> Double {
        rows.reduce(0) { total, row in
            guard row.createdAt >= start, row.createdAt < end else { return total }
            return total + row.cost
        }
    }

    /// Sub-cent precision is noise on a dollar meter, and the raw sum of a few
    /// thousand floating-point costs carries a tail of it.
    private static func dollars(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return (value * 100).rounded() / 100
    }

    /// What the raw-response inspector shows for a provider that never made a
    /// request. It says where the figures came from, because "observed on this
    /// Mac" is the one caveat a reader comparing these to an invoice needs.
    private static func summary(
        hosted: [OpenCodeMessage],
        go: [OpenCodeMessage],
        showsCaps: Bool,
        now: Date
    ) -> String? {
        let payload: [String: Any] = [
            "source": "local opencode database",
            "note": "observed spend on this Mac only; OpenCode publishes no usage API",
            "messages": hosted.count,
            "goMessages": go.count,
            "capsShown": showsCaps,
            "earliest": hosted.first.map { ProviderDate.iso8601.string(from: $0.createdAt) } ?? "",
            "latest": hosted.last.map { ProviderDate.iso8601.string(from: $0.createdAt) } ?? "",
            "readAt": ProviderDate.iso8601.string(from: now)
        ]
        return (try? JSONSerialization.data(withJSONObject: payload))?.base64EncodedString()
    }
}
