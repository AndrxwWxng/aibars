import Foundation
import SwiftUI

// ---------------------------------------------------------------------------
// What this file needs from the spend model behind it, written down because it
// is the only contract between them and nothing here may widen it.
//
// `BudgetStore` (@MainActor, ObservableObject, `shared`):
//     budgets: [String: Budget]                 keyed by serviceID, settable
//     static let overallKey: String             the key the overall budget lives under
//     func budget(for: String) -> Budget?
//     func setBudget(_: Budget?, for: String)
//
// `Budget`: `amountMinor`, `currency`, `alertsAt`, `defaultCurrency`,
//     `defaultAlerts`, and the cleaning initialiser. Amounts are in the minor
//     unit of `currency` — see `exponent(for:)` below for which minor unit that
//     is taken to be.
//
// `BudgetPolicy.total(_:currency:)` adds what shares a currency and names what
//     it left out; `BudgetPolicy.status(spend:budget:)` returns a `BudgetStatus`
//     or `nil` when the two cannot honestly be compared. Neither the totalling
//     nor the comparison is repeated here: this pane draws their answers.
//
// `SpendReport`: `providerID`, `amountMinor`, `currency`, `exponent`, `period`,
//     `isEstimate`, `display`, and the memberwise initialiser — whose labels are
//     taken in declaration order with `providerID` first, the way `UsageData`
//     leads with the same field.
//
// `UsageData.spend: SpendReport?` — what a service said it had spent, on the
//     same snapshot as its usage, so this pane needs no fetching of its own.
//
// Fetching spend, deciding what a provider's payload means, persisting budgets
// and posting the alerts are theirs. This owns which services get a row, what
// the row says, and the four things a person can do here: set a cap, clear one,
// move the warning level, and turn the warning at the cap itself off.
// ---------------------------------------------------------------------------

/// The Spend pane of Settings: what each service says it has cost, what the
/// user capped it at, and everything together.
///
/// Only services that report a figure get a row. A budget exists to be compared
/// against something, and a cap on a service that reports nothing would sit
/// there looking like a limit while enforcing nothing — so the pane says how
/// many services report nothing rather than offering fields that cannot work.
///
/// Modeless, like every other pane in this window. Each field writes through to
/// `BudgetStore`, which persists on change; there is no save button to add and
/// nothing to cancel.
public struct BudgetPane: View {
    @ObservedObject private var store: BudgetStore
    @ObservedObject private var state: AppState
    @ObservedObject private var appearance: AppearanceSettings

    /// Stored dependencies rather than `@EnvironmentObject`, like every other
    /// pane in this window, and resolved in the init body rather than as
    /// default arguments — a default argument is evaluated at the call site and
    /// all three `shared`s are main-actor isolated, so writing them there would
    /// constrain who is allowed to build the pane.
    public init(
        store: BudgetStore? = nil,
        state: AppState? = nil,
        appearance: AppearanceSettings? = nil
    ) {
        self._store = ObservedObject(wrappedValue: store ?? BudgetStore.shared)
        self._state = ObservedObject(wrappedValue: state ?? AppState.shared)
        self._appearance = ObservedObject(wrappedValue: appearance ?? AppearanceSettings.shared)
    }

    public var body: some View {
        // Read once for the whole pane, so the service rows, the total and the
        // note about what was left out cannot each be describing a different
        // refresh.
        let lines = self.lines
        // And decided once, for the same reason: the service rows and the total
        // are one column of amounts and cannot be reserving two different widths.
        let qualifier = qualifierRail(lines)

        Form {
            servicesSection(lines, qualifier: qualifier)
            overallSection(lines, qualifier: qualifier)
            alertsSection
        }
        .formStyle(.grouped)
    }

    /// The width the estimate qualifier is held in, for every row in the pane or
    /// for none of it.
    ///
    /// Decided here rather than per row, the way the panel computes its headline
    /// rail once and hands the same value to every row it has: a lane that
    /// appeared only on the rows that needed it would leave a billed amount and an
    /// estimated one ending on two different x, and the amounts are the column
    /// being scanned. Zero when nothing reported an estimate, so a pane of
    /// invoices spends no width saying so.
    private func qualifierRail(_ lines: [Line]) -> CGFloat {
        lines.contains { $0.reports.contains(where: \.isEstimate) }
            ? SpendColumn.qualifier
            : 0
    }

    // MARK: - What the services reported

    /// One service, everything its accounts reported, and what it is called.
    ///
    /// Grouped by `serviceID` and not by provider id, because that is how
    /// budgets are kept: two Claude accounts are one subscription as far as the
    /// person paying is concerned.
    private struct Line: Identifiable {
        let serviceID: String
        let name: String
        let accent: Color
        /// In the order the providers are listed, so a row's wording does not
        /// reshuffle between refreshes.
        let reports: [SpendReport]

        var id: String { serviceID }
    }

