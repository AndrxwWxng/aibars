import Foundation
import Combine

/// The sample history the forecast fits its line to, and the only part of
/// forecasting that touches disk.
///
/// One ring per provider id — "claude#2", not "claude", because two accounts of
/// one service are spent at their own rates and have to be projected apart.
/// Each ring holds at most `capacity` samples covering six hours, which is
/// deliberately longer than `UsageForecast.window`: how far back the fit looks
/// is the forecast's decision, and a store that pre-trimmed to the fit's window
/// would silently override it.
///
/// Rings are persisted as JSON under "aibars.forecast.samples.<id>". A fit needs
/// three samples five minutes apart and the app polls once a minute, so without
/// this the launch sweep would leave every row with nothing to say for a quarter
/// of an hour — long enough that a user who opens the panel, reads it and closes
/// it again would never see a pace line at all.
@MainActor
public final class UsageTrendStore: ObservableObject {
    /// The app's single instance. Shared because the refresh loop writes to it
    /// from the app delegate's side of the app while the rows read from it,
    /// exactly as they share AppState and AppearanceSettings.
    public static let shared = UsageTrendStore()

    // MARK: - Published state

    /// The latest projection per provider id, for observers that need to know
    /// something moved. Rows should read `projection(for:)` instead: it expires
    /// an answer whose samples have gone stale, which this dictionary cannot do
    /// on its own because nothing recomputes while a provider is backed off.
    @Published public private(set) var projections: [String: UsageProjection] = [:]

    /// Whether rows show the pace line.
    ///
    /// The one user-facing setting forecasting has, and it lives here rather
    /// than in AppearanceSettings because it is the only one, and because a
    /// pace line that is switched off should also be a store nobody has to ask
    /// about.
    @Published public var showsPaceInPanel: Bool {
        didSet { store.set(showsPaceInPanel, forKey: Key.showsPace) }
    }

    // MARK: - Shape of the ring

    /// How much history a ring keeps. Everything past this is dropped on the
    /// next sample rather than on a timer, so an app left idle overnight costs
    /// nothing until it is used again.
    private static let history: TimeInterval = 6 * 60 * 60

    /// The closest two samples are allowed to be.
    ///
    /// Someone holding ⌘R produces ten polls in as many seconds, all carrying
    /// the figure the provider cached. Ten near-identical points at the front of
    /// a recency-weighted fit outweigh everything behind them and read as a flat
    /// burn rate, which is the one answer that is certainly wrong.
    private static let minimumGap: TimeInterval = 30

    // MARK: - State

    private let store: UserDefaults
    private let capacity: Int
    private let now: () -> Date
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var rings: [String: [UsageSample]] = [:]
    /// The last renewal date each provider reported, kept so a projection can be
    /// recomputed without the usage payload that carried it.
    private var resetDates: [String: Date] = [:]

    /// `store` and `now` are injectable so tests get a scratch domain and a
    /// clock they can move, rather than the user's settings and a wall clock
    /// that makes a five-minute span take five minutes to arrange.
    public init(
        store: UserDefaults = .standard,
        // Six hours at the closest spacing a sample is allowed to have, so
        // `history` is what actually bounds the ring at every refresh interval.
        // A count-based cap of 60 made the documented six hours true only at
        // intervals of six minutes or more — which are exactly the intervals
        // where nothing reads the ring anyway.
        capacity: Int = Int(6 * 60 * 60 / 30),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        // A ring smaller than the fit's own minimum can never produce an
        // answer, so a caller asking for one gets the minimum instead of a
        // store that silently never forecasts.
        self.capacity = max(UsageForecast.minimumSamples, capacity)
        self.now = now
        // `object(forKey:)` rather than `bool(forKey:)`: the latter answers
        // false for a key nobody has written, which would ship the pace line
        // switched off.
        self.showsPaceInPanel = store.object(forKey: Key.showsPace) as? Bool ?? true
        load()
    }

    // MARK: - Recording

    /// Adds one reading to `providerID`'s ring and reprojects it.
    ///
    /// The id is passed separately from `data.providerID` because rows are keyed
    /// per account and the payload only knows which service it came from.
    public func record(_ data: UsageData, for providerID: String) {
        let metric = data.primary
        // A status-only row has no cap to run out of, and `UsageMetric.percent`
        // answers 0 for one. Sampling that would forecast copilot as pinned at
        // zero for ever instead of saying nothing about it, so any history it
        // already has goes too.
        guard metric.limit > 0, metric.limit.isFinite, metric.used.isFinite else {
            forget(providerID)
            return
        }

        // The reading was true when it was fetched, not when it reached here. A
        // payload-stamped date in the future would sit at the head of the ring
        // for six hours and hold every later sample out on the gap rule, so it
        // is pulled back to the present.
        let at = min(data.fetchedAt, now())
        var ring = rings[providerID] ?? []
        // A negative interval is a clock that moved backwards, and it fails this
        // the same way a burst of refreshes does.
        if let last = ring.last, at.timeIntervalSince(last.at) < Self.minimumGap { return }

        ring.append(UsageSample(at: at, percent: metric.percent))
        rings[providerID] = trim(ring, asOf: at)
        resetDates[providerID] = metric.resetDate
        persist(providerID)
        reproject(providerID)
    }

