import Foundation

/// What a budget says about a spend figure, once the two have been checked
/// against each other.
///
/// Only ever produced by `BudgetPolicy.status`, which returns `nil` rather than
/// a zeroed one when the comparison cannot honestly be made. Holding one of
/// these therefore means the question was answerable.
public struct BudgetStatus: Equatable, Sendable {
    /// Spent over budgeted. Not clamped at 1: going over is the thing a budget
    /// was set to find out about, and a meter that stops at full hides how far
    /// past it went. Clamped at 0 below, because a month in credit has no fill
    /// to draw and `remainingMinor` is where that fact lives.
    public let fraction: Double
    /// Budget minus spend, in the same minor units as both. Negative when over,
    /// so the caller can print the overspend without doing the subtraction
    /// again and getting a different answer.
    public let remainingMinor: Int
    /// Strictly over. Spending exactly the budget has not exceeded it.
    public let isOver: Bool
    /// Whether the spend behind this is arithmetic this app did rather than a
    /// figure a provider billed — `SpendReport.Confidence.estimated`. An answer
    /// resting on an estimate has to say so, or the user reads a guess as an
    /// invoice.
    public let includesEstimates: Bool

    /// Public so a test can state the expected answer directly, rather than
    /// working backwards from a report and a budget that produce it.
    public init(fraction: Double, remainingMinor: Int, isOver: Bool, includesEstimates: Bool) {
        self.fraction = fraction
        self.remainingMinor = remainingMinor
        self.isOver = isOver
        self.includesEstimates = includesEstimates
    }
}

/// What a budget means, as pure functions.
///
/// Kept apart from `BudgetStore` and from whatever draws the numbers, for the
/// reason the forecast and the history query are kept apart from theirs:
/// totalling, the refusals, and deciding which alert level a month has just
/// walked through are the parts that can be quietly wrong, and none of them
/// need a clock, a defaults key or a network call to be asserted against — so
/// none of them are allowed to acquire one.
///
/// It reads six stored properties and nothing else: a report's `amountMinor`,
/// `currency`, `exponent` and `confidence`, and a budget's `amountMinor` and
/// `currency`. How spend is fetched and where a budget is kept are out of reach
/// of the arithmetic by construction.
///
/// It does not decide *which* reports belong together. Adding a `.month` figure
/// to a `.lifetime` one is as much a fiction as adding two currencies, but the
/// period a total covers is the caller's question; this adds what it is handed.
public enum BudgetPolicy {

    // MARK: - Totalling

    /// The reports billed in `currency`, added up, and the other currencies
    /// found among them.
    ///
    /// Two currencies are never added together. There is no exchange rate in
    /// this app and there is not going to be one — a rate means a network call,
    /// a cache, and a total that moves while the user is reading it — so a rate
    /// here would be invented, and a budget measured against an invented number
    /// is fiction. The sum covers what it can and `skipped` names the rest, so
    /// the pane can say out loud that this is not the whole month rather than
    /// under-reporting it in silence.
    ///
    /// `skipped` holds the distinct currency codes that were left out, sorted.
    /// Currency codes rather than services, because a `SpendReport` names no
    /// service — and sorted rather than in arrival order, because the reports
    /// come off a refresh that does not promise one and a sentence that
    /// reshuffles between polls reads as a bug.
    ///
    /// Codes are matched after trimming and upper-casing. Both types normalise
    /// their own on the way in, but `Budget.currency` is a `var` and can be
    /// assigned after that, so the comparison does not assume it.
    ///
    /// An empty `currency` matches nothing rather than everything: a caller
    /// that has not settled on one yet gets a total of zero and the full list,
    /// which is the truth, instead of every currency piled into one number.
    public static func total(
        _ reports: [SpendReport],
        currency: String
    ) -> (minor: Int, skipped: [String]) {
        let target = normalised(currency)
        var matching: [SpendReport] = []
        var others: Set<String> = []

        for report in reports {
            let code = normalised(report.currency)
            if !target.isEmpty, code == target {
                matching.append(report)
            } else if !code.isEmpty {
                // A report with no code at all is still left out of the sum; it
                // simply cannot be named, and a blank entry in the pane's
                // sentence would be worse than the omission. `SpendReport`
                // treats a missing currency as a parse failure, so this is a
                // corner that should never arrive.
                others.insert(code)
            }
        }

        // Minor units are only comparable at one exponent: $1.00 is 100 to a
        // provider billing in cents and 1_000_000 to one billing in micro-units,
        // and adding those raw is off by four orders of magnitude. The coarsest
        // scale present wins — it is the conventional minor unit whenever any
        // provider reports in it, and it is what a `Budget` states its own
        // amount in ("3284 is $32.84").
        guard let scale = matching.map(\.exponent).min() else {
            return (0, others.sorted())
        }

        var minor = 0
        for report in matching {
            minor = adding(minor, rescale(report.amountMinor, from: report.exponent, to: scale))
        }
        return (minor, others.sorted())
    }

    // MARK: - Status