    /// Every service with a spend figure, plus every service with a budget set.
    ///
    /// The second half matters: a service can stop reporting — signed out,
    /// removed, or answering an error this refresh — and a budget the user can
    /// no longer see is a budget they cannot clear.
    private var lines: [Line] {
        var order: [String] = []
        var reports: [String: [SpendReport]] = [:]
        var names: [String: (name: String, accent: Color)] = [:]

        for provider in state.providers {
            let service = provider.serviceID
            if names[service] == nil {
                names[service] = (provider.displayName, provider.accentColor)
            }
            guard case .success(let data) = state.snapshots[provider.id],
                  let spend = data.spend else { continue }
            if reports[service] == nil {
                reports[service] = []
                order.append(service)
            }
            reports[service]?.append(spend)
        }

        // A budget with nothing behind it still gets a row, at the end, so it
        // can be read and cleared. Sorted, because a dictionary has no order and
        // a list that reshuffles on every redraw is unusable.
        for service in store.budgets.keys.sorted()
        where service != BudgetStore.overallKey && reports[service] == nil {
            order.append(service)
        }

        return order.map { service in
            Line(
                serviceID: service,
                // Named by the id when the provider is gone. Ugly, and true:
                // inventing a display name for a service that is no longer
                // there would be worse.
                name: names[service]?.name ?? service,
                accent: names[service]?.accent ?? .secondary,
                reports: reports[service] ?? []
            )
        }
    }

    /// Services that reported nothing and have no budget. Counted rather than
    /// listed: eleven names is a paragraph, and the number is the whole point —
    /// it says the pane is short because most services do not publish a figure,
    /// not because something failed.
    private func silentServices(_ lines: [Line]) -> Int {
        let shown = Set(lines.map(\.serviceID))
        return Set(state.providers.map(\.serviceID)).subtracting(shown).count
    }

    // MARK: - Per service

