import XCTest
@testable import aibarsCore

/// AlertCenter is the one place in the app allowed to touch UserNotifications,
/// and touching it from a test bundle raises an Objective-C exception Swift
/// cannot catch — it would take the whole suite down rather than fail a test.
/// So the first case here is the one that keeps every other case alive: under
/// xctest the class has to decide, on its own, that it is not hosted in an app.
///
/// Everything after that exercises the half of the class that still has to work
/// when nothing can be delivered — the policy, the persisted state, and the
/// in-app log that is the only surface an un-notarised build reliably has.
final class AlertCenterTests: XCTestCase {
    // MARK: - Environment

    @MainActor
    func testTheTestBundleIsNotHostedInAnApp() {
        // Read before asserting: the property is main-actor isolated and an
        // autoclosure argument is not.
        let hosted = AlertCenter.isHostedInApp
        XCTAssertFalse(
            hosted,
            "the test bundle looks like an app to AlertCenter, so it will call "
                + "UNUserNotificationCenter.current() and abort the whole suite"
        )
    }

    @MainActor
    func testANewCentreIsSilentAndUnavailable() throws {
        let center = AlertCenter(store: try scratchStore())
        XCTAssertEqual(center.permission, .unavailable)
        XCTAssertTrue(center.recent.isEmpty)
        XCTAssertFalse(center.rules.isEnabled, "alerts must stay off until the user asks for them")
        XCTAssertEqual(center.rules, .default)
    }

    /// Both failure states have to say something, because both of them end with
    /// the user waiting for a banner that is never coming.
    func testOnlyTheFailureStatesExplainThemselves() {
        XCTAssertNil(AlertPermission.unknown.explanation)
        XCTAssertNil(AlertPermission.granted.explanation)
        XCTAssertNotNil(AlertPermission.denied.explanation)
        XCTAssertNotNil(AlertPermission.unavailable.explanation)
    }

    // MARK: - Priming

    @MainActor
    func testPrimingWithAlertsOffAsksNothing() async throws {
        let store = try scratchStore()
        let center = makeCenter(store, enabled: false)

        await center.primeIfNeeded()

        XCTAssertEqual(center.permission, .unavailable)
        XCTAssertFalse(
            store.bool(forKey: Self.didAskKey),
            "the authorisation prompt was raised for a user who has alerts switched off"
        )
    }

    /// With alerts on but no `.app` around us the answer is known without asking,
    /// and the one-shot prompt must stay unspent for the day it can be shown.
    @MainActor
    func testPrimingWithoutAnAppBundleDoesNotSpendThePrompt() async throws {
        let store = try scratchStore()
        let center = makeCenter(store)

        await center.primeIfNeeded()

        XCTAssertEqual(center.permission, .unavailable)
        XCTAssertFalse(store.bool(forKey: Self.didAskKey))
    }

    // MARK: - Storage

    @MainActor
    func testRulesRoundTripThroughTheStore() throws {
        let store = try scratchStore()
        let written = ThresholdRules(
            isEnabled: true,
            levels: [0.5, 0.9],
            coversSecondaryWindows: false,
            announcesReset: true,
            cooldown: 60
        )

        let first = AlertCenter(store: store, now: { Self.clock })
        first.rules = written

        let second = AlertCenter(store: store, now: { Self.clock })
        XCTAssertEqual(second.rules, written, "the pane's choices did not survive a relaunch")
    }

    /// A blob that no longer decodes has to fall back to the shipped defaults,
    /// which are off. The alternative is a launch that crashes on a file written
    /// by an older build.
    @MainActor
    func testUnreadableStoredRulesFallBackToTheDefaults() throws {
        let store = try scratchStore()
        store.set(Data("not json".utf8), forKey: Self.rulesKey)
        store.set(Data("not json either".utf8), forKey: Self.stateKey)

        let center = AlertCenter(store: store, now: { Self.clock })
        XCTAssertEqual(center.rules, .default)
        XCTAssertTrue(center.recent.isEmpty)
    }

