import XCTest
@testable import aibarsCore

/// Threshold alerts are the only thing in aibars that interrupts, so the tests
/// are mostly about the readings that must stay silent: the first sight of a
/// provider already over the line, the figure that wobbles a point either side
/// of a level, the same reading polled again five minutes later. A menu bar app
/// that cries wolf is one people mute, and a muted app never delivers the alert
/// that would have helped.
///
/// Everything here goes through `evaluate`, which is pure, so the clock is a
/// parameter and there is nothing to stub.
final class ThresholdPolicyTests: XCTestCase {
    /// Fixed so the countdowns in the copy are exact, and so the encoded dates
    /// in the round trip are values a Double represents without rounding.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Harness

    /// A caller that hangs on to the state between readings, which is the only
    /// way the policy is ever used.
    private struct Watcher {
        var rules: ThresholdRules
        var providerID = "claude"
        var displayName = "claude"
        var state = ThresholdState()

        mutating func poll(_ data: UsageData, at now: Date) -> [PendingAlert] {
            let result = ThresholdPolicy.evaluate(
                data,
                providerID: providerID,
                displayName: displayName,
                rules: rules,
                state: state,
                now: now
            )
            state = result.state
            return result.alerts
        }
    }

    private func rules(
        levels: [Double] = [0.80, 0.95],
        coversSecondaryWindows: Bool = true,
        announcesReset: Bool = false,
        cooldown: TimeInterval = 0
    ) -> ThresholdRules {
        // Enabled and with no cooldown unless a test is about one of those two,
        // so that a suppressed alert is always the hysteresis talking.
        ThresholdRules(
            isEnabled: true,
            levels: levels,
            coversSecondaryWindows: coversSecondaryWindows,
            announcesReset: announcesReset,
            cooldown: cooldown
        )
    }

    private func metric(
        _ percent: Double,
        label: String = "5h window",
        resetIn: TimeInterval? = nil
    ) -> UsageMetric {
        UsageMetric(
            label: label,
            used: percent,
            limit: 100,
            unit: "%",
            resetDate: resetIn.map { now.addingTimeInterval($0) }
        )
    }

    private func usage(
        _ percent: Double,
        label: String = "5h window",
        resetIn: TimeInterval? = nil,
        secondary: [UsageMetric] = []
    ) -> UsageData {
        UsageData(
            providerID: "claude",
            primary: metric(percent, label: label, resetIn: resetIn),
            secondary: secondary
        )
    }

    // MARK: - First sight

    func testFirstObservationSeedsWithoutFiring() {
        var watcher = Watcher(rules: rules())
        XCTAssertEqual(watcher.poll(usage(92), at: now), [], "installing at 92% is not a crossing aibars watched")
        XCTAssertFalse(watcher.state.isEmpty, "the reading still has to be remembered, or the next poll fires it")
        XCTAssertEqual(watcher.poll(usage(92), at: now.addingTimeInterval(300)), [],
                       "a level seeded as already reported must stay quiet")
    }

    func testCrossingAfterSeedingFiresOnceForThatLevel() {
        var watcher = Watcher(rules: rules())
        XCTAssertEqual(watcher.poll(usage(72), at: now), [])

        let alerts = watcher.poll(usage(81, resetIn: 3600), at: now.addingTimeInterval(300))
        XCTAssertEqual(alerts.count, 1)
        let alert = alerts.first
        XCTAssertEqual(alert?.providerID, "claude")
        XCTAssertEqual(alert?.key, "threshold.claude.5h window")
        XCTAssertEqual(alert?.title, "claude at 81%")
        XCTAssertEqual(alert?.body, "5h window, resets in 55m", "the body names the window and when it clears")
        XCTAssertEqual(alert?.at, now.addingTimeInterval(300))
    }

    func testARepeatedReadingAboveTheLevelSaysNothingFurther() {
        var watcher = Watcher(rules: rules())
        _ = watcher.poll(usage(72), at: now)
        XCTAssertEqual(watcher.poll(usage(81), at: now.addingTimeInterval(60)).count, 1)

        for poll in 1...5 {
            let alerts = watcher.poll(usage(82), at: now.addingTimeInterval(TimeInterval(60 * (poll + 1))))
            XCTAssertEqual(alerts, [], "poll \(poll) parked at 82% re-announced a level that never fell back")
        }
    }

    // MARK: - Hysteresis