    private func servicesSection(_ lines: [Line], qualifier: CGFloat) -> some View {
        let silent = silentServices(lines)

        return Section {
            if lines.isEmpty {
                Text("No service is reporting what it has cost. Most publish usage but not spend, and a cap on a figure that is never reported would warn about nothing.")
                    .font(.system(size: Tokens.Ramp.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(lines) { line in
                    row(for: line, qualifier: qualifier)
                }
                if silent > 0 {
                    Text("\(silent) other services report usage but not spend, so there is nothing here to cap.")
                        .font(.system(size: Tokens.Ramp.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } header: {
            Text("Spend")
        } footer: {
            SectionFooter("What each service says it has spent, over whatever span that service bills on. Accounts of one service are added together, because one subscription is one bill. A cap here changes nothing at the provider — it is what aibars measures against, and warns you about.")
        }
    }

    private func row(for line: Line, qualifier: CGFloat) -> some View {
        let currency = self.currency(for: line)
        let exponent = self.exponent(for: line)
        let totalled = total(line.reports.map { (line.name, $0) }, currency: currency, exponent: exponent)
        let spend = combined(line.reports, currency: currency, exponent: exponent, minor: totalled.minor)
        let budget = store.budget(for: line.serviceID)
        let status = BudgetPolicy.status(spend: spend, budget: budget)

        return SpendRow(
            serviceID: line.serviceID,
            name: line.name,
            accent: line.accent,
            amount: spend?.display,
            confidence: spend?.confidence,
            qualifierRail: qualifier,
            detail: detail(
                for: line,
                spend: spend,
                budget: budget,
                exponent: exponent,
                status: status,
                skipped: totalled.skipped
            ),
            tint: figureTint(for: status, accent: line.accent),
            isAlert: isAlert(status),
            currency: currency,
            exponent: exponent,
            budget: budget,
            // A cleared field is no budget rather than a budget of zero: those
            // are the same state, and `BudgetStore` says so by having no
            // separate delete.
            write: { minor in
                let existing = self.store.budget(for: line.serviceID)
                self.store.setBudget(minor.map {
                    Budget(
                        amountMinor: $0,
                        currency: currency,
                        // A new budget inherits the levels the pane is already
                        // showing, so the alerts section is never describing
                        // something the newest budget does not do.
                        alertsAt: existing?.alertsAt ?? self.alertLevels
                    )
                }, for: line.serviceID)
            }
        )
    }

    /// The line under a service name: the span it bills on, whether the figure
    /// is the app's own arithmetic, and what the budget makes of it.
    ///
    /// Prose, and deliberately so. The near-cap channels that survive greyscale
    /// in the panel are position, shape and weight; a settings row has no meter
    /// to carry the first two, so the words do it — "over by $12.30" reads the
    /// same in every colour ramp and to every eye.
    private func detail(
        for line: Line,
        spend: SpendReport?,
        budget: Budget?,
        exponent: Int,
        status: BudgetStatus?,
        skipped: [String]
    ) -> String {
        var parts: [String] = []

        if let period = line.reports.first?.period {
            parts.append(period.title)
        }
        if spend?.isEstimate == true {
            // The qualifier a measured figure does not carry. Never dropped for
            // brevity: a priced-up token count read as an invoice is the one
            // way this pane can mislead.
            //
            // Said twice on purpose — the figure carries "est." in its own lane
            // as well. That one is the glance and this one is the sentence, and a
            // fact this pane must not let a reader miss gets two channels, the
            // way near-cap gets four in the panel.
            parts.append("estimated")
        }
        if line.reports.isEmpty {
            parts.append("nothing reported")
        }

        if let status, let budget {
            parts.append(Self.verdict(status, budget: budget, exponent: exponent))
        } else if let budget, budget.amountMinor > 0, let spend,
                  budget.currency != spend.currency {
            // The one refusal worth spelling out on the row itself. Nothing here
            // converts between currencies, so a cap in the wrong one is not a
            // cap that is nearly right — it is not compared at all.
            parts.append("capped in \(budget.currency), billed in \(spend.currency), so not compared")
        } else if budget == nil {
            parts.append("no cap set")
        }

        if !skipped.isEmpty {
            parts.append("\(skipped.count) account\(skipped.count == 1 ? "" : "s") left out")
        }
        return parts.joined(separator: " · ")
    }

    /// "66% of $50.00, $17.16 left", or the same sentence the other way round.
    ///
    /// One wording for the service rows and the overall row, so a total that has
    /// gone over says what a service that has gone over says. Static, because it
    /// reads nothing but its arguments.
    private static func verdict(_ status: BudgetStatus, budget: Budget, exponent: Int) -> String {
        let cap = Money.text(minor: budget.amountMinor, currency: budget.currency, exponent: exponent)
        let fraction = status.fraction.formatted(.percent.precision(.fractionLength(0)))
        // `remainingMinor` is negative past the cap, and the sign is already
        // carried by the word: "over by -$12.30" is not a sentence.
        let rest = Money.text(
            minor: abs(status.remainingMinor),
            currency: budget.currency,
            exponent: exponent
        )
        return status.isOver
            ? "\(fraction) of \(cap), over by \(rest)"
            : "\(fraction) of \(cap), \(rest) left"
    }

    // MARK: - Everything together

    private func overallSection(_ lines: [Line], qualifier: CGFloat) -> some View {
        let reports = lines.flatMap(\.reports)
        let currency = overallCurrency(reports)
        let exponent = overallExponent(reports, currency: currency)
        let totalled = total(lines.flatMap { line in line.reports.map { (line.name, $0) } },
                             currency: currency, exponent: exponent)
        let spend = combined(reports, currency: currency, exponent: exponent, minor: totalled.minor)
        let budget = store.budget(for: BudgetStore.overallKey)
        let status = BudgetPolicy.status(spend: spend, budget: budget)

        return Section {
            if reports.isEmpty {
                Text("Nothing to add up yet.")
                    .font(.system(size: Tokens.Ramp.caption))
                    .foregroundStyle(.secondary)
            } else {
                SpendRow(
                    serviceID: nil,
                    name: "Everything",
                    accent: .secondary,
                    amount: spend?.display,
                    confidence: spend?.confidence,
                    qualifierRail: qualifier,
                    detail: overallDetail(
                        status: status,
                        budget: budget,
                        spend: spend,
                        exponent: exponent
                    ),
                    tint: figureTint(for: status, accent: .secondary),
                    isAlert: isAlert(status),
                    currency: currency,
                    exponent: exponent,
                    budget: budget,
                    write: { minor in
                        let existing = self.store.budget(for: BudgetStore.overallKey)
                        self.store.setBudget(minor.map {
                            Budget(
                                amountMinor: $0,
                                currency: currency,
                                alertsAt: existing?.alertsAt ?? self.alertLevels
                            )
                        }, for: BudgetStore.overallKey)
                    }
                )

                if let note = skippedNote(totalled.skipped, currency: currency) {
                    SpendCallout(note)
                }
            }
        } header: {
            Text("Everything together")
        } footer: {
            SectionFooter("One currency at a time. There is no exchange rate in aibars and there is not going to be one — a rate means a network call, a cache, and a total that moves while you are reading it — so anything billed in another currency is named above rather than folded in at a number nobody can check.")
        }
    }

    /// The overall row says which currency it is a total of, because that is the
    /// one thing about it a reader cannot infer from the rows above — those are
    /// a mixture, and this is not.
    ///
    /// It says nothing about a period. The services under it bill on their own
    /// spans and a sum of a rolling day and a calendar month covers neither;
    /// naming one would be the pane inventing a window nobody resets on.
    private func overallDetail(
        status: BudgetStatus?,
        budget: Budget?,
        spend: SpendReport?,
        exponent: Int
    ) -> String {
        let code = spend?.currency ?? budget?.currency ?? Budget.defaultCurrency
        var parts = ["everything billed in \(code)"]
        if spend?.isEstimate == true {
            // Weaker than a service row's "estimated", and deliberately: one
            // priced-up token count in a total of six invoices makes the total
            // partly a guess, not a guess.
            parts.append("part estimated")
        }
        if let status, let budget {
            parts.append(Self.verdict(status, budget: budget, exponent: exponent))
        } else if let budget, budget.currency != code {
            parts.append("capped in \(budget.currency), so not compared")
        } else if budget == nil {
            parts.append("no cap set")
        }
        return parts.joined(separator: " · ")
    }

    /// Which accounts are not in the total, by the names they are shown under
    /// elsewhere in this window.
    ///
    /// Named rather than counted, unlike the silent services: a total that is
    /// missing something is only trustworthy if the reader can see what.
    private func skippedNote(_ skipped: [String], currency: String) -> String? {
        guard !skipped.isEmpty else { return nil }
        var seen: Set<String> = []
        let names = skipped.compactMap { id -> String? in
            let name = state.provider(for: id)?.displayName ?? id
            return seen.insert(name).inserted ? name : nil
        }
        guard !names.isEmpty else { return nil }
        let list = names.joined(separator: ", ")
        return names.count == 1
            ? "\(list) does not bill in \(currency), so it is not in this total."
            : "\(list) do not bill in \(currency), so they are not in this total."
    }

    /// The currency the total is stated in: whatever the overall cap was set in,
    /// and otherwise the one the most accounts bill in.
    ///
    /// The cap wins because a total that changed currency underneath it would
    /// silently stop being compared to it, and the user set the cap. It wins
    /// only while something is actually billed in it, though — a cap in a
    /// currency nothing reports would otherwise leave the total permanently
    /// empty with every account named as skipped, which reads as a fault rather
    /// than as a cap in the wrong currency.
    private func overallCurrency(_ reports: [SpendReport]) -> String {
        if let budget = store.budget(for: BudgetStore.overallKey),
           reports.contains(where: { $0.currency == budget.currency }) {
            return budget.currency
        }
        var counts: [String: Int] = [:]
        for report in reports {
            counts[report.currency, default: 0] += 1
        }
        // Most accounts wins; a tie goes to the code that sorts first. Ties have
        // to be broken by something stable, or a dictionary's order picks a
        // different winner on each redraw and the total changes currency while
        // nobody is touching it.
        return counts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .first?.key
            ?? Budget.defaultCurrency
    }

    private func overallExponent(_ reports: [SpendReport], currency: String) -> Int {
        reports.first { $0.currency == currency }?.exponent ?? Self.defaultExponent
    }

    // MARK: - Money, in the unit the service reports in

    /// The exponent a budget for this service is taken to be stated in.
    ///
    /// `Budget` carries an amount and a currency and no exponent, and
    /// `BudgetPolicy` compares the two amounts as plain integers — so a cap only
    /// means anything if it is stored in the same minor unit the service
    /// reports in. A provider billing in micro-units gets a cap in micro-units;
    /// everything else gets cents. Nothing is converted anywhere, which is why
    /// this is read off the report rather than off a table of currencies.
    private func exponent(for line: Line) -> Int {
        line.reports.first?.exponent ?? Self.defaultExponent
    }

    /// What a budget is stated in when no report has arrived to say otherwise.
    /// Two, which is `SpendReport`'s own default and the minor unit of every
    /// currency any of these services bills in.
    private static let defaultExponent = 2

    /// The currency the row is stated in.
    ///
    /// What the service bills in, and the cap's own currency only when nothing
    /// was reported. The report wins because it is a fact and the cap is a
    /// preference: reading the row in the cap's currency would filter the
    /// service's own figure out of its own row, and the row would show a dash
    /// over a bill that had very much arrived.
    private func currency(for line: Line) -> String {
        line.reports.first?.currency
            ?? store.budget(for: line.serviceID)?.currency
            ?? Budget.defaultCurrency
    }

    /// `BudgetPolicy.total` with one refusal added: reports at different
    /// exponents are not added either.
    ///
    /// The policy matches on currency alone, which is right for the case it was
    /// written for and one digit out by a factor of ten thousand for a provider
    /// billing the same currency in micro-units. Unlike quantities are named in
    /// `skipped` alongside the wrong-currency ones rather than summed — this
    /// pane refuses the arithmetic, it does not invent a conversion.
    ///
    /// Takes name/report pairs rather than reports alone because a `SpendReport`
    /// does not carry who filed it — it is a figure, not a row — and naming what
    /// was refused is the whole point of `skipped`.
    private func total(
        _ reports: [(name: String, report: SpendReport)],
        currency: String,
        exponent: Int
    ) -> (minor: Int, skipped: [String]) {
        var matched: [SpendReport] = []
        var skipped: [String] = []
        for entry in reports {
            if entry.report.exponent == exponent {
                matched.append(entry.report)
            } else {
                skipped.append(entry.name)
            }
        }
        let totalled = BudgetPolicy.total(matched, currency: currency)
        return (totalled.minor, skipped + totalled.skipped)
    }

    /// The accounts that were added up, as one report, so the row has something
    /// to print and `BudgetPolicy.status` has something to compare.
    ///
    /// `period` and `resetDate` are what a single account's report carries and a
    /// sum of several cannot: `status` reads neither, and the row prints the
    /// period off the reports themselves. The period here is the first one, and
    /// it is never shown.
    private func combined(
        _ reports: [SpendReport],
        currency: String,
        exponent: Int,
        minor: Int
    ) -> SpendReport? {
        let matched = reports.filter { $0.exponent == exponent && $0.currency == currency }
        guard let first = matched.first else { return nil }
        return SpendReport(
            amountMinor: minor,
            currency: currency,
            exponent: exponent,
            limitMinor: nil,
            period: first.period,
            // One estimated account makes the sum estimated. A total that is
            // three quarters invoice and one quarter guess is a guess.
            confidence: matched.contains(where: \.isEstimate) ? .estimated : .measured,
            resetDate: nil
        )
    }

    /// The figure's ink, from the same ramp the panel's figures use, so a budget
    /// that is nearly gone is the colour a window nearly gone would be.
    ///
    /// `figureTint` and not `tint`: below the caution level the digits are neutral,
    /// which is what makes colour arriving on a number the event rather than the
    /// background. A row with nothing to compare against is neutral for the same
    /// reason — it is not a reading, and the ramp's resting colour on it would say
    /// it was sitting at zero of something.
    private func figureTint(for status: BudgetStatus?, accent: Color) -> Color {
        guard let status else { return .primary }
        // The ramp is defined over 0…1 and a budget is a line you can keep
        // walking past. Past it the ramp has nothing further to say, so the
        // clamp costs nothing and the words carry the overspend.
        return appearance.figureTint(for: min(status.fraction, 1), providerAccent: accent)
    }

    /// Whether the figure takes the heavier weight.
    ///
    /// The same line the colour changes at, and not the cap: weight is the channel
    /// that survives a greyscale screenshot, and a row whose figure went red at
    /// the warning level but only got heavier at the cap would have a band that
    /// colour alone carries.
    private func isAlert(_ status: BudgetStatus?) -> Bool {
        guard let status else { return false }
        return status.fraction >= appearance.warningThreshold
    }

    // MARK: - The levels

    /// One set of levels for every budget.
    ///
    /// `Budget` keeps its own, because the policy evaluates each budget on its
    /// own terms, but a pane that asked "and at what percent for Claude?" eleven
    /// times over would be a pane nobody finishes. Every write here goes to
    /// every budget, and the values shown are the overall budget's — or, with no
    /// overall budget, the first service budget in id order, so the pane cannot
    /// show a different answer on each redraw.
    private var referenceBudget: Budget? {
        store.budget(for: BudgetStore.overallKey)
            ?? store.budgets.min { $0.key < $1.key }?.value
    }

    private var alertLevels: [Double] {
        referenceBudget?.alertsAt ?? Budget.defaultAlerts
    }

    /// The warning below the cap, as whole percent. The largest stored level
    /// short of the cap itself; the shipped default when there is none, because
    /// a stepper has to start somewhere and it starts where a fresh budget does.
    private var earlyLevel: Binding<Int> {
        Binding(
            get: {
                let early = self.alertLevels.last { $0 < 1 }
                    ?? Budget.defaultAlerts.first { $0 < 1 }
                    ?? 0.80
                return Int((early * 100).rounded())
            },
            set: { self.writeLevels(early: $0, atCap: self.warnsAtCap.wrappedValue) }
        )
    }

    private var warnsAtCap: Binding<Bool> {
        Binding(
            get: { self.alertLevels.contains { $0 >= 1 } },
            set: { self.writeLevels(early: self.earlyLevel.wrappedValue, atCap: $0) }
        )
    }

    /// Written to every budget in one assignment rather than one at a time:
    /// `BudgetStore.budgets` persists in its own observer, and eleven writes
    /// would be eleven trips to disk for one click of a stepper.
    private func writeLevels(early: Int, atCap: Bool) {
        var levels = [Double(early) / 100]
        if atCap { levels.append(1) }
        store.budgets = store.budgets.mapValues {
            Budget(amountMinor: $0.amountMinor, currency: $0.currency, alertsAt: levels)
        }
    }

    private var alertsSection: some View {
        Section {
            LabeledContent("Warn me at") {
                // Five at a time, like the Alerts pane's thresholds: a spend
                // warning at 83% rather than 85% is a distinction nobody holds
                // an opinion about, and single steps make the walk from 25 to 95
                // seventy clicks long.
                Stepper(value: earlyLevel, in: 25...95, step: 5) {
                    Text(Double(earlyLevel.wrappedValue) / 100, format: .percent.precision(.fractionLength(0)))
                        .font(.system(
                            size: Tokens.Ramp.caption,
                            weight: .regular,
                            design: Tokens.Ramp.figureDesign
                        ))
                        .foregroundStyle(.secondary)
                        // A readout wide enough to wrap would take the row's
                        // height with it, and the row below would shift half a
                        // line as the value crossed 100.
                        .lineLimit(1)
                        .frame(width: Tokens.Control.readoutWidth, alignment: .trailing)
                }
            }

            Toggle("Warn me again at the cap itself", isOn: warnsAtCap)
        } header: {
            Text("When to warn")
        } footer: {
            SectionFooter("Fractions of each cap, and the same two for every service — a spend warning is the same sentence whichever bill it is about. Each level fires as it is crossed and not again, and nothing fires the first time aibars sees a budget, because setting one while already over it is not a crossing it watched happen.")
        }
        // Nothing to set levels on. Dimmed rather than hidden, so someone
        // deciding whether to set a cap can see what setting one would do.
        .disabled(store.budgets.isEmpty)
    }
}

// MARK: - Rows

/// The widths the rows in this pane share.
///
/// Named once rather than written into each, because two rows in one pane whose
/// right edges are three points apart read as a rendering fault.
private enum SpendColumn {
    /// The one rail money is allowed: eight cells, `$1234.56`. Every money
    /// figure in the application is this wide, which is why it is
    /// `Tokens.moneyWidth` and not eleven cells counted out here for the sake of
    /// "CN¥1,234.56" — a bill past four figures overflows a rail three other
    /// rows share rather than widening it, and the amount is set with a
    /// `minimumScaleFactor` below so it gives up size before it gives up digits.
    static let amount = Tokens.moneyWidth(Tokens.Ramp.title)
    /// The lane the estimate qualifier sits in, *ahead* of the amount rail.
    ///
    /// Ahead, and not after it as the panel's `SpendFigure` has it: that one
    /// leads a caption line and can let the word trail the rail, while these
    /// amounts are a column with the cap fields to their right. A qualifier
    /// after the rail would move an estimated row's amount left by the width of
    /// a word, and the whole point of a rail is that the digits do not move.
    /// Three cells, which holds "est." at `Ramp.title` with room rather than
    /// exactly none.
    static let qualifier = Tokens.figureWidth(Tokens.Ramp.title, digits: 3)
    /// The cap field, at the money rail as well — by construction and not by
    /// coincidence: it is the same quantity being typed rather than read, and a
    /// field wider than the figure it is compared against reads as a different
    /// kind of number.
    static let cap = amount
    /// The column the field is trailing-aligned in, at the width the Services
    /// pane holds its buttons, so the two panes end their rows on the same x.
    static let action = Tokens.Control.actionColumn
}

/// One service's spend, and the cap beside it.
///
/// Laid out like `ServiceRow` in the Services pane — a mark in the logo column,
/// then a title over its detail, then the control — because the two are the
/// same kind of row and this window has one shape for that.
private struct SpendRow: View {
    /// `nil` for the overall row, which is a sum rather than a service and has
    /// no logo to draw.
    let serviceID: String?
    let name: String
    let accent: Color
    /// Already formatted by `SpendReport`, so this row and the dropdown state
    /// one amount in one way. `nil` when nothing was reported.
    let amount: String?
    /// How much the amount is worth trusting, carried through rather than
    /// flattened into the sentence under it: an estimate is a local token count
    /// priced against a published rate card, and a row that drew it the way it
    /// draws an invoice would be lying about how much the number is worth.
    /// `nil` when there is no amount to qualify.
    let confidence: SpendReport.Confidence?
    /// The width the qualifier is held in, decided once for the whole pane so a
    /// billed row and an estimated one end their amounts on the same x. Zero
    /// when nothing in the pane is an estimate.
    let qualifierRail: CGFloat
    let detail: String
    /// Decided by the pane from the appearance settings — a row has no business
    /// holding a second opinion about what 92% of a budget looks like.
    let tint: Color
    /// At or above the warning threshold, which is where the figure takes the
    /// heavier weight. Not "past the cap": weight is one of the channels that
    /// has to survive a greyscale screenshot, so it changes where the colour
    /// changes and not one band later.
    let isAlert: Bool
    let currency: String
    let exponent: Int
    let budget: Budget?
    let write: (Int?) -> Void

    var body: some View {
        HStack(spacing: Tokens.Space.gutter) {
            if let serviceID {
                ProviderLogo(
                    providerID: serviceID,
                    fallbackName: name,
                    fallbackColor: accent,
                    size: Tokens.Control.settingsLogo
                )
            } else {
                // The column stays, so the overall row's name starts where every
                // other name in the window starts.
                Color.clear
                    .frame(width: Tokens.Control.settingsLogo, height: Tokens.Control.settingsLogo)
            }

            VStack(alignment: .leading, spacing: Tokens.Space.hairline) {
                Text(name)
                    .font(.system(size: Tokens.Ramp.title, weight: Tokens.Ramp.emphasisWeight))
                    .lineLimit(1)

                // A run with words in it, so SF Pro with tabular digits rather
                // than the figure face: "66% of $50.00, $17.16 left" is a
                // sentence that happens to contain numbers.
                Text(detail)
                    .font(.system(size: Tokens.Ramp.caption))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Tokens.Space.gutter)

            figure

            CapField(
                currency: currency,
                exponent: exponent,
                amountMinor: budget?.amountMinor,
                write: write
            )
            // Trailing in a column the width of the Services pane's buttons, so
            // the field is the money rail and the row still ends where every
            // other row in the window ends.
            .frame(minWidth: SpendColumn.action, alignment: .trailing)
        }
        .padding(.vertical, Tokens.Space.tight)
    }

    /// The row's answer: the qualifier lane, then the amount in the money rail.
    ///
    /// The amount is a pure quantity — currency symbol, digits and a point — so
    /// it is the figure face, and it keeps its two decimals, which is the one
    /// exception the app makes to dropping them: a cap of `$32` against a bill of
    /// `$32.84` is a different number.
    ///
    /// The qualifier is a word and is therefore not the figure face. It says the
    /// figure was priced up locally, and it is never dropped for brevity: a token
    /// count read as an invoice is the one way this pane can mislead.
    private var figure: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Space.snug) {
            if qualifierRail > 0 {
                // Empty rather than absent on a billed row: the lane is reserved
                // for the whole pane, and an empty `Text` keeps a baseline for
                // the row to align on where a `Color.clear` would not.
                Text(confidence == .estimated ? "est." : "")
                    .font(.system(size: Tokens.Ramp.title))
                    .foregroundStyle(Tokens.Ink.idle)
                    .lineLimit(1)
                    .frame(width: qualifierRail, alignment: .trailing)
            }
            amountText
        }
        .help(figureHelp)
    }

    /// What the amount says about itself in full, since "est." is three letters.
    ///
    /// Switched over the confidence rather than asked whether it is an estimate,
    /// so the third state has to be answered: a row that reported nothing has no
    /// account of how its figure was arrived at, and "Reported by the service" on
    /// an em dash would be the pane claiming a reading it never got.
    private var figureHelp: String {
        switch confidence {
        case .estimated:
            return "Estimated locally from token counts and published prices, not a billed figure"
        case .measured:
            return "Reported by the service"
        case nil:
            return ""
        }
    }

    /// An em dash where there is no figure, and not a zero. "Reports nothing" and
    /// "has spent nothing" are different facts, and only one of them is a reading.
    @ViewBuilder
    private var amountText: some View {
        if let amount {
            Text(amount)
                .font(.system(
                    size: Tokens.Ramp.title,
                    weight: isAlert ? Tokens.Ramp.alertWeight : Tokens.Ramp.emphasisWeight,
                    design: Tokens.Ramp.figureDesign
                ))
                .foregroundStyle(tint)
                .lineLimit(1)
                // Gives up size before it gives up digits: eight cells covers a
                // four-figure bill, and a larger one is worth overflowing for
                // rather than abbreviating.
                .minimumScaleFactor(0.8)
                .frame(width: SpendColumn.amount, alignment: .trailing)
        } else {
            Text(verbatim: "—")
                .font(.system(
                    size: Tokens.Ramp.title,
                    weight: Tokens.Ramp.emphasisWeight,
                    design: Tokens.Ramp.figureDesign
                ))
                .foregroundStyle(.tertiary)
                .frame(width: SpendColumn.amount, alignment: .trailing)
                .accessibilityLabel("No spend reported")
        }
    }
}

// MARK: - The callout

/// A note the total above it cannot honestly be read without.
///
/// A raised surface with its own edge rather than a line of coloured prose in the
/// section, because it is not a footer: it qualifies a figure, and a qualification
/// that draws like the prose under every other section is a qualification people
/// read past. Elevation here is a ground plus one stroke — the app has no shadows
/// anywhere, and nothing carrying a number is drawn on a material.
///
/// One coloured element: the glyph. The sentence itself is `.secondary`, the way
/// the browser banner's detail line is, so the ink says "attention" once.
private struct SpendCallout: View {
    let text: String

    /// The stroke steps up under increased contrast like every other edge in the
    /// app. At 0.09 over `Surface.raised` it is the first thing a low-contrast
    /// display gives up, and without it the plane change is carrying the callout
    /// on its own.
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.medium) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: Tokens.Ramp.title))
                .foregroundStyle(Tokens.Ink.attention)
                // The sentence beside it already says what the glyph says, and
                // "exclamation mark triangle" read out in front of it is noise.
                .accessibilityHidden(true)
            Text(text)
                .font(.system(size: Tokens.Ramp.caption))
                .foregroundStyle(.secondary)
                // Prose, so it wraps. A callout that cannot grow downward can
                // only ever name one account.
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(Tokens.Space.large)
        .background(Tokens.surface(Tokens.Radius.panel).fill(Tokens.Surface.raised))
        .overlay(
            Tokens.surface(Tokens.Radius.panel).strokeBorder(
                Tokens.quiet(Tokens.borderOpacity(increased: contrast == .increased)),
                lineWidth: Tokens.Control.hairline
            )
        )
    }
}