    /// The arming has to outlive the process, or every window fires again on the
    /// first poll after a restart.
    @MainActor
    func testArmingSurvivesAFreshInstance() async throws {
        let store = try scratchStore()
        let first = makeCenter(store)
        await feed([10, 85], into: first)
        XCTAssertEqual(first.recent.count, 1)

        let second = AlertCenter(store: store, now: { Self.clock })
        await feed([85], into: second)
        XCTAssertTrue(second.recent.isEmpty, "a relaunch replayed a level that was already armed")

        // Still live, though: an escalation past the next level must get through.
        await feed([97], into: second)
        XCTAssertEqual(second.recent.count, 1)
    }

    // MARK: - Crossings

    @MainActor
    func testARisingSeriesIsLoggedAndPermissionStaysUnavailable() async throws {
        let center = makeCenter(try scratchStore())

        await feed([5, 40, 82, 91, 97], into: center)

        XCTAssertEqual(center.permission, .unavailable)
        XCTAssertEqual(
            center.recent.map(\.title), ["Claude at 97%", "Claude at 82%"],
            "the log should hold one row per level crossed, newest first"
        )
        for alert in center.recent {
            XCTAssertFalse(center.wasDelivered(alert), "nothing can be delivered from a test bundle")
        }
    }

    /// Either side of both shipped levels. The second crossing landing at the
    /// same instant as the first is deliberate: an escalation is meant to beat
    /// the cooldown, and this is the case that proves it.
    @MainActor
    func testEachLevelFiresOnItsBoundaryAndNotBelowIt() async throws {
        let center = makeCenter(try scratchStore())

        await feed([10, 79.9, 80, 94.9, 95, 100], into: center)

        XCTAssertEqual(center.recent.map(\.title), ["Claude at 95%", "Claude at 80%"])
    }

    /// A level of exactly 1 is legal and must behave like any other, including
    /// staying quiet a tenth of a point below itself.
    @MainActor
    func testTheTopOfTheScaleIsALevelLikeAnyOther() async throws {
        let center = makeCenter(try scratchStore(), levels: [1.0])

        await feed([10, 99.9], into: center)
        XCTAssertTrue(center.recent.isEmpty, "99.9% is not the cap")

        await feed([100], into: center)
        XCTAssertEqual(center.recent.count, 1)
    }

    /// Nothing is ever announced on the strength of a reading aibars did not
    /// watch cross, so the first sight of a provider is always silent.
    @MainActor
    func testTheFirstReadingNeverFiresHoweverHighItIs() async throws {
        let center = makeCenter(try scratchStore())

        await feed([99], into: center)

        XCTAssertTrue(center.recent.isEmpty, "installing at 99% is not a crossing")
    }

    @MainActor
    func testSecondaryWindowsFollowTheRule() async throws {
        let weekly = UsageMetric(label: "Weekly", used: 88, limit: 100, unit: "%")
        let low = UsageMetric(label: "Weekly", used: 5, limit: 100, unit: "%")

        let covering = makeCenter(try scratchStore())
        await covering.consider(reading(5, secondary: [low]), providerID: "claude", displayName: "Claude")
        await covering.consider(reading(85, secondary: [weekly]), providerID: "claude", displayName: "Claude")
        XCTAssertEqual(covering.recent.count, 2, "the weekly cap should arm and fire on its own")

        let primaryOnly = makeCenter(try scratchStore(), coversSecondaryWindows: false)
        await primaryOnly.consider(reading(5, secondary: [low]), providerID: "claude", displayName: "Claude")
        await primaryOnly.consider(reading(85, secondary: [weekly]), providerID: "claude", displayName: "Claude")
        XCTAssertEqual(primaryOnly.recent.count, 1, "a window the user excluded still fired")
    }

    /// A provider that reports the same label twice has one window, not two, or
    /// the user gets the same sentence in two banners.
    @MainActor
    func testARepeatedLabelIsOneWindow() async throws {
        let center = makeCenter(try scratchStore())
        let twin = UsageMetric(label: "5h window", used: 85, limit: 100, unit: "%")

        await center.consider(reading(5, secondary: [twin]), providerID: "claude", displayName: "Claude")
        await center.consider(reading(85, secondary: [twin]), providerID: "claude", displayName: "Claude")

        XCTAssertEqual(center.recent.count, 1)
    }

