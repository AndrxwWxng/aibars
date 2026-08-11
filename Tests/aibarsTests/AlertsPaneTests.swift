import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// The Alerts pane is a Form of switches and steppers over an alert log, and
/// every value it shows is read out of a stored preference that is not obliged
/// to be sensible: `ThresholdRules.levels` is a plain array of Doubles that
/// survives a JSON round trip, a downgrade, and whatever an older build wrote.
///
/// So these count the AppKit controls SwiftUI actually instantiated rather than
/// look at pixels — the same measurement `AppearancePaneTests` makes, and for
/// the same reason: a Form nested in a hosting view snapshots blank in this
/// harness whether or not it built anything. Where a control count cannot see
/// the difference, because the part in question is one SwiftUI draws itself,
/// the height stands in for it.
///
/// Nothing here reaches `AlertCenter.shared`, `UsageTrendStore.shared` or
/// `LoginItem.shared`. All three persist to `UserDefaults.standard`, and a test
/// that writes through one of them edits the settings of whoever ran it.
final class AlertsPaneTests: XCTestCase {
    // MARK: - Harness

    @MainActor
    private func hosted<V: View>(_ view: V, height: CGFloat = 520) -> NSView {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: 660, height: height)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        // Long enough for the pane's `.task` to run: it settles the permission
        // line, which is part of what is being counted.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return host
    }

    private func controls(in view: NSView) -> [NSControl] {
        var found: [NSControl] = []
        if let control = view as? NSControl { found.append(control) }
        for subview in view.subviews { found.append(contentsOf: controls(in: subview)) }
        return found
    }

    /// A scratch domain, emptied first. `AlertCenter` decodes its rules in
    /// `init`, so a suite left behind by an earlier run would hand the next one
    /// somebody else's levels.
    private func scratch(_ name: String) throws -> UserDefaults {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @MainActor
    private func center(_ name: String, rules: ThresholdRules = .default) throws -> AlertCenter {
        let center = AlertCenter(store: try scratch(name), now: { Self.fixedNow })
        center.rules = rules
        return center
    }

    @MainActor
    private func trend(_ name: String) throws -> UsageTrendStore {
        UsageTrendStore(store: try scratch(name), now: { Self.fixedNow })
    }

    /// Fixed so the log rows' "3h 12m ago" is the same string on every run and
    /// on a machine whose clock is anywhere.
    private static let fixedNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private func reading(percent: Double, label: String = "5h window") -> UsageData {
        UsageData(
            providerID: "seed",
            fetchedAt: Self.fixedNow,
            planName: "Pro",
            primary: UsageMetric(label: label, used: percent * 100, limit: 100, unit: "%")
        )
    }

    /// Fills the log by driving the policy, because `AlertCenter.recent` is
    /// `private(set)` and there is no back door — which is the right shape for
    /// it and means the seeding has to obey the same rule the feature does:
    /// nothing fires on first sight, so every window is shown low once and then
    /// over the line.
    @MainActor
    private func seed(_ center: AlertCenter, crossings: Int) async {
        center.rules.isEnabled = true
        for index in 0..<crossings {
            let id = "seeded-\(index)"
            await center.consider(reading(percent: 0.10), providerID: id, displayName: "Service \(index)")
            await center.consider(reading(percent: 0.90), providerID: id, displayName: "Service \(index)")
        }
    }

    // MARK: - The pane builds

    @MainActor
    func testThePaneInstantiatesItsControls() async throws {
        let host = hosted(AlertsPane(
            center: try center("alerts-pane-controls"),
            trend: try trend("alerts-pane-controls-trend")
        ))
        let found = controls(in: host)
        XCTAssertGreaterThan(
            found.count, 6,
            "only \(found.count) controls — the four switches and two steppers are not being built"
        )
    }

    /// Short windows are the ordinary case for a settings sheet on a laptop.
    /// The Form has to scroll rather than collapse.
    @MainActor
    func testThePaneSurvivesAShortWindow() async throws {
        let host = hosted(
            AlertsPane(
                center: try center("alerts-pane-short"),
                trend: try trend("alerts-pane-short-trend")
            ),
            height: 300
        )
        XCTAssertGreaterThan(
            controls(in: host).count, 4,
            "the form collapsed in a 300pt window"
        )
    }

    // MARK: - Launch at login

    /// The section is a `Section`, so it is measured where it is used: inside
    /// somebody else's Form. Under xctest `LoginItem` is always `.unavailable`
    /// — there is no `.app` around the runner — which is exactly the state that
    /// has a note and a button to draw, so the unhappy path is the one this
    /// harness can actually see.
    ///
    /// Measured two ways because one is not enough. The toggle is the section's
    /// only AppKit control: SwiftUI draws `Button` itself on this OS, so a
    /// control count cannot tell a section with a note from one without, and
    /// counting alone would pass on a section that had lost its note entirely.
    /// The height can tell them apart — the note and the footer under it are
    /// several caption lines the bare switch does not have.
    @MainActor
    func testLaunchAtLoginSectionInstantiatesItsToggleAndItsNote() async throws {
        let item = LoginItem()
        XCTAssertFalse(LoginItem.isHostedInApp, "a test bundle must never look like a login item")
        XCTAssertNotNil(item.state.note, "the unavailable state must explain itself")
        XCTAssertFalse(item.state.isOn, "an unregistered login item must not read as on")

        // A width, because the strings have to be given somewhere to wrap: an
        // unconstrained Form lays the footer out on one 1150pt line and reports
        // the height of a single row.
        let section = hosted(Form { LaunchAtLoginSection(item: item) }.frame(width: 620))
        XCTAssertEqual(
            controls(in: section).count, 1,
            "the login toggle is not being built"
        )

        // The same switch on its own, as the floor. Nothing else in the section
        // is reachable from here, so the surplus is the evidence.
        let switchOnly = hosted(Form {
            Section { Toggle("Open aibars at login", isOn: .constant(false)) }
        }.frame(width: 620))

        XCTAssertGreaterThan(
            section.fittingSize.height,
            switchOnly.fittingSize.height + Tokens.Ramp.caption,
            "the section is \(section.fittingSize.height)pt against a bare switch's "
                + "\(switchOnly.fittingSize.height)pt — the note is not being drawn"
        )
    }

    /// Asking for it under xctest must change nothing but the note. If this
    /// ever registers, the test runner becomes the login item of whoever ran
    /// the suite and stays there after the run.
    @MainActor
    func testAskingToLaunchAtLoginFromATestBundleOnlyExplainsItself() async throws {
        let item = LoginItem()
        let state = item.setEnabled(true)
        XCTAssertFalse(state.isOn, "the switch must fall back to off when macOS will not register")
        XCTAssertNotNil(state.note, "a refusal with no reason is a switch that springs back silently")
    }

    // MARK: - Where the switch writes

    /// The pane binds to the center it was handed, not to the shared one, so a
    /// settings window built against a scratch store cannot reach into
    /// `UserDefaults.standard`. Read before and after rather than asserted nil:
    /// the machine running this may have the real app's preferences on it, and
    /// the invariant is that they do not move.
    @MainActor
    func testTheAlertsSwitchWritesThroughToTheInjectedCenter() async throws {
        let name = "alerts-pane-writes"
        let store = try scratch(name)
        let center = AlertCenter(store: store, now: { Self.fixedNow })
        let key = "aibars.alerts.rules"
        let standardBefore = UserDefaults.standard.data(forKey: key)

        _ = hosted(AlertsPane(center: center, trend: try trend("alerts-pane-writes-trend")))
        XCTAssertFalse(center.rules.isEnabled, "alerts must start off")

        center.rules.isEnabled = true

        let written = try XCTUnwrap(store.data(forKey: key), "the rules were not persisted to the injected store")
        let decoded = try JSONDecoder().decode(ThresholdRules.self, from: written)
        XCTAssertTrue(decoded.isEnabled, "the switch did not write through")
        XCTAssertEqual(
            UserDefaults.standard.data(forKey: key), standardBefore,
            "the pane wrote to UserDefaults.standard instead of the store it was given"
        )
    }

    /// Persisting is guarded on a real change, so a pane that redraws sixty
    /// times an hour must not keep rewriting the same value.
    @MainActor
    func testRenderingThePaneDoesNotRewriteTheRules() async throws {
        let name = "alerts-pane-idle"
        let store = try scratch(name)
        let center = AlertCenter(store: store, now: { Self.fixedNow })
        let key = "aibars.alerts.rules"

        _ = hosted(AlertsPane(center: center, trend: try trend("alerts-pane-idle-trend")))
        XCTAssertNil(
            store.data(forKey: key),
            "opening the pane persisted rules nobody changed"
        )
    }

    // MARK: - The log

    /// Alerts on, readings arriving, log still empty — which is the state the
    /// pane has to say something in rather than draw a blank section. The
    /// readings are the ones no threshold can be crossed in: no ceiling, a
    /// negative ceiling, and figures that are not numbers.
    @MainActor
    func testThePaneRendersAnEmptyLog() async throws {
        let center = try center("alerts-pane-log-empty")
        center.rules.isEnabled = true
        let unwatchable = [
            reading(percent: 0.90).mutating(limit: 0),
            reading(percent: 0.90).mutating(limit: -100),
            reading(percent: 0.90).mutating(limit: .nan),
            reading(percent: 0.90).mutating(limit: .infinity),
            reading(percent: 0.90).mutating(used: .nan, limit: 100)
        ]
        for (index, data) in unwatchable.enumerated() {
            await center.consider(data, providerID: "capless-\(index)", displayName: "Capless")
        }
        XCTAssertTrue(center.recent.isEmpty, "a window with no usable cap must not produce an alert")

        let host = hosted(AlertsPane(center: center, trend: try trend("alerts-pane-log-empty-trend")))
        XCTAssertGreaterThan(host.fittingSize.height, 0, "the empty log collapsed the pane")
        XCTAssertGreaterThan(controls(in: host).count, 4, "the empty log took the form with it")
    }

    @MainActor
    func testThePaneRendersAFullLog() async throws {
        let center = try center("alerts-pane-log-full")
        await seed(center, crossings: 5)
        XCTAssertEqual(center.recent.count, 5, "five crossings must produce five rows")

        let host = hosted(AlertsPane(center: center, trend: try trend("alerts-pane-log-full-trend")))
        XCTAssertGreaterThan(host.fittingSize.height, 0, "the pane collapsed with a full log")
        XCTAssertGreaterThan(controls(in: host).count, 4, "the log rows displaced the form")
    }

    /// The log is capped by the center, not by the pane. More crossings than
    /// the cap must still draw the cap's worth of rows and nothing else.
    @MainActor
    func testThePaneRendersALogThatOverflowed() async throws {
        let center = try center("alerts-pane-log-over")
        await seed(center, crossings: 8)
        XCTAssertEqual(center.recent.count, 5, "the log is not being trimmed by the center")

        let host = hosted(AlertsPane(center: center, trend: try trend("alerts-pane-log-over-trend")))
        XCTAssertGreaterThan(controls(in: host).count, 4, "an overflowing log broke the form")
    }

    /// Every row asks `wasDelivered`. Under xctest nothing is ever delivered,
    /// which is the branch that draws the "macOS didn't show it" half of the
    /// row, so the pane is only ever exercised on its unhappy log row here —
    /// worth stating rather than leaving as an accident of the harness.
    @MainActor
    func testLoggedAlertsAreMarkedUndeliveredUnderTest() async throws {
        let center = try center("alerts-pane-delivery")
        await seed(center, crossings: 1)
        let alert = try XCTUnwrap(center.recent.first)
        XCTAssertFalse(center.wasDelivered(alert), "a test bundle cannot have delivered anything")
    }

    // MARK: - Levels that were never meant to be there

    /// The two steppers are read out of `rules.levels` with `first` and
    /// `dropFirst`, which is the only shape that survives an array holding none,
    /// one, or six of them. These are the arrays a stored preference can
    /// actually contain — empty, zero, negative, out of range, out of order, and
    /// the boundaries either side of the levels the pane offers.
    ///
    /// The pane has to build for all of them. A crash here is a settings window
    /// that cannot be opened at all.
    ///
    /// Non-finite levels are the one shape missing, and deliberately: the pane
    /// converts a level with `Int((level * 100).rounded())`, which traps on a NaN
    /// or an infinity rather than drawing anything. `testNonFiniteLevelsCannotBeStored`
    /// is what stands behind that — JSON cannot carry either one, so a level
    /// reaching the pane has already been through a round trip that refuses them.
    @MainActor
    func testDegenerateStoredLevelsStillBuildThePane() async throws {
        let cases: [(name: String, levels: [Double])] = [
            ("empty", []),
            ("zero", [0]),
            ("both zero", [0, 0]),
            ("negative", [-0.5, -0.1]),
            ("over one", [1.5, 2.0]),
            ("exactly one", [1.0, 1.0]),
            ("single", [0.80]),
            ("six", [0.10, 0.20, 0.30, 0.40, 0.50, 0.60]),
            ("out of order", [0.95, 0.80]),
            ("equal", [0.80, 0.80]),
            // Either side of the floor the lower stepper is held at, of the
            // ceiling the upper one is held at, and of the five-point gap kept
            // between them.
            ("below the floor", [0.49, 0.54]),
            ("on the floor", [0.50, 0.55]),
            ("above the ceiling", [0.96, 0.99]),
            ("on the ceiling", [0.90, 0.95]),
            ("inside the gap", [0.80, 0.81]),
            ("inverted past the gap", [0.95, 0.55])
        ]

        for (index, testCase) in cases.enumerated() {
            var rules = ThresholdRules.default
            rules.levels = testCase.levels
            rules.isEnabled = true
            let center = try center("alerts-pane-levels-\(index)", rules: rules)

            let host = hosted(AlertsPane(
                center: center,
                trend: try trend("alerts-pane-levels-trend-\(index)")
            ))
            XCTAssertGreaterThan(
                controls(in: host).count, 4,
                "\(testCase.name) levels did not build the form"
            )
            XCTAssertEqual(
                center.rules.levels, testCase.levels,
                "drawing the pane rewrote the \(testCase.name) levels"
            )
        }
    }

    /// The pane's percentages are `Int((level * 100).rounded())`, which traps on
    /// a NaN or an infinity. What keeps that unreachable is the store rather
    /// than the pane: JSON has no spelling for either, `JSONEncoder` refuses to
    /// write one, and `JSONDecoder` can therefore never produce one — so a
    /// preference that survived a launch is finite by construction.
    ///
    /// Pinned here because it is the whole argument for the conversion being
    /// safe, and nothing in the pane restates it. If this ever starts passing a
    /// non-finite level through, the settings window stops opening.
    @MainActor
    func testNonFiniteLevelsCannotBeStored() async throws {
        let store = try scratch("alerts-pane-nonfinite")
        let center = AlertCenter(store: store, now: { Self.fixedNow })
        let key = "aibars.alerts.rules"

        var sane = ThresholdRules.default
        sane.levels = [0.70, 0.90]
        center.rules = sane
        let written = try XCTUnwrap(store.data(forKey: key), "the sane levels were not stored")

        for levels in [[Double.nan], [.infinity], [-.infinity, 0.9], [0.8, .nan]] {
            var broken = ThresholdRules.default
            broken.levels = levels
            center.rules = broken
            XCTAssertEqual(
                store.data(forKey: key), written,
                "a non-finite level was written to the store and will come back out of it"
            )
        }

        let readBack = try JSONDecoder().decode(ThresholdRules.self, from: written)
        XCTAssertTrue(
            readBack.levels.allSatisfy(\.isFinite),
            "a stored level is not finite, and the pane converts it straight to an Int"
        )
    }

    /// A cooldown of zero, a negative one, and a non-finite one all reach the
    /// pane from a stored preference, and none of them is a reason for it not
    /// to open.
    @MainActor
    func testDegenerateCooldownsStillBuildThePane() async throws {
        for (index, cooldown) in [0, -1, -.infinity, .infinity, TimeInterval.nan].enumerated() {
            var rules = ThresholdRules.default
            rules.cooldown = cooldown
            rules.isEnabled = true
            let center = try center("alerts-pane-cooldown-\(index)", rules: rules)
            let host = hosted(AlertsPane(
                center: center,
                trend: try trend("alerts-pane-cooldown-trend-\(index)")
            ))
            XCTAssertGreaterThan(
                controls(in: host).count, 4,
                "a cooldown of \(cooldown) did not build the form"
            )
        }
    }

    /// The threshold section is dimmed rather than hidden while alerts are off,
    /// so both states have to build the same controls. If the disabled state
    /// built fewer, the section would be appearing on the switch rather than
    /// greying out, and the pane would answer "what would this do?" only after
    /// the user had already committed.
    @MainActor
    func testTheThresholdSectionIsBuiltWhetherOrNotAlertsAreOn() async throws {
        var on = ThresholdRules.default
        on.isEnabled = true

        let off = hosted(AlertsPane(
            center: try center("alerts-pane-off"),
            trend: try trend("alerts-pane-off-trend")
        ))
        let lit = hosted(AlertsPane(
            center: try center("alerts-pane-on", rules: on),
            trend: try trend("alerts-pane-on-trend")
        ))

        XCTAssertEqual(
            controls(in: off).count, controls(in: lit).count,
            "the thresholds are being hidden by the switch rather than dimmed"
        )
    }

    /// The pace switch is the trend store's, not the center's — the one place
    /// in this pane that writes somewhere else entirely.
    @MainActor
    func testThePaceSwitchWritesThroughToTheTrendStore() async throws {
        let name = "alerts-pane-pace"
        let store = try scratch(name)
        let trend = UsageTrendStore(store: store, now: { Self.fixedNow })
        XCTAssertTrue(trend.showsPaceInPanel, "the pace line ships on")

        _ = hosted(AlertsPane(center: try center("alerts-pane-pace-center"), trend: trend))
        trend.showsPaceInPanel = false

        XCTAssertEqual(
            store.object(forKey: "aibars.forecast.showsPace") as? Bool, false,
            "the pace switch did not write through to the store it was given"
        )
    }

}

private extension UsageData {
    /// A copy of the reading with different figures, for the windows the policy
    /// refuses to watch: no ceiling at all, or a figure that is not a number.
    func mutating(used: Double? = nil, limit: Double) -> UsageData {
        UsageData(
            providerID: providerID,
            fetchedAt: fetchedAt,
            planName: planName,
            primary: UsageMetric(
                label: primary.label,
                used: used ?? primary.used,
                limit: limit,
                unit: primary.unit,
                resetDate: primary.resetDate,
                windowLabel: primary.windowLabel
            ),
            secondary: secondary
        )
    }
}
