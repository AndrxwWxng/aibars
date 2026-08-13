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
/// Two things neither measurement can reach, and how each is reached instead.
/// The log rows are a `private` struct with no controls in them, so their height
/// is taken as a difference between two panes and pinned against a reference row
/// of known line count. Their colours cannot be measured at all — a Form does
/// not rasterise here, and `Ink.attention` and the usage ramp's amber are the
/// same hex, so a pixel could not name where it came from — so that one is
/// checked as what it actually is: a fact about which vocabulary the pane's
/// source names.
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

    /// A window counted in something rather than in percent, and with a reset on
    /// it. That is the combination `ThresholdPolicy` writes its longest body for:
    /// the label, both figures, the unit, and the countdown.
    private func countedReading(percent: Double) -> UsageData {
        UsageData(
            providerID: "seed",
            fetchedAt: Self.fixedNow,
            planName: "Business",
            primary: UsageMetric(
                label: "Weekly credits left",
                used: percent * 50_000,
                limit: 50_000,
                unit: "credits",
                resetDate: Self.fixedNow.addingTimeInterval(6 * 86_400 + 23 * 3_600),
                windowLabel: "7d window"
            )
        )
    }

    /// Fills the log by driving the policy, because `AlertCenter.recent` is
    /// `private(set)` and there is no back door — which is the right shape for
    /// it and means the seeding has to obey the same rule the feature does:
    /// nothing fires on first sight, so every window is shown low once and then
    /// over the line.
    @MainActor
    private func seed(_ center: AlertCenter, crossings: Int) async {
        await seed(center, crossings: crossings, named: { "Service \($0)" }) { self.reading(percent: $0) }
    }

    /// The same seeding with the strings the rows will carry left to the caller,
    /// for the tests that are about how long a row's text is rather than about
    /// how many rows there are. The window is handed back at whatever percentage
    /// the crossing needs, so one builder covers both sightings.
    @MainActor
    private func seed(
        _ center: AlertCenter,
        crossings: Int,
        named name: (Int) -> String,
        window: (Double) -> UsageData
    ) async {
        center.rules.isEnabled = true
        for index in 0..<crossings {
            let id = "seeded-\(index)"
            await center.consider(window(0.10), providerID: id, displayName: name(index))
            await center.consider(window(0.90), providerID: id, displayName: name(index))
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
    /// Measured two ways because one is not enough. The count only proves a
    /// toggle was built at all; whether the section's button also counts as an
    /// AppKit control varies by OS, which failed on a CI runner a version away
    /// from the machine this was written on. So the count is a floor and the
    /// height carries the real assertion — the note and the footer under it are
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
        XCTAssertGreaterThanOrEqual(
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

    // MARK: - A row is one height

    /// A log row is three lines of type, and stays three lines whatever the
    /// alert says.
    ///
    /// The rows sit in a scrolling Form under three other sections, so a row that
    /// grew with its text would move the footer under it and change how much of
    /// the log is on screen depending on which services happened to warn — the
    /// settings equivalent of the panel's reflow.
    ///
    /// Measured as whole panes rather than as one row, because `AlertLogRow` is
    /// `private` to the pane and rightly so. One row against five cancels the
    /// Form's own chrome and leaves the row, which is the same subtraction
    /// `testLaunchAtLoginSectionInstantiatesItsToggleAndItsNote` makes against a
    /// bare switch.
    ///
    /// Two claims, and the second is the one with teeth. That the shortest and
    /// the longest alert the pane can produce measure the same is worth stating
    /// but not much: a grouped Form row here takes its height from the row's
    /// *ideal* width rather than the width it is drawn at, so a body that would
    /// wrap on screen still measures one line, and the string lengths cannot fail
    /// this on their own — `testEveryAlertTheLogCanShowIsOneLineOfProse` is what
    /// stands behind them instead. What this measurement does see is a row gaining
    /// or losing a *line*, so it is pinned against a reference: three lines of the
    /// window's own type, laid out the same way, with none of the row's content in
    /// it.
    @MainActor
    func testALogRowIsThreeLinesOfTypeWhateverTheAlertSays() async throws {
        let short = try await measuredLog(
            "height-short", rows: 5, service: Self.shortestName, window: shortestWindow
        )
        let long = try await measuredLog(
            "height-long", rows: 5, service: Self.longestName, window: longestWindow
        )

        // What was actually seeded, before two numbers are compared. Two bodies
        // of similar length would agree on a height for reasons that have
        // nothing to do with the row.
        XCTAssertGreaterThan(
            long.sample.body.count, short.sample.body.count + 30,
            "the long body is \"\(long.sample.body)\" against \"\(short.sample.body)\" — the two cases are "
                + "too close together to be measuring anything"
        )

        let single = try await measuredLog(
            "height-one", rows: 1, service: Self.shortestName, window: shortestWindow
        )
        let singleLong = try await measuredLog(
            "height-one-long", rows: 1, service: Self.longestName, window: longestWindow
        )
        let shortRow = (short.height - single.height) / 4
        let longRow = (long.height - singleLong.height) / 4

        // The control: two equal numbers prove nothing until the measurement is
        // shown to move. One row against five has to differ by four rows, or
        // `fittingSize` is answering about the scroll view rather than the log.
        XCTAssertGreaterThan(
            shortRow, Tokens.Ramp.title,
            "one row and five differ by \(shortRow)pt each — this harness is not measuring the log at all"
        )

        XCTAssertEqual(
            longRow, shortRow,
            "a row carrying the longest alert is \(longRow)pt against \(shortRow)pt for the shortest — a log "
                + "row is growing with its text"
        )

        let threeLines = threeLineRow()
        XCTAssertEqual(
            shortRow, threeLines, accuracy: Tokens.Space.tight,
            "a log row is \(shortRow)pt against \(threeLines)pt for three lines of this window's type — the "
                + "row has gained or lost a line"
        )
    }

    /// Three lines of the window's own type in a Form row, at the row's spacing
    /// and padding, and nothing else: a title, a detail under it, and a second
    /// detail under that. The reference for how tall a log row should be.
    ///
    /// Not a copy of `AlertLogRow` — it has none of its content, none of its
    /// colours and no leading symbol, and it is not asserted to be pixel-identical.
    /// What it stands for is the line count, which is the one thing about the row
    /// this harness can still see.
    @MainActor
    private func threeLineRow() -> CGFloat {
        func height(rows: Int) -> CGFloat {
            hosted(
                Form {
                    Section {
                        ForEach(0..<rows, id: \.self) { _ in
                            VStack(alignment: .leading, spacing: Tokens.Space.hairline) {
                                Text("A title")
                                    .font(.system(size: Tokens.Ramp.title, weight: Tokens.Ramp.titleWeight))
                                Text("A detail")
                                    .font(.system(size: Tokens.Ramp.caption))
                                Text("A second detail")
                                    .font(.system(size: Tokens.Ramp.caption))
                            }
                            .padding(.vertical, Tokens.Space.tight)
                        }
                    }
                }
                .formStyle(.grouped)
                .frame(width: Self.paneWidth)
            ).fittingSize.height
        }
        // The same subtraction as the log's, so the Form's own chrome cancels on
        // both sides of the comparison rather than being estimated on either.
        return (height(rows: 5) - height(rows: 1)) / 4
    }

    /// And the reason the heights above agree: every alert either policy can
    /// compose is one line of prose.
    ///
    /// This is the half with teeth. `AlertLogRow` holds its title to one line and
    /// its body to two, so a row can never grow without bound — but one row
    /// wrapping to two lines while its neighbours stay at one is exactly the
    /// ragged log the height test is meant to forbid, and a newline in a message
    /// is the way that happens without anybody widening a string. Both policies
    /// build their bodies by joining parts, and a join with the wrong separator
    /// is a one-character change.
    ///
    /// Driven through the policies rather than asserted against literals, so it
    /// covers what they actually emit: a percentage window, a counted window with
    /// a countdown on it, a reset, and a budget in each of its three sentences —
    /// under every service name aibars ships, since the name is what the title is
    /// mostly made of.
    @MainActor
    func testEveryAlertTheLogCanShowIsOneLineOfProse() async throws {
        var rules = ThresholdRules.default
        rules.isEnabled = true
        rules.announcesReset = true

        // The two names the height test measures with are aibars' own, and the
        // long one is the longest of them. Pinned here rather than there because
        // this is where the list is already in hand: a service added with a longer
        // name has to move that measurement rather than sit outside it.
        let names = Self.shippedDisplayNames
        XCTAssertTrue(names.contains(Self.shortestName), "\(Self.shortestName) is no longer a service")
        XCTAssertEqual(
            names.max(by: { $0.count < $1.count }), Self.longestName,
            "the longest service name is no longer \(Self.longestName)"
        )
        XCTAssertEqual(
            Self.shortestName.count, names.map(\.count).min(),
            "\(Self.shortestName) is no longer as short as a service name gets"
        )

        var alerts: [PendingAlert] = []
        for name in names {
            for window in [reading(percent: 0.90), countedReading(percent: 0.90)] {
                // Seen low first, because nothing fires on first sight, then over
                // the line, then back under it for the reset.
                let low = window.mutating(used: 0.10 * window.primary.limit, limit: window.primary.limit)
                var state = ThresholdPolicy.evaluate(
                    low, providerID: "one", displayName: name,
                    rules: rules, state: ThresholdState(), now: Self.fixedNow
                ).state
                var step = ThresholdPolicy.evaluate(
                    window, providerID: "one", displayName: name,
                    rules: rules, state: state, now: Self.fixedNow
                )
                alerts += step.alerts
                state = step.state
                step = ThresholdPolicy.evaluate(
                    low, providerID: "one", displayName: name,
                    rules: rules, state: state, now: Self.fixedNow
                )
                alerts += step.alerts
            }

            // Budgets: most of the cap, past it, and each of those on figures
            // this app worked out rather than was billed — the three sentences
            // `BudgetAlertPolicy` writes.
            let budget = Budget(amountMinor: 5_000, currency: "USD")
            for spentMinor in [4_500, 6_123] {
                for confidence in [SpendReport.Confidence.measured, .estimated] {
                    func spend(_ minor: Int) -> SpendReport {
                        SpendReport(
                            amountMinor: minor, currency: "USD",
                            period: .month, confidence: confidence
                        )
                    }
                    // Seeded at nothing spent first: a service is only ever
                    // armed by a reading the policy watched arrive.
                    let seeded = BudgetAlertPolicy.evaluate(
                        spend: spend(0), serviceID: "one", displayName: name, budget: budget,
                        rules: rules, state: BudgetAlertState(), now: Self.fixedNow
                    ).state
                    alerts += BudgetAlertPolicy.evaluate(
                        spend: spend(spentMinor), serviceID: "one", displayName: name, budget: budget,
                        rules: rules, state: seeded, now: Self.fixedNow
                    ).alerts
                }
            }
        }

        // The matrix has to have produced all three kinds, or the strings that
        // went unchecked are the ones a change would break.
        XCTAssertGreaterThan(
            alerts.count, names.count,
            "the policies produced almost nothing to check"
        )
        XCTAssertTrue(
            alerts.contains { $0.title.hasSuffix("reset") },
            "no reset alert was produced, so the reset body went unchecked"
        )
        XCTAssertTrue(
            alerts.contains { $0.title.contains("of budget") },
            "no budget alert was produced, so the budget bodies went unchecked"
        )
        XCTAssertTrue(
            alerts.contains { $0.body.contains("resets in") },
            "no crossing carried a countdown, so the longest body went unchecked"
        )
        XCTAssertTrue(
            alerts.contains { $0.body.contains("partly estimated") },
            "no budget alert was estimated, so the longest budget body went unchecked"
        )
        for alert in alerts {
            for (part, text) in [("title", alert.title), ("body", alert.body)] {
                XCTAssertFalse(
                    text.contains(where: \.isNewline),
                    "a \(part) the log has to draw carries a line break: \(text.debugDescription)"
                )
                XCTAssertFalse(
                    text.contains("\t"),
                    "a \(part) the log has to draw carries a tab: \(text.debugDescription)"
                )
            }
        }
    }

    // MARK: - Measuring the log

    /// The shortest and the longest alert the pane can produce, as the two parts
    /// each is made of: who it is about, and which window. Both names are aibars'
    /// own, and `shippedDisplayNames` is what keeps them so.
    private static let shortestName = "Grok"
    private static let longestName = "GitHub Copilot"

    /// A window stated in percent, whose body is its bare label and nothing else.
    private func shortestWindow(_ percent: Double) -> UsageData {
        reading(percent: percent, label: "5h")
    }

    /// A counted window with a reset on it: label, both figures, unit, countdown.
    private func longestWindow(_ percent: Double) -> UsageData {
        countedReading(percent: percent)
    }

    /// Every service name that can appear in an alert title, read off the app's
    /// own list rather than written out here — a service added with a long name
    /// is exactly the change that would go unnoticed.
    ///
    /// `AppState.services` is a static list of constructors and nothing else, so
    /// this reaches no shared state: `make(nil)` builds a provider for its name
    /// and drops it.
    @MainActor
    private static var shippedDisplayNames: [String] {
        AppState.services.map { $0.make(nil).displayName }
    }

    /// The pane's height with `rows` alerts in it, and one of the alerts to check
    /// the seeding by. Named per call because the center and the trend store are
    /// both scratch domains and two of them must not share one.
    ///
    /// Width pinned, for the reason `testLaunchAtLoginSectionInstantiatesItsToggleAndItsNote`
    /// pins its own: an unconstrained Form lays its footers out on one very long
    /// line, and a pane measured that way is a pane with no prose in it.
    @MainActor
    private func measuredLog(
        _ name: String,
        rows: Int,
        service: String,
        window: (Double) -> UsageData
    ) async throws -> (height: CGFloat, sample: PendingAlert) {
        let center = try center("alerts-pane-\(name)")
        await seed(center, crossings: rows, named: { _ in service }, window: window)
        XCTAssertEqual(center.recent.count, rows, "\(name) seeded \(center.recent.count) rows, not \(rows)")
        let host = hosted(
            AlertsPane(center: center, trend: try trend("alerts-pane-\(name)-trend"))
                .frame(width: Self.paneWidth)
        )
        return (host.fittingSize.height, try XCTUnwrap(center.recent.first))
    }

    /// The narrowest a settings pane's form is allowed to be, which is where a
    /// string wraps first. Measuring at the width the window happens to open at
    /// would be measuring the comfortable case.
    private static let paneWidth: CGFloat = Tokens.Control.formMinWidth

    // MARK: - Which vocabulary the log speaks

    /// The log's colours are state colours, out of `Tokens.Ink`, and never usage
    /// colours out of `UsageTint`.
    ///
    /// The confusion is available: every alert in this list has a percentage in
    /// its title, `UsageTint` takes a percentage, and both vocabularies own the
    /// same amber and the same red. But a log row is not reporting a reading, it
    /// is reporting whether macOS showed the warning — `Ink.attention` for one it
    /// swallowed, `Ink.idle` for one it showed — and neither of those states is a
    /// place on the ramp *at a reading an alert can be about*.
    ///
    /// That qualifier had a life of exactly one pass and is gone again. For that
    /// pass `Ink.idle` was `Ink.muted` and so was the ramp's resting stop — the
    /// private grey standing beside it (0x5F636B / 0x8A8F98) had been deleted as
    /// a duplicate — so below caution the two resolved to the same bytes and the
    /// sweeping form this check takes, "there is no percentage `UsageTint`
    /// answers with `Ink.idle`", was false at 0.0, 0.59 and 0.60.
    ///
    /// The resting stop is `Tokens.Meter.fill` now, off the text ladder
    /// altogether, because folding it into a text ink had left the ramp's first
    /// boundary carried by hue alone — 1.062:1 in dark and 1.020:1 in light
    /// between resting and caution. So the sweeping form is true again and is
    /// restored here rather than paraphrased: the whole range, not just the
    /// readings an alert can fire on. It is the stronger claim and it is the one
    /// the rule was written as.
    ///
    /// Checked two ways, because either alone proves nothing. The colours below
    /// establish that the two vocabularies genuinely disagree about an alert, so
    /// the rule is protecting a visible difference rather than a preference about
    /// names; the source check is the only thing that can see which of them the
    /// pane actually reached for, since the row is `private` and a Form does not
    /// rasterise in this harness.
    func testTheStateInksAndTheUsageRampDisagreeAboutAnAlert() throws {
        // Alerts fire at or above a level, and the shipped upper level is 0.95,
        // so the ordinary undelivered row is an alert about a reading the ramp
        // calls red. The log draws it amber, because amber is what "needs you"
        // means here and the reading's own severity is not the subject.
        for dark in [false, true] {
            let attention = try XCTUnwrap(hex(Tokens.Ink.attention, dark: dark))
            let ramp = try XCTUnwrap(hex(UsageTint.color(for: 0.95), dark: dark))
            XCTAssertNotEqual(
                attention, ramp,
                "on \(dark ? "dark" : "light") the ink and the ramp agree at 95%, so nothing here can tell "
                    + "a log wired to the ramp from one wired to Ink"
            )
        }

        // And the delivered row's grey is not on the ramp at any reading at all.
        // 0.80 is the lowest shipped level and 0.95 the upper one, 1.0 is the
        // cap, 0.84/0.94 sit inside each band so the check does not live only on
        // the boundaries — and 0.0, 0.59, 0.60 and 0.79 walk the resting band,
        // which is where the one-pass fold of the resting stop into `Ink.muted`
        // made this false. A log speaking the ramp's language could not draw the
        // delivered row in any of these, which is the claim.
        for dark in [false, true] {
            let idle = try XCTUnwrap(hex(Tokens.Ink.idle, dark: dark))
            for percent in [0.0, 0.59, 0.60, 0.79, 0.80, 0.84, 0.94, 0.95, 1.0] {
                XCTAssertNotEqual(
                    idle, hex(UsageTint.color(for: percent), dark: dark),
                    "the ramp reaches Ink.idle at \(percent) on \(dark ? "dark" : "light"), so a "
                        + "delivered row is no longer distinguishable from one the ramp would "
                        + "have drawn"
                )
            }
        }
    }

    /// The half the harness cannot see any other way: the pane names `Ink` and
    /// never names `UsageTint`.
    ///
    /// A source check rather than a rendered one, deliberately. `AlertLogRow` is
    /// `private`, a Form draws its own text rather than instantiating AppKit
    /// controls that could be counted, and the ramp's amber and `Ink.attention`
    /// are the same hex — so a pixel that came out amber could not name where it
    /// came from even if this harness produced one. What is actually being
    /// protected is which vocabulary the file speaks, and that is a fact about
    /// the file.
    ///
    /// Read from the checkout through `#filePath`, which is this test's own
    /// absolute path at build time, so the pane is two directories up and over.
    /// A missing source tree fails rather than skips: silently passing would
    /// retire the rule without anyone deciding to.
    func testThePaneReachesForInkAndNeverForTheUsageRamp() throws {
        let source = try XCTUnwrap(
            try? String(contentsOf: paneSource, encoding: .utf8),
            "could not read \(paneSource.path) — this check needs the source it is about"
        )

        XCTAssertFalse(
            source.contains("UsageTint"),
            "AlertsPane.swift names UsageTint. An alert's colour is its delivery state, not its reading, "
                + "and the ramp would repaint the ordinary undelivered row red"
        )
        // The positive half, so that deleting the colours altogether cannot pass
        // by containing no ramp.
        for ink in ["Tokens.Ink.attention", "Tokens.Ink.idle"] {
            XCTAssertTrue(
                source.contains(ink),
                "AlertsPane.swift no longer names \(ink) — the log's two states are drawn in something else"
            )
        }
    }

    /// `Tests/aibarsTests/AlertsPaneTests.swift` → `Sources/Views/AlertsPane.swift`.
    private var paneSource: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()      // aibarsTests
            .deletingLastPathComponent()      // Tests
            .deletingLastPathComponent()      // the checkout
            .appendingPathComponent("Sources/Views/AlertsPane.swift")
    }

    /// One colour as sRGB, resolved in a named appearance, the way
    /// `UsageRampContrastTests` does it: `performAsCurrentDrawingAppearance`
    /// rather than assigning `NSAppearance.current`, which is deprecated and a
    /// deprecation is a build regression here.
    private func hex(_ color: Color, dark: Bool) -> UInt32? {
        guard let appearance = NSAppearance(named: dark ? .darkAqua : .aqua) else { return nil }
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            resolved = NSColor(color).usingColorSpace(.sRGB)
        }
        guard let srgb = resolved else { return nil }
        func channel(_ value: CGFloat) -> UInt32 { UInt32((min(max(value, 0), 1) * 255).rounded()) }
        return channel(srgb.redComponent) << 16
             | channel(srgb.greenComponent) << 8
             | channel(srgb.blueComponent)
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