/// The cap on one row: a currency field that is empty when there is no cap.
///
/// Empty and zero are the same state here, because `BudgetStore` has no separate
/// delete and `BudgetPolicy` refuses to compare against a cap of zero. Clearing
/// the field removes the budget, which is the only way to remove one and the
/// only thing a user tries.
private struct CapField: View {
    let currency: String
    let exponent: Int
    let amountMinor: Int?
    let write: (Int?) -> Void

    /// The text as typed, not as formatted. Rewriting it from the store on
    /// every keystroke would put the caret back at the end of "5" while someone
    /// was halfway through typing "50", so the field is seeded once and then
    /// belongs to whoever is typing in it.
    @State private var text: String = ""

    var body: some View {
        TextField(text: $text, prompt: Text("No cap")) {
            Text("Cap")
        }
        .labelsHidden()
        .textFieldStyle(.roundedBorder)
        .font(.system(
            size: Tokens.Ramp.title,
            weight: .regular,
            design: Tokens.Ramp.figureDesign
        ))
        .multilineTextAlignment(.trailing)
        // The money rail, so a cap being typed is the width of the figure it is
        // measured against. A field scrolls its own text rather than truncating
        // it, so a cap past four figures still has a visible caret.
        .frame(width: SpendColumn.cap)
        .help("A spending cap in \(currency). Clear it to remove the cap.")
        .onAppear { text = Self.seed(amountMinor, exponent: exponent) }
        // Written through on every keystroke, like the account rename field in
        // the Services pane: this window has no save button, and a cap that
        // only lands when the field loses focus is a cap someone sets and then
        // watches do nothing.
        .onChange(of: text) { typed in
            self.write(Money.minor(typed, currency: self.currency, exponent: self.exponent))
        }
    }

