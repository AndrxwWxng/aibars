import SwiftUI

/// The Alerts pane of Settings: the switch that turns warnings on, what counts
/// as close enough to a cap to be worth one, and whether the warnings that were
/// posted actually arrived.
///
/// One tab for two capabilities, not two. Forecasting has exactly one setting a
/// user can hold an opinion about — whether rows draw a pace line — and a tab of
/// its own for a single switch is a tab you learn to skip. It belongs beside the
/// thresholds because a burn rate and a threshold answer the same question at
/// different distances: the alert says you are nearly out, the pace line says
/// when you will be.
///
/// Launching at login is deliberately *not* here. It is `LaunchAtLoginSection`,
/// which the General tab drops in: a Mac user looks for login items under
/// general, beside the refresh interval, and filing it under a word like
/// "alerts" is filing it where nobody will look.
///
/// Modeless, like every other pane in this window. Each control writes through
/// to `AlertCenter.rules` or `UsageTrendStore`, both of which persist on change;
/// there is no save button to add and nothing to cancel.
public struct AlertsPane: View {
    @ObservedObject private var center: AlertCenter
    @ObservedObject private var trend: UsageTrendStore

    /// Stored dependencies rather than `@EnvironmentObject`, like every other
    /// pane in this window: the settings window is an `NSHostingView` built with
    /// only `AppState` in its environment, and a missing environment object is a
    /// crash on the way in rather than a fallback.
    ///
    /// Resolved in the init body rather than as a default argument, as
    /// `AppearancePane` does — a default argument is evaluated at the call site,
    /// and both `shared`s are main-actor isolated, so writing them there would
    /// constrain who is allowed to build the pane.
    public init(center: AlertCenter? = nil, trend: UsageTrendStore? = nil) {
        self._center = ObservedObject(wrappedValue: center ?? AlertCenter.shared)
        self._trend = ObservedObject(wrappedValue: trend ?? UsageTrendStore.shared)
    }

    public var body: some View {
        Form {
            switchSection
            thresholdSection
            paceSection
            logSection
        }
        .formStyle(.grouped)
        // Reads back what the system decided while the app was closed, or while
        // the user was in System Settings changing their mind. `primeIfNeeded`
        // asks at most once per install and only ever reads afterwards, so
        // opening this pane cannot become a second prompt.
        .task { await center.primeIfNeeded() }
    }

    // MARK: - The switch

    private var switchSection: some View {
        Section {
            Toggle("Warn me before a cap is hit", isOn: alertsEnabled)
            permissionLine
        } header: {
            Text("Alerts")
        } footer: {
            SectionFooter("Off until you ask for it. Turning it on is what makes macOS put up its notification prompt — aibars asks for nothing before you flip this, and never asks twice.")
        }
    }

    /// Not `$center.rules.isEnabled`, because turning this on has to do the one
    /// thing writing the rule does not: ask macOS. `AlertCenter` deliberately
    /// keeps the prompt out of its `didSet` — it is a user action, not a
    /// consequence of a value changing, and a decoded preference must not raise
    /// a permission panel at launch. That makes this switch the place the ask
    /// belongs, and the only place it happens.
    private var alertsEnabled: Binding<Bool> {
        Binding(
            get: { self.center.rules.isEnabled },
            set: { isOn in
                self.center.rules.isEnabled = isOn
                guard isOn else { return }
                Task { await self.center.primeIfNeeded() }
            }
        )
    }

    /// What macOS will do with a warning, and the way out when the answer is
    /// nothing. `AlertPermission` writes the sentence and says nothing at all
    /// when there is nothing to explain, so this draws a row only when it does —
    /// a switch reading "on" over a permission that was refused is a promise the
    /// app cannot keep, and there is no other surface where that shows.
    ///
    /// Silent while alerts are off, whatever the permission says. A refusal is
    /// only bad news about alerts that were going to be sent, and the user who
    /// turned them off afterwards is being warned about a consequence they have
    /// already dealt with.
    @ViewBuilder
    private var permissionLine: some View {
        if center.rules.isEnabled, let explanation = center.permission.explanation {
            HStack(spacing: Tokens.Space.gutter) {
                Text(explanation)
                    .font(.system(size: Tokens.Ramp.caption))
                    .foregroundStyle(Tokens.Ink.attention)
                    .fixedSize(horizontal: false, vertical: true)

                // Only for a refusal. `.unavailable` is a build macOS will not
                // serve at all, and sending that user to Notifications shows
                // them a pane with no aibars in it to switch back on.
                if center.permission == .denied {
                    Spacer(minLength: Tokens.Space.gutter)
                    Button("Open Notifications…") {
                        AlertCenter.openNotificationSettings()
                    }
                    .controlSize(.small)
                    .help("Opens Notifications in System Settings.")
                    // Wider than the column the window's other buttons share,
                    // and a truncated button no longer names where it goes.
                    .fixedSize()
                }
            }
        }
    }