    func testADipInsideTheBandDoesNotRearmTheLevel() {
        var watcher = Watcher(rules: rules())
        _ = watcher.poll(usage(72), at: now)
        XCTAssertEqual(watcher.poll(usage(82), at: now.addingTimeInterval(60)).count, 1)

        XCTAssertEqual(watcher.poll(usage(78), at: now.addingTimeInterval(120)), [])
        XCTAssertEqual(watcher.poll(usage(81), at: now.addingTimeInterval(180)), [],
                       "78% is inside the five point band, so 81% is the same crossing wobbling")
    }

    func testFallingClearOfTheBandRearmsTheLevel() {
        var watcher = Watcher(rules: rules())
        _ = watcher.poll(usage(72), at: now)
        XCTAssertEqual(watcher.poll(usage(82), at: now.addingTimeInterval(60)).count, 1)

        XCTAssertEqual(watcher.poll(usage(73), at: now.addingTimeInterval(120)), [])
        XCTAssertEqual(watcher.poll(usage(81), at: now.addingTimeInterval(180)).count, 1,
                       "73% is a genuine reset of the window, so the next crossing is genuine too")
    }

    /// The band is exclusive at its floor: a reading of exactly the rearm point
    /// counts as having fallen back, one basis point above it does not.
    func testTheEdgesOfTheHysteresisBand() {
        var onTheLine = Watcher(rules: rules(levels: [0.80]))
        _ = onTheLine.poll(usage(50), at: now)
        XCTAssertEqual(onTheLine.poll(usage(85), at: now.addingTimeInterval(60)).count, 1)
        XCTAssertEqual(onTheLine.poll(usage(75), at: now.addingTimeInterval(120)), [])
        XCTAssertEqual(onTheLine.poll(usage(85), at: now.addingTimeInterval(180)).count, 1)

        var justInside = Watcher(rules: rules(levels: [0.80]))
        _ = justInside.poll(usage(50), at: now)
        XCTAssertEqual(justInside.poll(usage(85), at: now.addingTimeInterval(60)).count, 1)
        XCTAssertEqual(justInside.poll(usage(75.01), at: now.addingTimeInterval(120)), [])
        XCTAssertEqual(justInside.poll(usage(85), at: now.addingTimeInterval(180)), [],
                       "a hundredth of a point short of the rearm point is still armed")
    }

    /// A level fires at exactly its own fraction, and not a hundredth of a point
    /// below it. One level at a time, so the answer is about that level.
    func testTheEdgesOfEveryLevel() {
        for level in [0.50, 0.80, 0.95, 1.0] {
            let percent = level * 100

            var below = Watcher(rules: rules(levels: [level]))
            _ = below.poll(usage(0), at: now)
            XCTAssertEqual(below.poll(usage(percent - 0.01), at: now.addingTimeInterval(60)), [],
                           "\(percent - 0.01)% crossed the \(percent)% level")

            var on = Watcher(rules: rules(levels: [level]))
            _ = on.poll(usage(0), at: now)
            XCTAssertEqual(on.poll(usage(percent), at: now.addingTimeInterval(60)).count, 1,
                           "\(percent)% did not cross its own level")
        }
    }

    // MARK: - Escalation

    func testASecondLevelIsItsOwnAlertOnTheSameWindow() {
        var watcher = Watcher(rules: rules())
        _ = watcher.poll(usage(40), at: now)

        let first = watcher.poll(usage(81), at: now.addingTimeInterval(60))
        let second = watcher.poll(usage(96), at: now.addingTimeInterval(120))
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(second.count, 1)
        XCTAssertEqual(first.first?.title, "claude at 81%")
        XCTAssertEqual(second.first?.title, "claude at 96%")
        // Same window, so deliberately the same key: the 95% banner replaces the
        // 80% one still sitting in Notification Centre rather than stacking.
        XCTAssertEqual(first.first?.key, second.first?.key)
    }

    /// Two windows are two arming states, and two identifiers, so neither
    /// replaces the other in Notification Centre.
    func testTwoWindowsCrossingTogetherAreTwoAlertsWithDistinctKeys() {
        var watcher = Watcher(rules: rules())
        _ = watcher.poll(usage(40, secondary: [metric(40, label: "weekly")]), at: now)

        let alerts = watcher.poll(
            usage(85, secondary: [metric(85, label: "weekly")]),
            at: now.addingTimeInterval(60)
        )
        XCTAssertEqual(alerts.count, 2)
        XCTAssertEqual(Set(alerts.map(\.key)).count, 2)
        XCTAssertEqual(alerts.first?.key, "threshold.claude.5h window", "the window the menu bar shows comes first")
        XCTAssertEqual(alerts.last?.key, "threshold.claude.weekly")
    }