    /// What the field starts life showing. The plain number rather than the
    /// currency-formatted one: a field you are about to type in should not open
    /// with a symbol you then have to type around, and the currency is stated in
    /// the tooltip and on the row beside it.
    private static func seed(_ minor: Int?, exponent: Int) -> String {
        guard let minor, minor > 0 else { return "" }
        return Money.decimal(minor: minor, exponent: exponent)
            .formatted(.number.precision(.fractionLength(0...min(exponent, 2))))
    }
}

// MARK: - Minor units

/// Turning an amount in minor units into something a person reads, and back.
///
/// Here rather than on `SpendReport` because a cap is not a report: it has no
/// provider, no period and no confidence, and giving the model a second
/// initialiser for the sake of formatting a number would be the tail wagging
/// the dog.
private enum Money {
    /// The amount in major units, exactly. `Decimal` and not `Double`, for the
    /// reason `SpendReport` holds minor units in the first place: `0.1 + 0.2` is
    /// not `0.3` in binary floating point, and a cap that disagrees with the
    /// figure beside it by a cent is worse than no cap at all.
    static func decimal(minor: Int, exponent: Int) -> Decimal {
        Decimal(minor) * Decimal(sign: .plus, exponent: -exponent, significand: 1)
    }

    /// A cap, formatted in the reader's locale.
    ///
    /// `exponent` is the unit the cap was stored in, which is the unit the
    /// service reports in — see `BudgetPane.exponent(for:)`. Passing it rather
    /// than assuming cents is what keeps a cap on a micro-billed service from
    /// being printed ten thousand times too large.
    ///
    /// Plain currency precision, unlike `SpendReport.display`, which keeps
    /// sub-cent digits so a $0.0043 API charge is not shown as zero. A cap is a
    /// round number somebody typed; there is no fraction of a cent in it to
    /// lose.
    static func text(minor: Int, currency: String, exponent: Int) -> String {
        decimal(minor: minor, exponent: exponent)
            .formatted(.currency(code: currency))
    }