    /// Falling back has to clear the hysteresis band before it counts, so a
    /// figure wobbling under a level does not read as a reset.
    @MainActor
    func testAResetIsAnnouncedOnlyOnceTheReadingFallsClearOfTheLevel() async throws {
        let announcing = makeCenter(try scratchStore(), announcesReset: true)
        await feed([10, 85, 75.1], into: announcing)
        XCTAssertEqual(announcing.recent.count, 1, "75.1% is still inside the band below 80%")

        await feed([75], into: announcing)
        XCTAssertEqual(announcing.recent.first?.title, "Claude reset")

        let quiet = makeCenter(try scratchStore())
        await feed([10, 85, 75], into: quiet)
        XCTAssertEqual(quiet.recent.count, 1, "the reset was announced without being asked for")
    }

    // MARK: - Switching the feature on and off

    /// Turning alerts off and on again is a settings change, not a window
    /// resetting, and the reading that was already armed must stay silent.
    @MainActor
    func testTurningRulesOffAndOnAgainDoesNotReplayAlerts() async throws {
        let center = makeCenter(try scratchStore())
        await feed([10, 85], into: center)
        XCTAssertEqual(center.recent.count, 1)

        center.rules.isEnabled = false
        await feed([85, 85], into: center)
        XCTAssertEqual(center.recent.count, 1, "a poll while switched off produced an alert")

        center.rules.isEnabled = true
        await feed([85, 85], into: center)
        XCTAssertEqual(center.recent.count, 1, "switching back on replayed a crossing nobody watched")

        // The machinery is still armed and running underneath: a genuine
        // escalation past the next level has to get through.
        await feed([96], into: center)
        XCTAssertEqual(center.recent.count, 2)
    }

    // MARK: - Degenerate input

    @MainActor
    func testDegenerateReadingsAreIgnored() async throws {
        let center = makeCenter(try scratchStore())
        let degenerate = [
            UsageMetric(label: "unused", used: 0, limit: 100),
            UsageMetric(label: "no cap", used: 90, limit: 0),
            UsageMetric(label: "negative cap", used: 90, limit: -100),
            UsageMetric(label: "negative use", used: -90, limit: 100),
            UsageMetric(label: "unmeasured use", used: .nan, limit: 100),
            UsageMetric(label: "unmeasured cap", used: 90, limit: .nan),
            UsageMetric(label: "endless use", used: .infinity, limit: 100),
            UsageMetric(label: "endless cap", used: 90, limit: .infinity),
        ]

        for metric in degenerate {
            let data = UsageData(providerID: "claude", primary: metric)
            // Twice, so anything that seeded on the first pass would have had
            // its chance to fire on the second.
            await center.consider(data, providerID: "claude", displayName: "Claude")
            await center.consider(data, providerID: "claude", displayName: "Claude")
        }

        XCTAssertTrue(
            center.recent.isEmpty,
            "a figure with no usable cap was treated as a crossing: \(center.recent.map(\.title))"
        )
    }

    /// Levels the user cannot have meant are dropped, and dropping all of them
    /// leaves the feature switched on and silent rather than firing on everything.
    @MainActor
    func testUnusableLevelsLeaveTheFeatureSilent() async throws {
        for levels in [[], [0, -0.5, 1.5, Double.nan, .infinity]] {
            let center = makeCenter(try scratchStore(), levels: levels)
            await feed([10, 50, 100, 100], into: center)
            XCTAssertTrue(center.recent.isEmpty, "levels \(levels) produced \(center.recent.count) alerts")
        }
    }

    @MainActor
    func testEmptyIdentifiersAreSurvivable() async throws {
        let center = makeCenter(try scratchStore())
        let seed = UsageData(providerID: "", primary: UsageMetric(label: "", used: 5, limit: 100))
        let high = UsageData(providerID: "", primary: UsageMetric(label: "", used: 85, limit: 100))

        await center.consider(seed, providerID: "", displayName: "")
        await center.consider(high, providerID: "", displayName: "")

        XCTAssertEqual(center.recent.count, 1)
        XCTAssertEqual(center.recent.first?.providerID, "")
    }