    func testAnEscalationBeatsTheCooldown() {
        var watcher = Watcher(rules: rules(cooldown: 1800))
        _ = watcher.poll(usage(40), at: now)
        XCTAssertEqual(watcher.poll(usage(81), at: now).count, 1)

        XCTAssertEqual(watcher.poll(usage(96), at: now.addingTimeInterval(60)).count, 1,
                       "a burn fast enough to clear both levels in a minute is exactly what the user asked about")
    }

    func testAnEscalationInAFreshWindowBeatsThePreviousWindowsCooldown() {
        var watcher = Watcher(rules: rules(levels: [0.80, 0.95], cooldown: 1800))
        _ = watcher.poll(usage(40), at: now)
        XCTAssertEqual(watcher.poll(usage(85), at: now).count, 1)

        // The window rolls over, which disarms every level.
        XCTAssertEqual(watcher.poll(usage(10), at: now.addingTimeInterval(1200)), [])

        // Then the fresh window is burned straight past both levels, still
        // inside the cooldown started by the *previous* window's 80%.
        XCTAssertEqual(watcher.poll(usage(96), at: now.addingTimeInterval(1500)).count, 1,
                       "a new window reaching 95% is news, whatever the old window said 25 minutes ago")
    }

    // MARK: - Cooldown

    func testASecondCrossingInsideTheCooldownIsSuppressed() {
        var watcher = Watcher(rules: rules(levels: [0.80], cooldown: 1800))
        _ = watcher.poll(usage(40), at: now)
        XCTAssertEqual(watcher.poll(usage(85), at: now).count, 1)

        // Fall clear of the band and cross again a minute later.
        XCTAssertEqual(watcher.poll(usage(40), at: now.addingTimeInterval(30)), [])
        XCTAssertEqual(watcher.poll(usage(85), at: now.addingTimeInterval(60)), [],
                       "the same level twice inside half an hour is repetition, not news")

        // And once the cooldown has run out, the same sequence is allowed.
        XCTAssertEqual(watcher.poll(usage(40), at: now.addingTimeInterval(3500)), [])
        XCTAssertEqual(watcher.poll(usage(85), at: now.addingTimeInterval(3600)).count, 1)
    }

    func testANegativeCooldownIsTreatedAsNone() {
        var watcher = Watcher(rules: rules(levels: [0.80], cooldown: -600))
        _ = watcher.poll(usage(40), at: now)
        XCTAssertEqual(watcher.poll(usage(85), at: now).count, 1)
        XCTAssertEqual(watcher.poll(usage(40), at: now), [])
        XCTAssertEqual(watcher.poll(usage(85), at: now).count, 1)
    }

    // MARK: - Secondary windows

    func testSecondaryWindowsAreIgnoredWhenTheUserOnlyWantsThePrimary() {
        var watcher = Watcher(rules: rules(coversSecondaryWindows: false))
        _ = watcher.poll(usage(40, secondary: [metric(40, label: "weekly")]), at: now)

        let alerts = watcher.poll(
            usage(85, secondary: [metric(96, label: "weekly")]),
            at: now.addingTimeInterval(60)
        )
        XCTAssertEqual(alerts.count, 1, "the weekly cap crossed too, and was not asked about")
        XCTAssertEqual(alerts.first?.key, "threshold.claude.5h window")
    }

    /// A window that stops being reported gives up its arming, so if it comes
    /// back it comes back as a first observation rather than as a crossing.
    func testAWindowThatDisappearsIsSeededAgainWhenItReturns() {
        var watcher = Watcher(rules: rules())
        _ = watcher.poll(usage(40, secondary: [metric(40, label: "weekly")]), at: now)
        XCTAssertEqual(watcher.poll(usage(40), at: now.addingTimeInterval(60)), [])

        XCTAssertEqual(
            watcher.poll(usage(40, secondary: [metric(96, label: "weekly")]), at: now.addingTimeInterval(120)),
            [],
            "the weekly window was not being watched while it was absent"
        )
    }

    func testTwoWindowsWithTheSameLabelAreOneWindow() {
        var watcher = Watcher(rules: rules())
        let doubled = [metric(96, label: "5h window"), metric(96, label: "weekly")]
        _ = watcher.poll(usage(40, secondary: [metric(40, label: "5h window"), metric(40, label: "weekly")]), at: now)

        let alerts = watcher.poll(usage(96, secondary: doubled), at: now.addingTimeInterval(60))
        XCTAssertEqual(alerts.count, 2, "the duplicated label collapsed into the primary, so two windows crossed")
        XCTAssertEqual(Set(alerts.map(\.key)).count, 2)
    }

