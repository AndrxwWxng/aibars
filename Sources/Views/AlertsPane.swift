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
    /// pane in this window: this pane is built directly, with an `AlertCenter`
    /// and a `UsageTrendStore` handed to it and no environment at all, every
    /// time it is tested — and a pane that reached into the environment for
    /// either could only ever be tested against the two `shared` singletons,
    /// which persist to `UserDefaults.standard` and are therefore whoever ran
    /// the suite. An injectable dependency is what makes the pane measurable.
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
                // Regular, said out loud rather than inherited. The app runs on
                // two weights and one of them is a decision — a name or a figure
                // is `titleWeight`, everything that is context around it is
                // regular — and a caption that only happens to be regular because
                // that is today's default is a weight nobody chose.
                Text(explanation)
                    .font(.system(size: Tokens.Ramp.caption, weight: .regular))
                    .foregroundStyle(permissionInk)
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

    /// Amber where the user can do something about it, quiet where they cannot.
    ///
    /// There is no red left to reach for, and that is deliberate: red means one
    /// thing in this app now — a window at or over its cap — so a red sentence in
    /// here would be the same ink as a service that has run out. A build macOS
    /// will not deliver notifications for at all has nothing to fix and no button
    /// beside it, so it goes to the caption ink and stops asking for a decision
    /// that cannot be made. A refusal does want the user, and the button next to
    /// it is where it gets fixed, so that one keeps `Ink.attention` — the split
    /// `SettingsView` makes on a connection's last error, so the two windows
    /// still agree about which failures want you.
    ///
    /// Only reached for the two states that say anything: `.unknown` and
    /// `.granted` have no explanation and draw no row.
    private var permissionInk: Color {
        center.permission == .denied ? Tokens.Ink.attention : Tokens.Ink.muted
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
                // The third note in this pane that says a switch cannot do what
                // it claims, and amber like every one of them the user can act
                // on: a toggle sitting on over something that cannot work is
                // exactly what `Ink.attention` means, and it is fixable in
                // General — which is the test, not the fact that it is bad
                // news. On the ramp at `Ramp.caption` like every other note here
                // rather than `.callout`, which was a system size a point over
                // the pane's own title and agreed with nothing beside it.
                //
                // Prose with an interval in it, so SF Pro with tabular digits
                // rather than the figure face.
                Text("No pace can be shown while the refresh interval is \(refreshIntervalName). The fit reads the last half hour and ignores anything older than fifteen minutes, so readings this far apart never make three inside the window. Set it to 5 minutes or less in General.")
                    .font(.system(size: Tokens.Ramp.caption, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Ink.attention)
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
                // `Ink.muted` rather than `.secondary`, here and at the three
                // other quiet runs in this pane. The caption ink is a named
                // pair now, measured against the ground it is drawn on in both
                // appearances; the system's secondary label is whatever alpha
                // AppKit happens to be applying this release, and it lands one
                // ratio in the panel and another in this form.
                Text(center.rules.isEnabled
                     ? "Nothing has crossed a level yet."
                     : "Alerts are off, so there is nothing here.")
                    .font(.system(size: Tokens.Ramp.caption, weight: .regular))
                    .foregroundStyle(Tokens.Ink.muted)
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

/// The widths the log rows share, named once rather than written into each:
/// five rows whose right edges are three points apart read as a rendering fault.
private enum AlertColumn {
    /// The elapsed-time rail at a log row's trailing edge.
    ///
    /// Seven cells at `Ramp.caption`, which is `23h 59m` — the widest reading
    /// `Countdown.short` produces, because the moment it starts counting days it
    /// gets shorter again (`9d 23h`). Reserved rather than measured, like every
    /// other rail in the app: an alert ageing from `59m` into `1h 2m` gains a
    /// character and must not move the column it is in. A session left open long
    /// enough to read `100d 5h` overflows the rail instead of widening it, which
    /// is what reserving one is for.
    static let age = Tokens.figureWidth(Tokens.Ramp.caption, digits: 7)
}

/// One alert the policy produced: what it said, when, and whether macOS took it.
///
/// Laid out like `SpendRow` in the Budget pane — a symbol in the logo column,
/// then a title over its detail, then the row's figure trailing in a reserved
/// rail — because the three are the same kind of row and this window has one
/// shape for that.
///
/// Every line in it is held at `Tokens.lineBox`, so the row's height is
/// structural rather than a function of what a provider happens to call its
/// window. Five of these sit in a scrolling form under four other sections, and
/// a row that grew with its text would move the footers under it depending on
/// which services warned.
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
                // window starts its text at one x instead of several. Square and
                // centred rather than merely wide enough, because the two glyphs
                // that go in it are different sizes — `bell.slash` carries a
                // stroke across it and draws taller and wider than `bell` — and a
                // slot that only pins the width lets the mark that means bad news
                // sit a point off the axis the good one sits on.
                .frame(width: Tokens.Control.settingsLogo,
                       height: Tokens.Control.settingsLogo)

            VStack(alignment: .leading, spacing: Tokens.Space.hairline) {
                // A run with words in it, so SF Pro with tabular digits rather
                // than the figure face: "Claude at 92%" is a sentence that
                // happens to end in a number. The figure it ends in is the
                // reading the alert fired on, and it is the title that carries
                // it — the body underneath carries the window and its reset.
                //
                // Left on the label colour rather than taken to `Ink.body`.
                // That ink is the panel's, where we own the ground and the
                // whole column of text; this line sits in a `Form` between
                // toggle and `LabeledContent` labels the system draws, and one
                // custom row title a shade off the labels above and below it is
                // the mismatch, not the fix.
                //
                // `titleWeight`, which is the weight this line has always drawn:
                // `emphasisWeight` was a second name for the same `.medium` and
                // is gone. The app has two weights now — this one for the thing a
                // row is about, regular for everything around it — and a name for
                // a weight that resolved to another name is how they drift.
                Text(alert.title)
                    .font(.system(size: Tokens.Ramp.title, weight: Tokens.Ramp.titleWeight))
                    .monospacedDigit()
                    .lineLimit(1)
                    .frame(height: Tokens.lineBox(Tokens.Ramp.title), alignment: .leading)

                // Held to its line rather than allowed a second one. It was
                // wrapping so as not to lose the reading, but the reading is in
                // the title: what a second line actually bought was a row whose
                // height depended on how long a provider's window label is, and
                // the whole sentence is in the row's tooltip either way.
                Text(alert.body)
                    .font(.system(size: Tokens.Ramp.caption, weight: .regular))
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Ink.muted)
                    .lineLimit(1)
                    .frame(height: Tokens.lineBox(Tokens.Ramp.caption), alignment: .leading)

                // On every row, including the happy one: the question this list
                // exists to answer is whether alerts are landing, and a row that
                // says nothing when they are leaves the reader to infer it from
                // the shape of an icon.
                Text(delivered ? "delivered" : "macOS didn't show it")
                    .font(.system(size: Tokens.Ramp.caption, weight: .regular))
                    .foregroundStyle(delivered ? Tokens.Ink.idle : Tokens.Ink.attention)
                    .lineLimit(1)
                    .frame(height: Tokens.lineBox(Tokens.Ramp.caption), alignment: .leading)
            }

            Spacer(minLength: Tokens.Space.gutter)

            // The row's figure, in the one rail this pane reserves. Digits and
            // the unit letters attached to them and nothing else, so it is the
            // figure face — which is also why the "ago" it used to carry is
            // gone: a word in the rail would be a word in SF Mono, and the
            // column it sits in beside a log of past events says it anyway.
            // Regular, not the weight a figure takes. It reads as a figure and it
            // is set in the figure face, but what it reports is a countdown — how
            // long ago, the same run `Countdown.short` writes under a bar — and a
            // countdown is context. The row's subject is the sentence to its left.
            Text(age)
                .font(.system(size: Tokens.Ramp.caption,
                              weight: .regular,
                              design: Tokens.Ramp.figureDesign))
                .foregroundStyle(Tokens.Ink.muted)
                .lineLimit(1)
                .frame(width: AlertColumn.age, alignment: .trailing)
        }
        .padding(.vertical, Tokens.Space.tight)
        .help(detail)
    }

    /// What holding the row to three lines gives up: the body in full, and the
    /// instant itself rather than the distance back to it. The same trade the
    /// History pane makes on a day row, where the tenth of a percent the columns
    /// round away survives in the tooltip.
    private var detail: String {
        "\(alert.body) · \(alert.at.formatted(date: .abbreviated, time: .shortened))"
    }

    /// The panel's own countdown, run backwards: `Countdown.short` measures from
    /// `from` to `until`, so an elapsed time is those two swapped. A second
    /// formatter here would be a second set of rounding rules for the "3h 12m"
    /// the dropdown is already showing.
    ///
    /// `0s` where the countdown answers nothing, which is an alert that fired
    /// inside this second: it refuses a zero or negative interval, and "just now"
    /// is two words that cannot go in a figure rail.
    private var age: String {
        Countdown.short(until: Date(), from: alert.at) ?? "0s"
    }
}

/// A labelled percentage with a stepper. Set like the Appearance pane's own
/// steppers and sliders — caption type, the figure face, trailing in one width —
/// because "80%" here and "62%" there are the same kind of answer to an eye
/// running down the settings window.
///
/// Digits and a per-cent sign and nothing else, which is the rule for which face
/// a run takes: this is SF Mono, in the reserved rail `Control.readoutWidth`
/// names. It was SF Pro with tabular digits, which is the treatment for a run
/// with a word in it.
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
                    // The tabular request stays alongside the design token, for
                    // the reason the Appearance pane's readouts keep it: it costs
                    // nothing and does not depend on `figureDesign` staying
                    // monospaced.
                    // Regular, though it is a figure: it sits inches from a
                    // system `LabeledContent` label and a stepper's own glyphs,
                    // and a readout drawn heavier than the label naming it is the
                    // wrong thing emphasised in a settings row.
                    .font(.system(size: Tokens.Ramp.caption,
                                  weight: .regular,
                                  design: Tokens.Ramp.figureDesign))
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Ink.muted)
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
                        .font(.system(size: Tokens.Ramp.caption, weight: .regular))
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