    /// Drops everything known about a provider, on disk as well as in memory.
    /// Called when a service is signed out, and every minute for a service that
    /// reports no cap.
    public func forget(_ providerID: String) {
        // Guarded because the status-only case calls this on every sweep, and
        // assigning to a `@Published` dictionary republishes it whether or not
        // the assignment changed anything.
        guard rings[providerID] != nil || projections[providerID] != nil else { return }
        rings[providerID] = nil
        resetDates[providerID] = nil
        projections[providerID] = nil
        store.removeObject(forKey: Key.samples(providerID))
    }

    // MARK: - Reading

    /// The ring as the forecast would see it, oldest first. Empty for a provider
    /// with no history, which is not the same as a provider with no pace.
    public func samples(for providerID: String) -> [UsageSample] {
        rings[providerID] ?? []
    }

    /// The current projection, or nil when there is nothing honest to say.
    ///
    /// Projections are computed when a sample lands, and a provider serving a
    /// backoff stops sending them. The fit would refuse those samples as stale;
    /// this refuses the answer built from them for the same reason, rather than
    /// leaving a half-hour-old countdown on screen until the provider recovers.
    public func projection(for providerID: String) -> UsageProjection? {
        guard let last = rings[providerID]?.last,
              now().timeIntervalSince(last.at) <= UsageForecast.stalenessLimit
        else { return nil }
        return projections[providerID]
    }

    // MARK: - Ring maintenance

    private func trim(_ ring: [UsageSample], asOf date: Date) -> [UsageSample] {
        let cutoff = date.addingTimeInterval(-Self.history)
        // The upper bound only matters on the way in from disk: a sample later
        // than the clock means the clock moved, and the fit reads it as a
        // negative arm.
        var kept = ring.filter { $0.at >= cutoff && $0.at <= date }
        if kept.count > capacity { kept.removeFirst(kept.count - capacity) }
        return kept
    }

    private func reproject(_ providerID: String) {
        let projection = UsageForecast.project(
            rings[providerID] ?? [],
            now: now(),
            resetAt: resetDates[providerID]
        )
        // Eleven services polled once a minute would otherwise republish the
        // whole panel every minute to say that none of them had moved.
        guard projections[providerID] != projection else { return }
        projections[providerID] = projection
    }

    // MARK: - Persistence

    /// The on-disk shape. The renewal date rides along with the samples because
    /// a projection rebuilt at launch without it says "on pace to cap" about a
    /// window that resets before the cap is reached.
    private struct StoredRing: Codable {
        let samples: [UsageSample]
        let resetAt: Date?
    }

    private func persist(_ providerID: String) {
        let key = Key.samples(providerID)
        guard let ring = rings[providerID], !ring.isEmpty else {
            store.removeObject(forKey: key)
            return
        }
        let stored = StoredRing(samples: ring, resetAt: resetDates[providerID])
        // A failed encode costs this launch's history and nothing else; there is
        // no version of that worth interrupting a refresh over.
        guard let data = try? encoder.encode(stored) else { return }
        store.set(data, forKey: key)
    }

    /// Reads every ring back at launch.
    ///
    /// The provider ids come out of the keys themselves rather than an index
    /// written alongside them: an index is one more thing that can disagree with
    /// what is actually stored, and this runs once, before the first sweep.
    private func load() {
        let reference = now()
        for (key, value) in store.dictionaryRepresentation() where key.hasPrefix(Key.samplePrefix) {
            let providerID = String(key.dropFirst(Key.samplePrefix.count))
            guard !providerID.isEmpty,
                  let data = value as? Data,
                  let stored = try? decoder.decode(StoredRing.self, from: data)
            else {
                // An older shape or a half-written value is not recoverable, and
                // leaving it would mean failing to read it at every launch from
                // now on.
                store.removeObject(forKey: key)
                continue
            }

            let ring = trim(stored.samples, asOf: reference)
            guard !ring.isEmpty else {
                store.removeObject(forKey: key)
                continue
            }
            rings[providerID] = ring
            resetDates[providerID] = stored.resetAt
            reproject(providerID)
        }
    }

    private enum Key {
        static let showsPace = "aibars.forecast.showsPace"
        static let samplePrefix = "aibars.forecast.samples."
        static func samples(_ providerID: String) -> String { samplePrefix + providerID }
    }
}