    // MARK: - Switched off

    func testDisabledRulesFireNothingAndForgetWhatTheySaw() {
        var watcher = Watcher(rules: rules())
        _ = watcher.poll(usage(40), at: now)
        XCTAssertFalse(watcher.state.isEmpty)

        watcher.rules.isEnabled = false
        XCTAssertEqual(watcher.poll(usage(96), at: now.addingTimeInterval(60)), [])
        XCTAssertTrue(watcher.state.isEmpty,
                      "nothing is watching, so nothing is remembered — otherwise switching back on announces a crossing nobody saw")

        watcher.rules.isEnabled = true
        XCTAssertEqual(watcher.poll(usage(96), at: now.addingTimeInterval(120)), [],
                       "the first reading after switching back on is a first observation")
    }

    func testNoUsableLevelsMeansNoAlerts() {
        for levels in [[], [0], [-0.5, 1.5], [Double.nan, .infinity]] as [[Double]] {
            var watcher = Watcher(rules: rules(levels: levels))
            _ = watcher.poll(usage(40), at: now)
            XCTAssertEqual(watcher.poll(usage(99), at: now.addingTimeInterval(60)), [],
                           "\(levels) is not a level anything can cross")
            XCTAssertTrue(watcher.state.isEmpty)
        }
    }

    /// Nonsense levels drop out and the usable ones still work, rather than the
    /// whole setting being thrown away.
    func testUnusableLevelsAreFilteredOutOfAUsableSet() {
        var watcher = Watcher(rules: rules(levels: [0.80, -1, 2, .nan, 0.80]))
        _ = watcher.poll(usage(40), at: now)
        XCTAssertEqual(watcher.poll(usage(85), at: now.addingTimeInterval(60)).count, 1)
    }

    func testRemovingALevelDoesNotCountAsAWindowResetting() {
        var watcher = Watcher(rules: rules())
        _ = watcher.poll(usage(40), at: now)
        XCTAssertEqual(watcher.poll(usage(96), at: now.addingTimeInterval(60)).count, 1)

        watcher.rules.levels = [0.80]
        XCTAssertEqual(watcher.poll(usage(96), at: now.addingTimeInterval(120)), [],
                       "dropping the 95% level must not rearm the 80% one")
    }

    // MARK: - Resets

    func testAResetIsAnnouncedOnceWhenAskedFor() {
        var watcher = Watcher(rules: rules(announcesReset: true))
        _ = watcher.poll(usage(40), at: now)
        XCTAssertEqual(watcher.poll(usage(96), at: now.addingTimeInterval(60)).count, 1)

        let reset = watcher.poll(usage(10), at: now.addingTimeInterval(120))
        XCTAssertEqual(reset.count, 1)
        XCTAssertEqual(reset.first?.title, "claude reset")
        XCTAssertEqual(reset.first?.body, "5h window is back to 10%")
        XCTAssertEqual(watcher.poll(usage(10), at: now.addingTimeInterval(180)), [],
                       "the window can only come back down once per arming")
    }

    func testResetsAreSilentByDefault() {
        var watcher = Watcher(rules: rules())
        _ = watcher.poll(usage(40), at: now)
        XCTAssertEqual(watcher.poll(usage(96), at: now.addingTimeInterval(60)).count, 1)
        XCTAssertEqual(watcher.poll(usage(10), at: now.addingTimeInterval(120)), [],
                       "\"you can use it again\" is news to almost nobody")
    }

    /// The reset is not stamped as a fire, so the crossing 600 seconds after it
    /// still arrives even though the cooldown is half an hour.
    func testAResetDoesNotMuteTheNextCrossing() {
        var watcher = Watcher(rules: rules(levels: [0.80], announcesReset: true, cooldown: 1800))
        _ = watcher.poll(usage(40), at: now)
        XCTAssertEqual(watcher.poll(usage(85), at: now).count, 1)
        XCTAssertEqual(watcher.poll(usage(10), at: now.addingTimeInterval(2000)).count, 1, "the reset line")
        XCTAssertEqual(watcher.poll(usage(85), at: now.addingTimeInterval(2600)).count, 1)
    }

    // MARK: - Forgetting