    /// What was typed, in minor units, or `nil` for an empty or unreadable
    /// field.
    ///
    /// Parsed through a `FormatStyle` rather than `Decimal(string:)` so that a
    /// decimal comma is a decimal comma. The currency style first, because
    /// someone pasting "$50.00" back in should get fifty dollars; the plain
    /// number style second, because almost nobody types the symbol.
    static func minor(_ typed: String, currency: String, exponent: Int) -> Int? {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        let amount = (try? Decimal(trimmed, format: .currency(code: currency)))
            ?? (try? Decimal(trimmed, format: .number))
        guard let amount, amount > 0 else { return nil }

        // Clamped before it is scaled. `NSDecimalNumber.intValue` is undefined
        // past `Int`'s range, and a cap of a trillion is a typo rather than a
        // budget — refusing the digits nobody meant is cheaper than a figure
        // that comes back negative.
        var scaled = min(amount, ceiling) * pow(Decimal(10), exponent)
        var rounded = Decimal()
        NSDecimalRound(&rounded, &scaled, 0, .plain)
        return NSDecimalNumber(decimal: rounded).intValue
    }

    /// The largest cap the field accepts, in major units. Far past any
    /// subscription and far short of where scaling by a micro-unit exponent
    /// could overflow.
    private static let ceiling = Decimal(1_000_000_000)
}

// MARK: - Periods

private extension SpendReport.Period {
    /// What the row calls this span. Lower case: it sits in a run of prose after
    /// the service name rather than starting a sentence.
    var title: String {
        switch self {
        case .rollingHours(let hours): return "last \(hours)h"
        case .day:                     return "today"
        case .week:                    return "this week"
        case .month:                   return "this month"
        case .lifetime:                return "all time"
        }
    }
}
