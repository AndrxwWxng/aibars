import Foundation

/// The last twenty-four hours of every row's headline window, already bucketed,
/// held in memory so a row can draw one without touching a database.
///
/// A row cannot read `UsageHistoryStore` directly and the reason is not taste.
/// The synchronous reads on that store are `queue.sync` from the main actor, and
/// that queue is also the writer's: eleven rows each asking for their own samples
/// inside one `body` pass is eleven SQLite queries on the thread drawing the
/// panel, some of them queued behind the insert transaction of the very sweep
/// that opened it. Measured on a fortnight of readings that is tens of
/// milliseconds per open, every open, for a drawing that describes yesterday.
///
/// So the reads happen once per landed reading, off the main actor through
/// `UsageHistoryStore.peaks(for:from:to:count:)`, and the row gets a dictionary
/// lookup. Deliberately **not** an `ObservableObject`: the reasoning
/// `ForecastLine` writes down for the trend store applies unchanged — the
/// samples are refreshed by the same sweep that publishes the usage the row is
/// drawn from, so the row is already being rebuilt whenever this has moved, and
/// observing as well would let a sparkline arrive on its own between refreshes.
/// The slot is reserved either way, so nothing could resize; what it would do is
/// redraw nine rows to report that one of them gained an hour.
///
/// Nothing primes this at launch, and that is a decision rather than an
/// oversight. `AppState.start()` begins the first sweep before the panel can be
/// opened, so a prime would be a second code path into the same call and would
/// read the database before `maintain()` had pruned it. The consequence, stated
/// so nobody files it: the first sweep after launch draws no trace and the
/// second, a refresh interval later, does. A twenty-four-hour trace is not a
/// live reading and does not need to arrive in the same frame as the number
/// above it.
@MainActor
public final class RowSparklineStore {

    /// The app's single instance, shared for the same reason `AppState` and
    /// `AppearanceSettings` are: the refresh loop writes to it from the app
    /// delegate's side of the app while the rows read from it.
    public static let shared = RowSparklineStore()

    // MARK: - Shape of the series

    /// How far back a row's trace looks. A rolling day, like `HistoryRange.day`,
    /// and not a calendar one: a trace that emptied itself at midnight would
    /// report the clock rather than the usage.
    public static let window: TimeInterval = 24 * 60 * 60

    /// One bucket an hour. At the shipped 356pt panel the text column is 304pt,
    /// so a bucket is 304 / 23 = 13.2pt — about the narrowest a run of them still
    /// reads as a shape rather than as hatching.
    ///
    /// Seven days at this width would be 24 sawteeth 1.4pt apart, which is
    /// texture and not a reading; a row's headline window is typically five hours
    /// or a day, so a day of it at an hour a bucket is the span that has anything
    /// in it to see.
    public static let buckets = 24

    /// The closest two rebuilds of one series may be.
    ///
    /// Five minutes, and it is derived rather than chosen: the buckets are an
    /// hour wide, so a rebuild can only ever change the last one, and a reading
    /// landing four minutes after the previous one moves that bucket's peak by an
    /// amount no 13pt column can show. Without the throttle a one-minute refresh
    /// interval would rebuild eleven series a minute for a drawing that changes
    /// twenty-four times a day.
    public static let minimumRefresh: TimeInterval = 300

    /// One row's trace, as the row receives it: no dates, no samples, no store.
    public struct Series: Equatable, Sendable {
        /// Oldest first, exactly `RowSparklineStore.buckets` long. `nil` is a
        /// bucket nothing landed in, and it is not zero — the same rule
        /// `HistoryQuery.buckets` keeps, and the whole reason a gap in the trace
        /// is drawn as a gap rather than as a night at the floor.
        public let peaks: [Double?]
        /// When the buckets were built, which is what the throttle above is
        /// measured against.
        public let takenAt: Date

        public init(peaks: [Double?], takenAt: Date) {
            self.peaks = peaks
            self.takenAt = takenAt
        }
    }

    // MARK: - State

    private var cache: [String: Series] = [:]
    /// Provider ids with a rebuild in flight. Without it a sweep landing while
    /// the previous rebuild is still on the database queue starts a second one,
    /// and the two race to write the same key.
    private var inFlight: Set<String> = []
    private let history: UsageHistoryStore?
    private let now: () -> Date

    /// `history` and `now` are injectable so a test gets a scratch file and a
    /// clock it can move, rather than the user's real history and a wall clock
    /// that makes the five-minute throttle take five minutes to assert.
    public init(
        history: UsageHistoryStore? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.history = history ?? UsageHistoryStore.shared
        self.now = now
    }

    // MARK: - Reading

    /// What the row draws, or nil when nothing has been built for it yet.
    ///
    /// A dictionary lookup and nothing else. This is called once per row per
    /// `body` pass, nine to fifteen times a pass, so it may not allocate, may not
    /// read the clock and may certainly not touch disk.
    public func series(for providerID: String) -> Series? {
        cache[providerID]
    }

    // MARK: - Recording

    /// Rebuilds one row's trace if it is stale, off the main actor.
    ///
    /// Hangs off `AppState.note(_:_:)`, which is the one place a reading lands,
    /// so a single-row refresh feeds it exactly as a sweep does — the same
    /// argument `AppState` already writes down for the trend store and the
    /// history store.
    ///
    /// A window with no cap is not recorded by `UsageHistoryStore` at all (its
    /// `reading(from:provider:at:)` drops anything with `limit <= 0`), so there is
    /// nothing to bucket and asking would be a query guaranteed to return
    /// nothing. The row's slot stays reserved and empty, exactly as its meter slot
    /// does.
    public func note(_ data: UsageData, for providerID: String) {
        guard let history, data.primary.limit > 0, data.primary.limit.isFinite else { return }
        let at = now()
        if let held = cache[providerID],
           at.timeIntervalSince(held.takenAt) < Self.minimumRefresh { return }
        guard inFlight.insert(providerID).inserted else { return }

        // The same key the store filed the reading under a moment ago, derived
        // the same way: comparing labels instead would miss a series whose
        // provider reworded its window between two releases.
        let series = HistorySeriesID(
            providerID: providerID,
            windowKey: HistorySeriesID.windowKey(for: data.primary.label)
        )
        let from = at.addingTimeInterval(-Self.window)
        Task { [weak self] in
            // `peaks` is nonisolated, so this suspension hands the main actor
            // back for the whole of the database read and the bucketing.
            let peaks = await history.peaks(
                for: series, from: from, to: at, count: Self.buckets
            )
            guard let self else { return }
            self.inFlight.remove(providerID)
            // An empty answer is a series with no readings in the last day, and
            // it is stored as such: caching it is what stops a row with no
            // history re-querying the database once a minute for ever.
            self.cache[providerID] = Series(peaks: peaks, takenAt: at)
        }
    }

    /// Drops one row's trace. Called on sign-out, from `AppState.forgetHistory`.
    ///
    /// Slot numbers are reused — sign out of "claude#2" and the next session
    /// found for that service takes the same id — so without this the new
    /// account's row would draw the previous account's day. That is not a stale
    /// number, it is a fabricated one, which is exactly the sentence
    /// `AppState.forgetHistory` already carries about the stored history.
    public func forget(_ providerID: String) {
        cache[providerID] = nil
        inFlight.remove(providerID)
    }
}