    func testForgetDropsOnlyOneProvidersKeys() {
        var claude = Watcher(rules: rules(), providerID: "claude")
        var second = Watcher(rules: rules(), providerID: "claude#2")
        _ = claude.poll(usage(40), at: now)
        second.state = claude.state
        _ = second.poll(usage(40), at: now)

        // Both accounts are seeded in the one state the app persists.
        var shared = second.state
        shared = ThresholdPolicy.forget("claude", in: shared)
        claude.state = shared
        second.state = shared

        XCTAssertEqual(claude.poll(usage(85), at: now.addingTimeInterval(60)), [],
                       "the signed out account seeds afresh instead of firing against a previous session")
        XCTAssertEqual(second.poll(usage(85), at: now.addingTimeInterval(60)).count, 1,
                       "the account nobody signed out kept its arming")
    }

    func testForgettingSomethingUnknownChangesNothing() {
        var watcher = Watcher(rules: rules())
        _ = watcher.poll(usage(40), at: now)
        XCTAssertEqual(ThresholdPolicy.forget("grok", in: watcher.state), watcher.state)
        XCTAssertEqual(ThresholdPolicy.forget("claude", in: ThresholdState()), ThresholdState())
    }

    // MARK: - Readings that are not numbers

    func testMetricsWithNothingToCrossAreSkipped() {
        let unusable = [
            UsageMetric(label: "no cap", used: 90, limit: 0, unit: nil),
            UsageMetric(label: "negative cap", used: 90, limit: -100, unit: nil),
            UsageMetric(label: "infinite cap", used: 90, limit: .infinity, unit: nil),
            UsageMetric(label: "nan used", used: .nan, limit: 100, unit: "%"),
            UsageMetric(label: "infinite used", used: .infinity, limit: 100, unit: "%")
        ]
        for primary in unusable {
            var watcher = Watcher(rules: rules())
            let data = UsageData(providerID: "claude", primary: primary)
            XCTAssertEqual(watcher.poll(data, at: now), [], "\(primary.label) has nothing to cross")
            XCTAssertEqual(watcher.poll(data, at: now.addingTimeInterval(60)), [])
            XCTAssertTrue(watcher.state.isEmpty, "\(primary.label) should not be remembered at all")
        }
    }

    func testZeroAndNegativeUsageReadAsEmpty() {
        var watcher = Watcher(rules: rules(announcesReset: true))
        XCTAssertEqual(watcher.poll(usage(0), at: now), [])
        XCTAssertEqual(watcher.poll(usage(96), at: now.addingTimeInterval(60)).count, 1)

        // A provider that reports a negative figure is at zero, not below it.
        let reset = watcher.poll(usage(-5), at: now.addingTimeInterval(120))
        XCTAssertEqual(reset.first?.body, "5h window is back to 0%")
    }

    func testUsageOverTheCapIsStillJustFull() {
        var watcher = Watcher(rules: rules())
        _ = watcher.poll(usage(40), at: now)
        let alerts = watcher.poll(usage(150), at: now.addingTimeInterval(60))
        XCTAssertEqual(alerts.count, 1)
        XCTAssertEqual(alerts.first?.title, "claude at 100%", "a provider counting past its own cap is not 150%")
    }

    func testAnEmptyLabelStillIdentifiesAWindow() {
        var watcher = Watcher(rules: rules())
        _ = watcher.poll(usage(40, label: ""), at: now)
        let alerts = watcher.poll(usage(85, label: ""), at: now.addingTimeInterval(60))
        XCTAssertEqual(alerts.first?.key, "threshold.claude.")
    }

    // MARK: - Copy

    func testTheCopyIsPlainAndSaysWhatItNeedsTo() {
        var watcher = Watcher(rules: rules(levels: [0.80], announcesReset: true))
        func counted(_ used: Double) -> UsageData {
            UsageData(providerID: "claude", primary: UsageMetric(
                label: "5-hour messages",
                used: used,
                limit: 1000,
                unit: "messages",
                resetDate: now.addingTimeInterval(3 * 3600 + 12 * 60)
            ))
        }
        _ = watcher.poll(counted(400), at: now)
        let alerts = watcher.poll(counted(820), at: now)

        let alert = alerts.first
        XCTAssertEqual(alert?.title, "claude at 82%")
        XCTAssertEqual(alert?.body, "5-hour messages: 820 of 1.0k messages, resets in 3h 12m")
        for text in [alert?.title ?? "", alert?.body ?? ""] {
            XCTAssertEqual(text, text.lowercased(), "\(text) is shouting")
            XCTAssertFalse(text.contains("!"), "\(text) has an exclamation mark in it")
            XCTAssertTrue(text.allSatisfy(\.isASCII), "\(text) has picked up an emoji or a decorative character")
        }
        XCTAssertTrue(alert?.title.contains("claude") == true, "the alert has to say which service")
        XCTAssertTrue(alert?.body.contains("5-hour messages") == true, "and which window")
    }