    // MARK: - Thresholds

    /// Dimmed rather than removed while alerts are off. Someone deciding whether
    /// to turn this on is deciding what it would do, and a section that appears
    /// only after the switch flips answers that in the wrong order — unlike the
    /// Appearance pane's hidden rows, none of these stops meaning anything when
    /// the thing above them is off.
    private var thresholdSection: some View {
        Section {
            PercentStepper(title: "First warning", value: lowerLevel, range: lowerRange)
            PercentStepper(title: "Second warning", value: upperLevel, range: upperRange)
            Toggle("Count the extra usage windows", isOn: $center.rules.coversSecondaryWindows)
            Toggle("Say when a window resets", isOn: $center.rules.announcesReset)
        } header: {
            Text("When to warn")
        } footer: {
            SectionFooter(thresholdFooter)
        }
        .disabled(!center.rules.isEnabled)
    }

    private var thresholdFooter: String {
        var lines = ["Two warnings because they are two different messages: the first while you can still change what you're doing, the second when it is about to stop working. Each fires as it is crossed and then stays quiet until usage falls five points back below it, so a window parked just over a level is announced once rather than every minute — and nothing fires the first time aibars sees a window, because installing at 92% is not a crossing it watched happen."]
        if center.rules.coversSecondaryWindows {
            lines.append("The extra windows are the weekly and per-model caps under a service's headline number, so a weekly limit can warn you while the five-hour one it sits under is nowhere near.")
        }
        if center.rules.announcesReset {
            lines.append("A reset is the one alert that isn't a warning: it says a window you were told about is clear again.")
        }
        return lines.joined(separator: " ")
    }

    // MARK: - Reading and writing the two levels

    /// The pair the steppers edit, as whole percentages.
    ///
    /// `ThresholdRules.levels` is an array — the policy evaluates however many it
    /// is handed — while this pane offers exactly two, which is what ships. It is
    /// read through `first`/`dropFirst` rather than subscripted because a stored
    /// preference is not obliged to hold two of anything, and a stepper bound to
    /// an index that isn't there is a crash on the way into Settings. The final
    /// literals cannot be reached while `ThresholdRules.default` has levels in
    /// it, but a chain of `??` has to end somewhere and it ends on the shipped
    /// defaults rather than on zero.
    private var levels: (lower: Int, upper: Int) {
        let stored = center.rules.levels.sorted()
        let fallback = ThresholdRules.default.levels
        let lower = stored.first ?? fallback.min() ?? 0.80
        let upper = stored.dropFirst().first ?? fallback.max() ?? 0.95
        return (Self.percent(lower), Self.percent(upper))
    }

    private var lowerLevel: Binding<Int> {
        Binding(
            get: { self.levels.lower },
            set: { self.write(lower: $0, upper: self.levels.upper) }
        )
    }

    private var upperLevel: Binding<Int> {
        Binding(
            get: { self.levels.upper },
            set: { self.write(lower: self.levels.lower, upper: $0) }
        )
    }

    /// Written back as a whole array because that is the shape the rules keep,
    /// and sorted because sorting on write is what stops the two crossing
    /// however the pair got there — the coupled ranges below hold the steppers
    /// apart, but a value that arrives from anywhere else still has to land in
    /// order.
    private func write(lower: Int, upper: Int) {
        center.rules.levels = [Double(lower) / 100, Double(upper) / 100].sorted()
    }

    /// Rounded, never truncated: the same rule the panel's percentages follow,
    /// so a level shown as 80% here is the level a row reports crossing.
    private static func percent(_ fraction: Double) -> Int {
        Int((fraction * 100).rounded())
    }

    /// The two levels are kept five points apart, so the steppers are given
    /// coupled bounds. With a fixed track the lower stepper could be walked up
    /// past the upper one and sorted out from under the pointer, which reads as
    /// the two swapping places by themselves.
    ///
    /// The same treatment `AppearancePane` gives the colour thresholds, and for
    /// the same reason.
    ///
    /// Both ends sit on the same five-point grid the stepper moves in. A ceiling
    /// of 99 with a step of 5 is a ceiling nobody can reach: from 95 the next
    /// step is 100, the stepper refuses it, and the last four points of the
    /// track exist only to grey the button out.
    private var lowerRange: ClosedRange<Int> {
        // The floor guards the range from inverting rather than describing a
        // reachable state: the upper level is itself held at 55 and above.
        50...max(50, min(90, levels.upper - 5))
    }

