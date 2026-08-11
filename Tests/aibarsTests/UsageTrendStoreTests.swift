import XCTest
import Combine
@testable import aibarsCore

/// A clock the tests move by hand.
///
/// Every rule in the store is a span — thirty seconds between samples, six hours
/// of history, fifteen minutes before an answer goes stale — and none of them
/// are worth waiting out in real time.
private final class TrendClock {
    private(set) var now: Date

    init(_ start: Date) { self.now = start }

    func advance(_ interval: TimeInterval) { now = now.addingTimeInterval(interval) }
}

/// The ring behind the pace line.
///
/// The fit itself is tested against samples; this is about what reaches the fit
/// — which readings are refused, what survives a restart, and what a provider
/// with nothing to say leaves behind.
final class UsageTrendStoreTests: XCTestCase {

    // MARK: - Harness

    /// Somewhere unremarkable. The absolute date never matters, only the gaps.
    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    private let prefix = "aibars.forecast.samples."

    /// A scratch domain per test, torn down afterwards, so one test's history is
    /// never another's launch state and nothing here touches the user's own
    /// settings.
    private func scratchDefaults(_ label: String = #function) throws -> UserDefaults {
        let name = "aibars.trend.tests.\(label).\(UUID().uuidString)"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func usage(
        _ used: Double,
        limit: Double = 100,
        at date: Date,
        resetDate: Date? = nil,
        providerID: String = "claude"
    ) -> UsageData {
        UsageData(
            providerID: providerID,
            fetchedAt: date,
            primary: UsageMetric(label: "5h window", used: used, limit: limit, unit: "%", resetDate: resetDate)
        )
    }

    /// Three samples six minutes apart: the shortest series the fit will accept,
    /// which is what most of these tests need and none of them care about.
    @MainActor
    private func fill(_ store: UsageTrendStore, id: String, clock: TrendClock) {
        store.record(usage(10, at: clock.now, providerID: id), for: id)
        clock.advance(180)
        store.record(usage(20, at: clock.now, providerID: id), for: id)
        clock.advance(180)
        store.record(usage(30, at: clock.now, providerID: id), for: id)
    }

    // MARK: - The gap rule

    @MainActor
    func testASecondReadingTooSoonIsDroppedAndALaterOneIsKept() throws {
        let clock = TrendClock(start)
        let store = UsageTrendStore(store: try scratchDefaults(), now: { clock.now })

        store.record(usage(10, at: clock.now), for: "claude")
        XCTAssertEqual(store.samples(for: "claude").count, 1)

        clock.advance(5)
        store.record(usage(11, at: clock.now), for: "claude")
        XCTAssertEqual(
            store.samples(for: "claude").count, 1,
            "a refresh five seconds later carries the provider's cached figure, not a new reading"
        )

        clock.advance(35)
        store.record(usage(12, at: clock.now), for: "claude")
        let samples = store.samples(for: "claude")
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(try XCTUnwrap(samples.last).percent, 0.12, accuracy: 1e-9)
    }

    /// The rule is "closer than thirty seconds", so thirty seconds itself is far
    /// enough apart.
    @MainActor
    func testThirtySecondsApartIsAcceptedAndAnythingUnderItIsNot() throws {
        let clock = TrendClock(start)
        let store = UsageTrendStore(store: try scratchDefaults(), now: { clock.now })

        store.record(usage(10, at: clock.now), for: "claude")
        clock.advance(29.5)
        store.record(usage(11, at: clock.now), for: "claude")
        XCTAssertEqual(store.samples(for: "claude").count, 1, "just inside the gap should still be refused")

        clock.advance(0.5)
        store.record(usage(12, at: clock.now), for: "claude")
        XCTAssertEqual(store.samples(for: "claude").count, 2, "exactly thirty seconds is far enough apart")
    }

    /// A clock that moves backwards — a daylight saving change, an ntp
    /// correction — fails the gap rule the same way a burst of refreshes does.
    @MainActor
    func testAReadingBeforeTheLastOneIsRefused() throws {
        let clock = TrendClock(start)
        let store = UsageTrendStore(store: try scratchDefaults(), now: { clock.now })

        store.record(usage(10, at: clock.now), for: "claude")
        clock.advance(-100)
        store.record(usage(50, at: clock.now), for: "claude")

        let samples = store.samples(for: "claude")
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(try XCTUnwrap(samples.first).at, start)
    }

    /// A payload stamped in the future would otherwise sit at the head of the
    /// ring and hold every real reading out on the gap rule.
    @MainActor
    func testAFutureTimestampIsPulledBackToNow() throws {
        let clock = TrendClock(start)
        let store = UsageTrendStore(store: try scratchDefaults(), now: { clock.now })

        store.record(usage(10, at: clock.now.addingTimeInterval(3600)), for: "claude")
        XCTAssertEqual(try XCTUnwrap(store.samples(for: "claude").first).at, start)

        clock.advance(40)
        store.record(usage(11, at: clock.now), for: "claude")
        XCTAssertEqual(
            store.samples(for: "claude").count, 2,
            "the next real reading was measured against an hour that never happened"
        )
    }

    // MARK: - Ring maintenance

    @MainActor
    func testTheOldestSamplesFallOffPastCapacity() throws {
        let clock = TrendClock(start)
        let store = UsageTrendStore(store: try scratchDefaults(), capacity: 4, now: { clock.now })

        for step in 0..<6 {
            store.record(usage(Double(step), at: clock.now), for: "claude")
            clock.advance(60)
        }

        let samples = store.samples(for: "claude")
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(try XCTUnwrap(samples.first).percent, 0.02, accuracy: 1e-9, "the two oldest should have gone")
        XCTAssertEqual(try XCTUnwrap(samples.last).percent, 0.05, accuracy: 1e-9)
        XCTAssertEqual(samples.map(\.at), samples.map(\.at).sorted(), "the ring should stay oldest first")
    }

    /// A ring smaller than the fit's own minimum could never produce an answer.
    @MainActor
    func testCapacityCannotBeSetBelowWhatTheFitNeeds() throws {
        let clock = TrendClock(start)
        let store = UsageTrendStore(store: try scratchDefaults(), capacity: 1, now: { clock.now })

        for step in 0..<5 {
            store.record(usage(Double(step * 10), at: clock.now), for: "claude")
            clock.advance(180)
        }

        XCTAssertEqual(store.samples(for: "claude").count, UsageForecast.minimumSamples)
    }

    /// Zero and negative capacities are the same mistake as one.
    @MainActor
    func testZeroAndNegativeCapacitiesStillHoldTheMinimum() throws {
        let clock = TrendClock(start)
        for capacity in [0, -7] {
            let store = UsageTrendStore(store: try scratchDefaults(), capacity: capacity, now: { clock.now })
            for step in 0..<5 {
                store.record(usage(Double(step * 10), at: clock.now), for: "claude")
                clock.advance(180)
            }
            XCTAssertEqual(
                store.samples(for: "claude").count, UsageForecast.minimumSamples,
                "capacity \(capacity) left a ring that can never be fitted"
            )
        }
    }

    @MainActor
    func testHistoryOlderThanSixHoursIsDroppedOnTheNextWrite() throws {
        let clock = TrendClock(start)
        let store = UsageTrendStore(store: try scratchDefaults(), now: { clock.now })

        store.record(usage(10, at: clock.now), for: "claude")
        clock.advance(60)
        let sixHoursOld = clock.now
        store.record(usage(11, at: clock.now), for: "claude")
        XCTAssertEqual(store.samples(for: "claude").count, 2)

        clock.advance(6 * 60 * 60)
        store.record(usage(12, at: clock.now), for: "claude")

        // The boundary is inclusive, so the sample exactly six hours old stays
        // and the one a minute older than that does not.
        XCTAssertEqual(store.samples(for: "claude").map(\.at), [sixHoursOld, clock.now])
    }

    // MARK: - Readings the store refuses

    /// A status-only row reports no cap, and `percent` answers zero for one.
    /// Sampling that would forecast the provider as pinned at zero for ever.
    @MainActor
    func testAReadingWithNoCapRecordsNothingAndClearsWhatWasThere() throws {
        let clock = TrendClock(start)
        let defaults = try scratchDefaults()
        let store = UsageTrendStore(store: defaults, now: { clock.now })

        fill(store, id: "copilot", clock: clock)
        XCTAssertNotNil(store.projections["copilot"])
        XCTAssertNotNil(defaults.object(forKey: prefix + "copilot"))

        clock.advance(180)
        store.record(usage(0, limit: 0, at: clock.now, providerID: "copilot"), for: "copilot")

        XCTAssertTrue(store.samples(for: "copilot").isEmpty)
        XCTAssertNil(store.projections["copilot"])
        XCTAssertNil(store.projection(for: "copilot"))
        XCTAssertNil(defaults.object(forKey: prefix + "copilot"), "the persisted ring outlived the cap it described")
    }

    @MainActor
    func testUnusableFiguresAreNeverSampled() throws {
        let clock = TrendClock(start)
        let store = UsageTrendStore(store: try scratchDefaults(), now: { clock.now })

        let refused: [(String, UsageData)] = [
            ("no cap", usage(10, limit: 0, at: clock.now)),
            ("negative cap", usage(10, limit: -100, at: clock.now)),
            ("infinite cap", usage(10, limit: .infinity, at: clock.now)),
            ("nan cap", usage(10, limit: .nan, at: clock.now)),
            ("infinite usage", usage(.infinity, at: clock.now)),
            ("nan usage", usage(.nan, at: clock.now))
        ]

        for (what, data) in refused {
            store.record(data, for: "claude")
            XCTAssertTrue(store.samples(for: "claude").isEmpty, "\(what) reached the ring")
            clock.advance(60)
        }
    }

    /// Zero used against a real cap is a true reading, not a missing one.
    @MainActor
    func testAnUntouchedQuotaIsStillWorthSampling() throws {
        let clock = TrendClock(start)
        let store = UsageTrendStore(store: try scratchDefaults(), now: { clock.now })

        store.record(usage(0, at: clock.now), for: "claude")
        let samples = store.samples(for: "claude")
        XCTAssertEqual(samples.count, 1)
        XCTAssertEqual(try XCTUnwrap(samples.first).percent, 0)
    }

    /// Providers overshoot soft limits and, once, reported a negative balance.
    @MainActor
    func testReadingsOutsideTheCapAreClamped() throws {
        let clock = TrendClock(start)
        let store = UsageTrendStore(store: try scratchDefaults(), now: { clock.now })

        store.record(usage(150, at: clock.now), for: "claude")
        clock.advance(60)
        store.record(usage(-40, at: clock.now), for: "claude")

        XCTAssertEqual(store.samples(for: "claude").map(\.percent), [1, 0])
    }

    // MARK: - Identity

    /// Rows are keyed per account; the payload only knows which service it came
    /// from, so the id the caller passes has to win.
    @MainActor
    func testTheRingIsKeyedByTheCallersIdNotThePayloads() throws {
        let clock = TrendClock(start)
        let store = UsageTrendStore(store: try scratchDefaults(), now: { clock.now })

        store.record(usage(10, at: clock.now, providerID: "claude"), for: "claude#2")

        XCTAssertEqual(store.samples(for: "claude#2").count, 1)
        XCTAssertTrue(store.samples(for: "claude").isEmpty)
    }

    @MainActor
    func testAProviderWithNoHistoryAnswersEmptyRatherThanNothing() throws {
        let clock = TrendClock(start)
        let store = UsageTrendStore(store: try scratchDefaults(), now: { clock.now })

        XCTAssertEqual(store.samples(for: "grok"), [])
        XCTAssertNil(store.projection(for: "grok"))
        XCTAssertTrue(store.projections.isEmpty)
    }

    // MARK: - Projection

    @MainActor
    func testProjectionAppearsOnlyOnceTheFitCanSupportItAndAgreesWithTheForecast() throws {
        let clock = TrendClock(start)
        let store = UsageTrendStore(store: try scratchDefaults(), now: { clock.now })

        var published: [[String: UsageProjection]] = []
        let subscription = store.$projections.sink { published.append($0) }
        defer { subscription.cancel() }

        store.record(usage(10, at: clock.now), for: "claude")
        clock.advance(180)
        store.record(usage(20, at: clock.now), for: "claude")
        XCTAssertNil(store.projections["claude"])
        XCTAssertEqual(published.count, 1, "two samples cannot be fitted, so nothing should have been republished")

        clock.advance(180)
        store.record(usage(30, at: clock.now), for: "claude")

        let expected = try XCTUnwrap(
            UsageForecast.project(store.samples(for: "claude"), now: clock.now, resetAt: nil)
        )
        XCTAssertEqual(published.count, 2, "crossing the minimum sample count should republish exactly once")
        XCTAssertEqual(store.projections["claude"], expected)
        XCTAssertEqual(published.last?["claude"], expected)
        XCTAssertEqual(expected.sampleCount, 3)
        XCTAssertEqual(expected.span, 360, accuracy: 1e-9)
    }

    /// Three samples inside five minutes is enough points and not enough time.
    @MainActor
    func testASeriesTooShortInTimeProducesNoProjection() throws {
        let clock = TrendClock(start)
        let store = UsageTrendStore(store: try scratchDefaults(), now: { clock.now })

        for step in 0..<4 {
            store.record(usage(Double(step * 5), at: clock.now), for: "claude")
            clock.advance(60)
        }

        XCTAssertEqual(store.samples(for: "claude").count, 4)
        XCTAssertNil(store.projections["claude"], "180 seconds of samples is under the fit's minimum span")
    }

    /// A provider serving a backoff stops sending readings, and a countdown
    /// built from the last ones before that goes stale with them.
    @MainActor
    func testAProjectionExpiresWithItsSamples() throws {
        let clock = TrendClock(start)
        let store = UsageTrendStore(store: try scratchDefaults(), now: { clock.now })
        fill(store, id: "claude", clock: clock)

        XCTAssertNotNil(store.projection(for: "claude"))

        clock.advance(UsageForecast.stalenessLimit)
        XCTAssertNotNil(store.projection(for: "claude"), "the limit itself is still inside the limit")

        clock.advance(1)
        XCTAssertNil(store.projection(for: "claude"))
        XCTAssertNotNil(
            store.projections["claude"],
            "nothing recomputes while a provider is backed off, so the dictionary still holds the answer"
        )
    }

    // MARK: - Forgetting

    @MainActor
    func testForgettingOneProviderLeavesTheOthersAlone() throws {
        let clock = TrendClock(start)
        let defaults = try scratchDefaults()
        let store = UsageTrendStore(store: defaults, now: { clock.now })

        fill(store, id: "claude", clock: clock)
        clock.advance(60)
        fill(store, id: "claude#2", clock: clock)

        store.forget("claude")

        XCTAssertTrue(store.samples(for: "claude").isEmpty)
        XCTAssertNil(store.projections["claude"])
        XCTAssertNil(defaults.object(forKey: prefix + "claude"))

        XCTAssertEqual(store.samples(for: "claude#2").count, 3)
        XCTAssertNotNil(store.projections["claude#2"])
        XCTAssertNotNil(defaults.object(forKey: prefix + "claude#2"))
    }

    /// Forget runs every sweep for a provider that reports no cap, and
    /// republishing a dictionary to say nothing changed redraws the panel.
    @MainActor
    func testForgettingSomethingUnknownRepublishesNothing() throws {
        let clock = TrendClock(start)
        let store = UsageTrendStore(store: try scratchDefaults(), now: { clock.now })

        var published = 0
        let subscription = store.$projections.sink { _ in published += 1 }
        defer { subscription.cancel() }

        store.forget("copilot")
        store.forget("copilot")

        XCTAssertEqual(published, 1, "only the subscription's own first value should have arrived")
    }

    // MARK: - Persistence

    @MainActor
    func testASecondStoreOverTheSameDefaultsSeesTheFirstsHistory() throws {
        let clock = TrendClock(start)
        let defaults = try scratchDefaults()

        let first = UsageTrendStore(store: defaults, now: { clock.now })
        fill(first, id: "claude", clock: clock)
        clock.advance(60)
        fill(first, id: "claude#2", clock: clock)

        let second = UsageTrendStore(store: defaults, now: { clock.now })

        for id in ["claude", "claude#2"] {
            XCTAssertEqual(second.samples(for: id), first.samples(for: id))
            // Against the forecast rather than against the first store's answer:
            // the two were computed at different instants, and the recency
            // weights differ enough to move the last bits of the slope.
            XCTAssertEqual(
                second.projections[id],
                UsageForecast.project(second.samples(for: id), now: clock.now, resetAt: nil)
            )
            XCTAssertNotNil(second.projections[id], "the reload should have a pace line to show immediately")
        }
    }

    /// The renewal date rides along with the samples, because a projection
    /// rebuilt without it claims a cap the window resets before reaching.
    @MainActor
    func testTheRenewalDateSurvivesTheReload() throws {
        let clock = TrendClock(start)
        let defaults = try scratchDefaults()
        let resetAt = start.addingTimeInterval(2 * 3600)

        let first = UsageTrendStore(store: defaults, now: { clock.now })
        for used in [10.0, 11.0, 12.0] {
            first.record(usage(used, at: clock.now, resetDate: resetAt), for: "claude")
            clock.advance(180)
        }
        XCTAssertEqual(first.projections["claude"]?.outcome, .resetsFirst(resetAt))

        let second = UsageTrendStore(store: defaults, now: { clock.now })
        XCTAssertEqual(second.projections["claude"]?.outcome, .resetsFirst(resetAt))
    }

    @MainActor
    func testStaleHistoryIsNotReadBackAtLaunch() throws {
        let clock = TrendClock(start)
        let defaults = try scratchDefaults()

        let first = UsageTrendStore(store: defaults, now: { clock.now })
        fill(first, id: "claude", clock: clock)

        clock.advance(7 * 60 * 60)
        let second = UsageTrendStore(store: defaults, now: { clock.now })

        XCTAssertTrue(second.samples(for: "claude").isEmpty)
        XCTAssertNil(second.projections["claude"])
        XCTAssertNil(
            defaults.object(forKey: prefix + "claude"),
            "a ring that can never be read again should not be carried forward"
        )
    }

    /// Samples later than the clock mean the clock moved, and the fit reads them
    /// as a negative arm.
    @MainActor
    func testHistoryFromTheFutureIsNotReadBackAtLaunch() throws {
        let clock = TrendClock(start.addingTimeInterval(4 * 3600))
        let defaults = try scratchDefaults()

        let first = UsageTrendStore(store: defaults, now: { clock.now })
        fill(first, id: "claude", clock: clock)

        let rewound = TrendClock(start)
        let second = UsageTrendStore(store: defaults, now: { rewound.now })

        XCTAssertTrue(second.samples(for: "claude").isEmpty)
        XCTAssertNil(defaults.object(forKey: prefix + "claude"))
    }

    @MainActor
    func testUnreadableStoredRingsAreDiscardedRatherThanCrashing() throws {
        let clock = TrendClock(start)
        let defaults = try scratchDefaults()

        let broken: [String: Any] = [
            "claude": Data("{ not json at all".utf8),
            "gemini": Data(),
            "grok": Data(#"{"samples":"nope"}"#.utf8),
            "cursor": Data(#"{"resetAt":123}"#.utf8),
            // An older shape wrote the array on its own, with no wrapper.
            "mistral": Data("[]".utf8),
            // Not even data: something else wrote under our prefix.
            "deepseek": "a string"
        ]
        for (id, value) in broken { defaults.set(value, forKey: prefix + id) }
        // The prefix with nothing after it names no provider.
        defaults.set(Data(#"{"samples":[],"resetAt":null}"#.utf8), forKey: prefix)

        let store = UsageTrendStore(store: defaults, now: { clock.now })

        for id in broken.keys {
            XCTAssertTrue(store.samples(for: id).isEmpty, "\(id) came back from an unreadable blob")
            XCTAssertNil(defaults.object(forKey: prefix + id), "\(id) would fail to read at every launch from now on")
        }
        XCTAssertNil(defaults.object(forKey: prefix))
        XCTAssertTrue(store.projections.isEmpty)

        // And the store still works afterwards.
        fill(store, id: "claude", clock: clock)
        XCTAssertEqual(store.samples(for: "claude").count, 3)
    }

    /// Percentages come off disk untrusted, like anything else in a file.
    @MainActor
    func testStoredPercentagesAreClampedOnTheWayBackIn() throws {
        let clock = TrendClock(start)
        let defaults = try scratchDefaults()
        let stamp = start.timeIntervalSinceReferenceDate

        let json = """
        {"samples":[{"at":\(stamp - 360),"percent":-2},\
        {"at":\(stamp - 180),"percent":4},\
        {"at":\(stamp),"percent":0.5}],"resetAt":null}
        """
        defaults.set(Data(json.utf8), forKey: prefix + "claude")

        let store = UsageTrendStore(store: defaults, now: { clock.now })
        XCTAssertEqual(store.samples(for: "claude").map(\.percent), [0, 1, 0.5])
    }

    // MARK: - The one setting

    @MainActor
    func testThePaceLineIsOnUntilSomebodyTurnsItOff() throws {
        let defaults = try scratchDefaults()
        let key = "aibars.forecast.showsPace"

        let first = UsageTrendStore(store: defaults)
        XCTAssertTrue(first.showsPaceInPanel, "a key nobody has written should not ship the pace line switched off")

        first.showsPaceInPanel = false
        XCTAssertEqual(defaults.object(forKey: key) as? Bool, false)
        XCTAssertFalse(UsageTrendStore(store: defaults).showsPaceInPanel)

        first.showsPaceInPanel = true
        XCTAssertTrue(UsageTrendStore(store: defaults).showsPaceInPanel)
    }
}