    /// A window already expressed as a percentage has no counts worth printing,
    /// and a window with no reset date has no countdown to promise.
    func testTheBodyDropsWhatWouldRepeatTheTitle() {
        var watcher = Watcher(rules: rules(levels: [0.80]))
        _ = watcher.poll(usage(40, label: "weekly"), at: now)
        XCTAssertEqual(
            watcher.poll(usage(85, label: "weekly"), at: now).first?.body,
            "weekly"
        )

        var elapsed = Watcher(rules: rules(levels: [0.80]))
        _ = elapsed.poll(usage(40, resetIn: -60), at: now)
        XCTAssertEqual(
            elapsed.poll(usage(85, resetIn: -60), at: now).first?.body,
            "5h window",
            "a reset that is already due is not a countdown"
        )
    }

    // MARK: - State

    func testStateRoundTripsThroughJSON() throws {
        var watcher = Watcher(rules: rules(cooldown: 1800))
        _ = watcher.poll(usage(40, secondary: [metric(40, label: "weekly")]), at: now)
        XCTAssertEqual(watcher.poll(usage(85, secondary: [metric(96, label: "weekly")]), at: now).count, 2)

        let data = try JSONEncoder().encode(watcher.state)
        let restored = try JSONDecoder().decode(ThresholdState.self, from: data)
        XCTAssertEqual(restored, watcher.state)

        // And it has to behave the same after a relaunch, not merely compare
        // equal: the arming and the last fire are what the silence rests on.
        var reloaded = Watcher(rules: watcher.rules)
        reloaded.state = restored
        XCTAssertEqual(reloaded.poll(usage(85, secondary: [metric(96, label: "weekly")]),
                                     at: now.addingTimeInterval(60)), [])
    }

    func testAnEmptyStateRoundTrips() throws {
        let data = try JSONEncoder().encode(ThresholdState())
        let restored = try JSONDecoder().decode(ThresholdState.self, from: data)
        XCTAssertEqual(restored, ThresholdState())
        XCTAssertTrue(restored.isEmpty)
    }

    /// Same reading, same rules, same state, same answer — the caller is free to
    /// evaluate twice without the second call meaning anything different.
    func testEvaluateIsPure() {
        let seeded = ThresholdPolicy.evaluate(
            usage(40), providerID: "claude", displayName: "claude",
            rules: rules(), state: ThresholdState(), now: now
        ).state

        let first = ThresholdPolicy.evaluate(
            usage(85), providerID: "claude", displayName: "claude",
            rules: rules(), state: seeded, now: now
        )
        let second = ThresholdPolicy.evaluate(
            usage(85), providerID: "claude", displayName: "claude",
            rules: rules(), state: seeded, now: now
        )
        XCTAssertEqual(first.alerts, second.alerts)
        XCTAssertEqual(first.state, second.state)
    }

    // MARK: - Rules

    func testRulesDecodeFieldByFieldSoAMissingKeyKeepsTheDefault() throws {
        let json = Data(#"{"isEnabled":true,"cooldown":60}"#.utf8)
        let decoded = try JSONDecoder().decode(ThresholdRules.self, from: json)
        XCTAssertTrue(decoded.isEnabled)
        XCTAssertEqual(decoded.cooldown, 60)
        XCTAssertEqual(decoded.levels, ThresholdRules.default.levels, "a rule added later must not reset the rest")
        XCTAssertEqual(decoded.coversSecondaryWindows, ThresholdRules.default.coversSecondaryWindows)
        XCTAssertEqual(decoded.announcesReset, ThresholdRules.default.announcesReset)
    }

    func testRulesRoundTripAndStartSwitchedOff() throws {
        XCTAssertFalse(ThresholdRules.default.isEnabled, "aibars does not start notifying on the day it is installed")
        let encoded = try JSONEncoder().encode(ThresholdRules.default)
        XCTAssertEqual(try JSONDecoder().decode(ThresholdRules.self, from: encoded), ThresholdRules.default)
    }
}