    private var upperRange: ClosedRange<Int> {
        min(95, max(55, levels.lower + 5))...95
    }

    // MARK: - Pace

    private var paceSection: some View {
        Section {
            Toggle("Show a pace line on each row", isOn: $trend.showsPaceInPanel)
            if paceNeedsFasterRefresh {
                Text("No pace can be shown while the refresh interval is \(refreshIntervalName). The fit reads the last half hour and ignores anything older than fifteen minutes, so readings this far apart never make three inside the window. Set it to 5 minutes or less in General.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Pace")
        } footer: {
            SectionFooter("aibars watches how fast each window is filling and puts the time it would run out under the bar. It needs three readings at least five minutes apart before it says anything, it stops looking twelve hours ahead, and a window that is idle or falling has no pace and shows none — a line drawn through one reading is not a forecast.")
        }
    }

    /// Three readings have to land inside `UsageForecast.window`, and the newest
    /// has to be fresher than `UsageForecast.stalenessLimit`. Polling slower than
    /// that makes a pace line impossible rather than merely coarse, and a toggle
    /// that cannot do anything should say so instead of sitting there switched on.
    private var paceNeedsFasterRefresh: Bool {
        Double(AppState.shared.refreshIntervalSeconds) > UsageForecast.stalenessLimit
    }

    private var refreshIntervalName: String {
        let seconds = AppState.shared.refreshIntervalSeconds
        return seconds % 60 == 0 ? "\(seconds / 60) minutes" : "\(seconds) seconds"
    }

    // MARK: - What was actually sent

    /// `AlertCenter.recent` is already newest first and already trimmed to the
    /// last five, so this neither sorts nor truncates. Doing either here would
    /// be a second opinion about a list whose length is the centre's own
    /// constant, free to disagree with it after a change to one side.
    private var logSection: some View {
        Section {
            if center.recent.isEmpty {
                Text(center.rules.isEnabled
                     ? "Nothing has crossed a level yet."
                     : "Alerts are off, so there is nothing here.")
                    .font(.system(size: Tokens.Ramp.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // Keyed on position rather than on the alert. `PendingAlert.key`
                // is stable per provider and window, so the same window firing
                // at the first level and again at the second produces two rows
                // under one key — a repeated `ForEach` id draws one of them and
                // silently drops the other.
                ForEach(Array(center.recent.enumerated()), id: \.offset) { row in
                    AlertLogRow(alert: row.element, delivered: center.wasDelivered(row.element))
                }
            }
        } header: {
            Text("Recent alerts")
        } footer: {
            SectionFooter("Posting a notification and showing one are different things: a Focus, Do Not Disturb, or the Notifications settings can swallow one aibars sent. Every alert is listed here either way, so a quiet menu bar can be told apart from a quiet Mac.")
        }
    }
}

// MARK: - Rows

/// One alert the policy produced: what it said, when, and whether macOS took it.
///
/// Laid out like `BrowserSourceRow` in the Services pane — a symbol in the logo
/// column, then a title over its detail — because the two are the same kind of
/// row and this window has one shape for that.
private struct AlertLogRow: View {
    let alert: PendingAlert
    /// Kept off `PendingAlert` by `AlertCenter`, because the policy that built
    /// the alert has no way of knowing what became of it.
    let delivered: Bool

    var body: some View {
        HStack(spacing: Tokens.Space.gutter) {
            Image(systemName: delivered ? "bell" : "bell.slash")
                .foregroundStyle(delivered ? Tokens.Ink.idle : Tokens.Ink.attention)
                // The column a provider logo occupies, so every row in this
                // window starts its text at one x instead of several.
                .frame(width: Tokens.Control.settingsLogo)

            VStack(alignment: .leading, spacing: Tokens.Space.hairline) {
                Text(alert.title)
                    .font(.system(size: Tokens.Ramp.title, weight: Tokens.Ramp.emphasisWeight))
                    .lineLimit(1)

                Text(alert.body)
                    .font(.system(size: Tokens.Ramp.caption))
                    .foregroundStyle(.secondary)
                    // Wraps rather than truncates: the body carries the figure
                    // and the window it belongs to, which is the whole content
                    // of the row.
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Text(meta)
                    .font(.system(size: Tokens.Ramp.caption))
                    .foregroundStyle(delivered ? Tokens.Ink.idle : Tokens.Ink.attention)
            }

            Spacer(minLength: Tokens.Space.gutter)
        }
        .padding(.vertical, Tokens.Space.tight)
    }

    /// "3h 12m ago · delivered". Both halves on every row, including the happy
    /// one: the question this list exists to answer is whether alerts are
    /// landing, and a row that says nothing when they are leaves the reader to
    /// infer it from the shape of an icon.
    private var meta: String {
        [age, delivered ? "delivered" : "macOS didn't show it"]
            .joined(separator: " · ")
    }

    /// The panel's own countdown, run backwards: `Countdown.short` measures from
    /// `from` to `until`, so an elapsed time is those two swapped. A second
    /// formatter here would be a second set of rounding rules for the "3h 12m"
    /// the dropdown is already showing.
    private var age: String {
        Countdown.short(until: Date(), from: alert.at).map { "\($0) ago" } ?? "just now"
    }
}

/// A labelled percentage with a stepper. Set like the Appearance pane's own
/// steppers and sliders — caption type, monospaced, trailing in one width —
/// because "80%" here and "62%" there are the same kind of answer to an eye
/// running down the settings window.
private struct PercentStepper: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        LabeledContent(title) {
            // Five at a time, which is also the width of the policy's
            // hysteresis: a warning at 83% rather than 85% is a distinction
            // nobody holds an opinion about, and single steps make the walk from
            // 50 to 90 forty clicks long.
            Stepper(value: $value, in: range, step: 5) {
                Text("\(value)%")
                    .font(.system(size: Tokens.Ramp.caption))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    // A readout wide enough to wrap would take the row's height
                    // with it, and the row below would shift half a line as the
                    // value crossed 100.
                    .lineLimit(1)
                    .frame(width: Tokens.Control.readoutWidth, alignment: .trailing)
            }
        }
    }
}

// MARK: - Login items

/// Launch at login, as a `Section` the General tab drops into its own `Form`.
///
/// A section rather than a pane because that is where it is looked for: under
/// general, beside the refresh interval, in the same place System Settings keeps
/// its own login items list. A tab called "Startup" holding one switch is a tab
/// nobody opens twice.
///
/// The toggle reads `LoginItem.state` rather than a preference of its own.
/// `SMAppService` refuses registrations routinely — a copy still sitting in
/// Downloads is the ordinary case — so a switch backed by our own bool would sit
/// there saying "on" over a login item that does not exist. Reading the state
/// back means a refused registration returns the switch to off with the reason
/// underneath, which looks like the control failed and is the honest answer: it
/// did.
public struct LaunchAtLoginSection: View {
    @ObservedObject private var item: LoginItem