    // MARK: - The log

    @MainActor
    func testTheLogKeepsFiveRowsNewestFirst() async throws {
        let center = makeCenter(try scratchStore())

        for index in 0..<7 {
            let id = "claude#\(index)"
            await center.consider(reading(10), providerID: id, displayName: "Claude \(index)")
            await center.consider(reading(85), providerID: id, displayName: "Claude \(index)")
        }

        XCTAssertEqual(
            center.recent.map(\.providerID),
            ["claude#6", "claude#5", "claude#4", "claude#3", "claude#2"]
        )
    }

    // MARK: - Forgetting an account

    @MainActor
    func testForgettingAProviderClearsItsArmingAndItsLog() async throws {
        let center = makeCenter(try scratchStore())
        await feed([10, 85], into: center, providerID: "claude", displayName: "Claude")
        await feed([10, 85], into: center, providerID: "grok", displayName: "Grok")
        XCTAssertEqual(center.recent.count, 2)

        center.forget("claude")
        XCTAssertEqual(
            center.recent.map(\.providerID), ["grok"],
            "forget took the wrong rows out of the log"
        )

        // Signing back in: the same reading is a first observation again.
        await feed([85], into: center, providerID: "claude", displayName: "Claude")
        XCTAssertEqual(center.recent.map(\.providerID), ["grok"], "a re-signed-in account fired on its seed")

        // The account that was not forgotten keeps its arming.
        await feed([85], into: center, providerID: "grok", displayName: "Grok")
        XCTAssertEqual(center.recent.count, 1, "grok re-announced a level it was already armed on")
    }

    @MainActor
    func testForgettingAnUnknownProviderChangesNothing() async throws {
        let center = makeCenter(try scratchStore())
        await feed([10, 85], into: center)

        center.forget("mistral")

        XCTAssertEqual(center.recent.count, 1)
    }

    // MARK: - Helpers

    /// Mirrors of AlertCenter's private keys. Asserting that the one-shot
    /// authorisation prompt was never spent means reading the mark it leaves,
    /// and there is no other way in from outside the class.
    private static let rulesKey = "aibars.alerts.rules"
    private static let stateKey = "aibars.alerts.state"
    private static let didAskKey = "aibars.alerts.didAsk"

    /// Fixed, so that two crossings in one test share an instant and the
    /// cooldown is exercised at its hardest.
    private static let clock = Date(timeIntervalSinceReferenceDate: 700_000_000)

    /// A scratch domain per test: the centre writes its rules and its state on
    /// every change, and a shared domain would let one test arm another's
    /// windows — or leave arming behind in the developer's own defaults.
    private func scratchStore(_ label: String = #function) throws -> UserDefaults {
        let suite = "aibars.alerts.tests.\(label).\(UUID().uuidString)"
        let store = try XCTUnwrap(UserDefaults(suiteName: suite), "could not open a scratch suite")
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return store
    }

    @MainActor
    private func makeCenter(
        _ store: UserDefaults,
        enabled: Bool = true,
        levels: [Double] = [0.80, 0.95],
        coversSecondaryWindows: Bool = true,
        announcesReset: Bool = false
    ) -> AlertCenter {
        let center = AlertCenter(store: store, now: { Self.clock })
        center.rules = ThresholdRules(
            isEnabled: enabled,
            levels: levels,
            coversSecondaryWindows: coversSecondaryWindows,
            announcesReset: announcesReset
        )
        return center
    }

    private func reading(
        _ percent: Double,
        label: String = "5h window",
        secondary: [UsageMetric] = []
    ) -> UsageData {
        UsageData(
            providerID: "claude",
            planName: "Max",
            primary: UsageMetric(
                label: label,
                used: percent,
                limit: 100,
                unit: "%",
                resetDate: Self.clock.addingTimeInterval(3600)
            ),
            secondary: secondary
        )
    }

    @MainActor
    private func feed(
        _ series: [Double],
        into center: AlertCenter,
        providerID: String = "claude",
        displayName: String = "Claude"
    ) async {
        for percent in series {
            await center.consider(reading(percent), providerID: providerID, displayName: displayName)
        }
    }
}