    /// What the budget says about this spend, or `nil` when it is not entitled
    /// to say anything.
    ///
    /// `nil` in four cases, every one of them "there is no comparison to make"
    /// rather than "the comparison came out at zero" — the same distinction the
    /// meter keeps between a service that reports no quota and one sitting at
    /// 0%, and for the same reason:
    ///
    /// - no budget,
    /// - no spend reported yet,
    /// - a budget of zero or less, which is a cleared field rather than a limit
    ///   of nothing, and which nothing can be taken as a fraction of anyway,
    /// - a budget and a spend in different currencies. Comparing them needs the
    ///   rate `total` refuses to invent, and an answer in the wrong currency is
    ///   worse than no answer, because it looks like one.
    ///
    /// The two amounts are compared as they are stored. A `Budget` carries no
    /// exponent, so it is taken to be stated in the same minor units as the
    /// report it is measured against — which is the contract `total` already
    /// works to when it carries its sum at the coarsest scale it was given.
    public static func status(spend: SpendReport?, budget: Budget?) -> BudgetStatus? {
        guard let spend, let budget, budget.amountMinor > 0 else { return nil }

        // `Budget` already refuses an empty code, so this only catches one
        // assigned onto the `var` afterwards. A budget denominated in nothing
        // matches nothing, including a report that is also denominated in
        // nothing.
        let code = normalised(budget.currency)
        guard !code.isEmpty, normalised(spend.currency) == code else { return nil }

        return BudgetStatus(
            fraction: max(0, Double(spend.amountMinor) / Double(budget.amountMinor)),
            remainingMinor: subtracting(budget.amountMinor, spend.amountMinor),
            isOver: spend.amountMinor > budget.amountMinor,
            includesEstimates: spend.confidence == .estimated
        )
    }

    // MARK: - Crossings

    /// The levels this reading has just walked through, ascending.
    ///
    /// Levels are fractions of the budget — `Budget.alertsAt` — and are not
    /// clamped at 1 here. A budget is a line you can keep walking past, unlike
    /// a usage cap, so this is not the place that decides a level above the
    /// budget cannot exist. Levels at or below zero are dropped: there is no
    /// crossing of a line spending has always been on the far side of.
    ///
    /// Half-open at the bottom, closed at the top: a level counts as crossed
    /// when `previous < level <= current`. So a reading landing exactly on a
    /// level fires once, and the next reading in the same place does not fire
    /// again. That is the whole hysteresis — the caller keeps `current` and
    /// hands it back as `previous`, and an edge cannot be found twice.
    ///
    /// Empty on a first observation. `previous` of `nil` means the app has not
    /// watched this budget before, and announcing every level below wherever
    /// the month already stands would be reporting crossings nobody witnessed.
    /// `ThresholdPolicy` seeds without firing for the same reason: an alert the
    /// user knows to be stale teaches them to ignore the next one, which is the
    /// one that would have helped.
    ///
    /// A spend that falls — a refund, or a new billing period — yields no
    /// crossings by construction, so nothing here has to special-case it.
    public static func crossings(
        previous: Double?,
        current: Double,
        levels: [Double]
    ) -> [Double] {
        guard let previous, previous.isFinite, current.isFinite else { return [] }

        var out: [Double] = []
        for level in levels
        where level.isFinite && level > 0 && level > previous && level <= current {
            // Linear, because an alert list is at most four long. A `Set` would
            // buy nothing here and would file two spellings of the same number
            // apart; `Budget` rounds them to a basis point before this sees
            // them, and this stays correct for callers that do not.
            if !out.contains(level) { out.append(level) }
        }
        return out.sorted()
    }

    // MARK: - Arithmetic

    /// Compared, never shown, so it is folded to one shape first.
    private static func normalised(_ code: String) -> String {
        code.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    }

    /// `amount` restated at a coarser exponent.
    ///
    /// Rounded half away from zero, which costs under one minor unit per report
    /// — the rounding any invoice does — and is the only way a micro-billed
    /// figure joins a total kept in cents at all. Dropping the report instead
    /// would lose whole dollars to avoid losing a fraction of a cent, and it
    /// would have to be named in `skipped` under the currency it was actually
    /// in, which would then read as a currency the total had refused.
    ///
    /// Only ever called with `to` no greater than `from`, so it divides and
    /// cannot overflow.
    private static func rescale(_ amount: Int, from: Int, to: Int) -> Int {
        guard from > to else { return amount }

        var divisor = 1
        // `SpendReport` clamps its exponent to 0...9, so this runs at most nine
        // times; the ceiling is only here so a report built some other way
        // cannot overflow the divisor itself. 10^18 is the last power that fits.
        for _ in 0..<min(from - to, 18) { divisor *= 10 }

        let quotient = amount / divisor
        let remainder = amount % divisor
        // `remainder` takes the sign of `amount` and is smaller than `divisor`
        // in magnitude, so neither the doubling nor the `abs` can overflow.
        guard abs(remainder) * 2 >= divisor else { return quotient }
        return amount < 0 ? quotient - 1 : quotient + 1
    }

    /// Saturating. `+` traps on overflow, and one provider handing back a
    /// nonsense amount would otherwise take the whole app down over a number
    /// nobody could spend; an absurd total is a bug report, a crash is an
    /// uninstall.
    private static func adding(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflowed) = lhs.addingReportingOverflow(rhs)
        guard overflowed else { return sum }
        return rhs > 0 ? .max : .min
    }

    /// Saturating, for the same reason as `adding`.
    private static func subtracting(_ lhs: Int, _ rhs: Int) -> Int {
        let (difference, overflowed) = lhs.subtractingReportingOverflow(rhs)
        guard overflowed else { return difference }
        return rhs > 0 ? .min : .max
    }
}