    /// Resolved in the init body rather than as a default argument, for the same
    /// reason `AlertsPane` does it: `shared` is main-actor isolated and a default
    /// argument is evaluated at the call site.
    public init(item: LoginItem? = nil) {
        self._item = ObservedObject(wrappedValue: item ?? LoginItem.shared)
    }

    public var body: some View {
        Section {
            // `LoginItemState.isOn` decides where the switch sits, including the
            // awkward middle case where macOS has registered the item but wants
            // it confirmed. That reads as on, because unticking it would take
            // away the very thing the note underneath is asking them to approve.
            Toggle("Open aibars at login", isOn: Binding(
                get: { self.item.state.isOn },
                set: { self.item.setEnabled($0) }
            ))

            // The note and the button travel together. `LoginItemState` writes a
            // note for exactly the states the user can do something about, and
            // both of those sentences end by pointing at Login Items — deciding
            // again in here which states earn the button would be a copy of that
            // rule, free to disagree with the sentence printed beside it.
            if let note = item.state.note {
                HStack(spacing: Tokens.Space.gutter) {
                    Text(note)
                        .font(.system(size: Tokens.Ramp.caption))
                        .foregroundStyle(Tokens.Ink.attention)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: Tokens.Space.gutter)

                    Button("Open Login Items…") {
                        LoginItem.openLoginItemsSettings()
                    }
                    .controlSize(.small)
                    .help("Opens General → Login Items in System Settings.")
                    // Wider than the column the window's other buttons share,
                    // and a truncated button no longer names where it goes.
                    .fixedSize()
                }
            }
        } footer: {
            SectionFooter("Registered with macOS as a login item, which is the list System Settings shows under General → Login Items. Nothing is copied into your Applications folder and no launch agent is written, so moving or deleting the app is enough to undo it.")
        }
        // The user can change login items behind the app's back, and this
        // section is often the next thing they look at when they do.
        .onAppear { item.refresh() }
    }
}
