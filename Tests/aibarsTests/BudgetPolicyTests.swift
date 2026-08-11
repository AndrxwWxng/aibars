import XCTest
@testable import aibarsCore

/// Money is the one figure in aibars a user might reconcile against a real
/// invoice, so these tests spend most of their time on the refusals rather than
/// the sums: a total that quietly folded euros into dollars, a budget compared
/// against spend in another currency, or an alert fired for a crossing nobody
/// witnessed would all read as the app being confidently wrong about a bill.
///
/// `BudgetPolicy` is pure, so there is nothing here to stub — every case is an
/// input and an answer.
final class BudgetPolicyTests: XCTestCase {

    // MARK: - Builders

    private func report(
        _ amountMinor: Int,
        _ currency: String = "USD",
        exponent: Int = 2,
        confidence: SpendReport.Confidence = .measured
    ) -> SpendReport {
        SpendReport(
            amountMinor: amountMinor,
            currency: currency,
            exponent: exponent,
            period: .month,
            confidence: confidence
        )
    }

    private func budget(_ amountMinor: Int, _ currency: String = "USD") -> Budget {
        Budget(amountMinor: amountMinor, currency: currency)
    }

    /// A caller polling one budget over time, which is the only way `crossings`
    /// is ever used: it keeps the last reading and hands it back as `previous`.
    private func walk(_ readings: [Double], levels: [Double]) -> [[Double]] {
        var previous: Double?
        return readings.map { reading in
            let fired = BudgetPolicy.crossings(previous: previous, current: reading, levels: levels)
            previous = reading
            return fired
        }
    }

    // MARK: - Totalling

    func testTwoReportsInTheSameCurrencyAddUp() {
        let total = BudgetPolicy.total([report(1234), report(2050)], currency: "USD")
        XCTAssertEqual(total.minor, 3284)
        XCTAssertEqual(total.skipped, [])
    }

    /// The whole point of the return being a pair: the euro figure is neither
    /// added nor converted nor silently dropped, it is named.
    func testAForeignReportIsNamedRatherThanConverted() {
        let total = BudgetPolicy.total(
            [report(1000), report(5000, "EUR"), report(2000)],
            currency: "USD"
        )
        XCTAssertEqual(total.minor, 3000, "the euro amount reached the dollar total")
        XCTAssertEqual(total.skipped, ["EUR"])
    }

    func testEachForeignCurrencyIsNamedOnceAndSorted() {
        let total = BudgetPolicy.total(
            [report(1, "JPY", exponent: 0), report(2, "EUR"), report(3, "EUR"), report(4)],
            currency: "USD"
        )
        XCTAssertEqual(total.minor, 4)
        XCTAssertEqual(total.skipped, ["EUR", "JPY"], "sorted, because a sentence that reshuffles between polls reads as a bug")
    }

    func testNothingReportedTotalsZeroAndNamesNothing() {
        let total = BudgetPolicy.total([], currency: "USD")
        XCTAssertEqual(total.minor, 0)
        XCTAssertEqual(total.skipped, [])
    }

    /// Zero spent is a reading. It must not come back looking like the empty
    /// case with something skipped.
    func testZeroAmountsTotalZeroWithNothingSkipped() {
        let total = BudgetPolicy.total([report(0), report(0)], currency: "USD")
        XCTAssertEqual(total.minor, 0)
        XCTAssertEqual(total.skipped, [])
    }

    func testAllForeignReportsStillTotalZeroAndNameThemselves() {
        let total = BudgetPolicy.total([report(500, "EUR"), report(700, "GBP")], currency: "USD")
        XCTAssertEqual(total.minor, 0)
        XCTAssertEqual(total.skipped, ["EUR", "GBP"])
    }

    func testCurrencyMatchingIgnoresCaseAndSurroundingSpace() {
        let total = BudgetPolicy.total([report(1234), report(2050)], currency: "  usd\n")
        XCTAssertEqual(total.minor, 3284)
        XCTAssertEqual(total.skipped, [])
    }

    /// A caller that has not settled on a currency gets the truth — nothing
    /// totalled, everything named — rather than every currency in one number.
    func testAnEmptyTargetCurrencyMatchesNothing() {
        let total = BudgetPolicy.total([report(1000), report(5000, "EUR")], currency: "   ")
        XCTAssertEqual(total.minor, 0)
        XCTAssertEqual(total.skipped, ["EUR", "USD"])
    }

    /// `SpendReport` treats a missing currency as a parse failure, so this is a
    /// corner that should not arrive; if it does, the report is left out and
    /// cannot be named, because a blank entry in the pane's sentence would be
    /// worse than the omission.
    func testAReportDenominatedInNothingIsLeftOutAndNotNamed() {
        let total = BudgetPolicy.total([report(1000), report(999, "   ")], currency: "USD")
        XCTAssertEqual(total.minor, 1000)
        XCTAssertEqual(total.skipped, [], "an empty code in the skipped list would print as a currency with no name")
    }

    /// Micro-billed and cent-billed figures are only comparable at one scale,
    /// and the coarsest present is the one a budget is stated in.
    func testMixedExponentsTotalAtTheCoarsestScale() {
        let total = BudgetPolicy.total(
            [report(3284), report(1_500_000, exponent: 6)],
            currency: "USD"
        )
        XCTAssertEqual(total.minor, 3434, "$15.00 billed in micro-units should have joined as 1500 cents")
        XCTAssertEqual(total.skipped, [])
    }

    /// Only reports at one exponent means no rescaling at all, and the total
    /// stays in the units it arrived in rather than being pushed to cents.
    func testASingleScaleIsKeptAsItArrived() {
        let total = BudgetPolicy.total(
            [report(1_234_567, exponent: 6), report(1_000_000, exponent: 6)],
            currency: "USD"
        )
        XCTAssertEqual(total.minor, 2_234_567)
    }

    /// The rounding an invoice does: under one minor unit per report, and half
    /// away from zero rather than toward it, so a refund is not rounded up
    /// toward the user's favour on one row and down on the next. The companion
    /// report at exponent 2 is what fixes the scale being rounded to.
    func testRescalingRoundsHalfAwayFromZero() {
        let down = BudgetPolicy.total([report(0), report(1_234_567, exponent: 6)], currency: "USD")
        XCTAssertEqual(down.minor, 123, "0.4567 of a cent rounds down")

        let up = BudgetPolicy.total([report(0), report(1_235_000, exponent: 6)], currency: "USD")
        XCTAssertEqual(up.minor, 124, "exactly half a cent rounds away from zero")

        let negative = BudgetPolicy.total([report(0), report(-1_235_000, exponent: 6)], currency: "USD")
        XCTAssertEqual(negative.minor, -124, "a credit rounds away from zero too, not toward it")
    }

    /// A refund is a real thing a provider reports, and it has to come off the
    /// total rather than being floored at nothing.
    func testACreditReducesTheTotal() {
        let total = BudgetPolicy.total([report(1500), report(-500)], currency: "USD")
        XCTAssertEqual(total.minor, 1000)
    }

    /// An absurd total is a bug report; a crash is an uninstall.
    func testANonsenseAmountSaturatesRatherThanTrapping() {
        let high = BudgetPolicy.total([report(.max), report(1)], currency: "USD")
        XCTAssertEqual(high.minor, .max)

        let low = BudgetPolicy.total([report(.min), report(-1)], currency: "USD")
        XCTAssertEqual(low.minor, .min)
    }

    // MARK: - Status

    /// An absent budget is not a budget of zero, and an absent spend is not a
    /// spend of zero. Both are "there is no comparison to make".
    func testStatusIsNilWhenEitherSideIsMissing() {
        XCTAssertNil(BudgetPolicy.status(spend: report(1000), budget: nil))
        XCTAssertNil(BudgetPolicy.status(spend: nil, budget: budget(5000)))
        XCTAssertNil(BudgetPolicy.status(spend: nil, budget: nil))
    }

    /// A cleared field, not a limit of nothing — and nothing can be taken as a
    /// fraction of zero anyway.
    func testABudgetOfZeroIsNotALimit() {
        XCTAssertNil(BudgetPolicy.status(spend: report(1000), budget: budget(0)))
    }

    /// `Budget`'s initialiser floors the amount, so a negative one can only
    /// arrive by assignment onto the `var` afterwards. The policy still refuses
    /// it rather than producing a negative fraction.
    func testANegativeBudgetIsRefused() {
        var mutated = budget(5000)
        mutated.amountMinor = -1
        XCTAssertNil(BudgetPolicy.status(spend: report(1000), budget: mutated))
    }

    func testABudgetInAnotherCurrencyIsRefusedRatherThanConverted() {
        XCTAssertNil(
            BudgetPolicy.status(spend: report(1000, "EUR"), budget: budget(5000, "USD")),
            "an answer in the wrong currency is worse than no answer, because it looks like one"
        )
    }

    /// A budget denominated in nothing matches nothing, including a report that
    /// is also denominated in nothing.
    func testABudgetWithNoCurrencyMatchesNothing() {
        var blank = budget(5000)
        blank.currency = "   "
        XCTAssertNil(BudgetPolicy.status(spend: report(1000), budget: blank))
        XCTAssertNil(BudgetPolicy.status(spend: report(1000, "  "), budget: blank))
    }

    func testCurrencyComparisonIgnoresCaseAndSurroundingSpace() {
        var scruffy = budget(5000)
        scruffy.currency = " usd "
        XCTAssertNotNil(BudgetPolicy.status(spend: report(1000), budget: scruffy))
    }

    func testAPartialSpendReportsItsFractionAndWhatIsLeft() {
        let status = BudgetPolicy.status(spend: report(3284), budget: budget(5000))
        XCTAssertEqual(status?.fraction ?? .nan, 0.6568, accuracy: 1e-12)
        XCTAssertEqual(status?.remainingMinor, 1716)
        XCTAssertEqual(status?.isOver, false)
        XCTAssertEqual(status?.includesEstimates, false)
    }

    /// The boundary either side of the budget itself: spending exactly it has
    /// not exceeded it, one minor unit past it has.
    func testTheEdgeOfTheBudget() {
        let under = BudgetPolicy.status(spend: report(4999), budget: budget(5000))
        XCTAssertEqual(under?.isOver, false)
        XCTAssertEqual(under?.remainingMinor, 1)

        let exact = BudgetPolicy.status(spend: report(5000), budget: budget(5000))
        XCTAssertEqual(exact?.fraction ?? .nan, 1.0, accuracy: 1e-12)
        XCTAssertEqual(exact?.remainingMinor, 0)
        XCTAssertEqual(exact?.isOver, false, "spending exactly the budget has not exceeded it")

        let over = BudgetPolicy.status(spend: report(5001), budget: budget(5000))
        XCTAssertEqual(over?.fraction ?? .nan, 1.0002, accuracy: 1e-12)
        XCTAssertEqual(over?.remainingMinor, -1, "the overspend is the caller's to print, not to recompute")
        XCTAssertEqual(over?.isOver, true)
    }

    /// Going well past the budget is not clamped: a meter that stops at full
    /// hides how far past it went.
    func testTheFractionIsNotClampedAboveTheBudget() {
        let status = BudgetPolicy.status(spend: report(12_500), budget: budget(5000))
        XCTAssertEqual(status?.fraction ?? .nan, 2.5, accuracy: 1e-12)
        XCTAssertEqual(status?.remainingMinor, -7500)
    }

    /// A month in credit has no fill to draw, so the fraction floors at zero —
    /// and `remainingMinor` is where the credit itself survives.
    func testAMonthInCreditHasNoFillButKeepsItsRemainder() {
        let status = BudgetPolicy.status(spend: report(-500), budget: budget(5000))
        XCTAssertEqual(status?.fraction ?? .nan, 0, accuracy: 1e-12)
        XCTAssertEqual(status?.remainingMinor, 5500)
        XCTAssertEqual(status?.isOver, false)
    }

    /// An answer resting on a local token count has to say so, or the user
    /// reads a guess as an invoice.
    func testAnEstimatedSpendSaysSo() {
        let estimated = BudgetPolicy.status(
            spend: report(3284, confidence: .estimated),
            budget: budget(5000)
        )
        XCTAssertEqual(estimated?.includesEstimates, true)

        let measured = BudgetPolicy.status(
            spend: report(3284, confidence: .measured),
            budget: budget(5000)
        )
        XCTAssertEqual(measured?.includesEstimates, false)
    }

    /// The stated contract: a `Budget` carries no exponent, so it is read in
    /// whatever minor units the report it is measured against is stated in.
    /// Pinned because it is the assumption a caller could break by handing over
    /// a micro-billed report and a budget in cents.
    func testTheBudgetIsReadInTheReportsOwnMinorUnits() {
        let status = BudgetPolicy.status(
            spend: report(2_500_000, exponent: 6),
            budget: budget(5_000_000)
        )
        XCTAssertEqual(status?.fraction ?? .nan, 0.5, accuracy: 1e-12)
        XCTAssertEqual(status?.remainingMinor, 2_500_000)
    }

    /// Both extremes at once, so the subtraction overflows. It saturates, and
    /// the fraction stays a finite number a meter can be drawn from.
    func testExtremeAmountsSaturateAndStayFinite() {
        var enormous = budget(1)
        enormous.amountMinor = .max
        let status = BudgetPolicy.status(spend: report(.min), budget: enormous)
        XCTAssertEqual(status?.remainingMinor, .max)
        XCTAssertEqual(status?.isOver, false)
        XCTAssertEqual(status?.fraction.isFinite, true)
        XCTAssertEqual(status?.fraction ?? .nan, 0, accuracy: 1e-12)
    }

    // MARK: - Crossings

    /// Announcing every level below wherever the month already stands would be
    /// reporting crossings nobody witnessed.
    func testAFirstObservationAnnouncesNothing() {
        XCTAssertEqual(BudgetPolicy.crossings(previous: nil, current: 0.99, levels: [0.8, 1.0]), [])
    }

    func testEachLevelFiresExactlyOnceForARisingFigure() {
        let fired = walk([0.10, 0.50, 0.85, 0.90, 1.00, 1.40], levels: [0.8, 1.0])
        XCTAssertEqual(fired, [[], [], [0.8], [], [1.0], []])
    }

    func testAReadingThatJumpsTwoLevelsReportsBothInOrder() {
        XCTAssertEqual(
            BudgetPolicy.crossings(previous: 0.10, current: 1.00, levels: [1.0, 0.8]),
            [0.8, 1.0]
        )
    }

    func testAFigureThatHasNotMovedCrossesNothing() {
        XCTAssertEqual(BudgetPolicy.crossings(previous: 0.9, current: 0.9, levels: [0.8, 1.0]), [])
    }

    /// A refund or a new billing period, and then the climb again. The fall
    /// itself is silent, and the second climb is a genuine crossing.
    func testAFigureThatFallsBelowALevelRearmsIt() {
        let fired = walk([0.50, 0.85, 0.05, 0.85], levels: [0.8])
        XCTAssertEqual(fired, [[], [0.8], [], [0.8]])
    }

    func testLevelsGivenOutOfOrderComeBackAscending() {
        XCTAssertEqual(
            BudgetPolicy.crossings(previous: 0.0, current: 1.0, levels: [1.0, 0.5, 0.8]),
            [0.5, 0.8, 1.0]
        )
    }

    /// Half-open at the bottom, closed at the top. Sitting exactly on a level
    /// fires once and never again, which is the whole hysteresis.
    func testTheEdgesOfALevel() {
        XCTAssertEqual(
            BudgetPolicy.crossings(previous: 0.7999, current: 0.8, levels: [0.8]),
            [0.8],
            "a reading landing exactly on a level has crossed it"
        )
        XCTAssertEqual(
            BudgetPolicy.crossings(previous: 0.7, current: 0.7999, levels: [0.8]),
            [],
            "a ten-thousandth short is short"
        )
        XCTAssertEqual(
            BudgetPolicy.crossings(previous: 0.8, current: 0.8, levels: [0.8]),
            [],
            "the reading that already fired must not fire again"
        )
        XCTAssertEqual(
            BudgetPolicy.crossings(previous: 0.8, current: 0.9, levels: [0.8]),
            [],
            "climbing away from a level already crossed is not a second crossing"
        )
    }

    func testNoLevelsCrossNothing() {
        XCTAssertEqual(BudgetPolicy.crossings(previous: 0.0, current: 5.0, levels: []), [])
    }

    /// There is no crossing of a line spending has always been on the far side
    /// of, so zero and below are not lines at all.
    func testLevelsAtOrBelowZeroAreNotLines() {
        XCTAssertEqual(
            BudgetPolicy.crossings(previous: 0.0, current: 1.0, levels: [0, -0.2, 0.8]),
            [0.8]
        )
    }

    /// A budget is a line you can keep walking past, so a level above it is
    /// still a level. Clamping belongs to whoever collects them, not here.
    func testALevelAboveTheBudgetIsStillALine() {
        XCTAssertEqual(BudgetPolicy.crossings(previous: 1.0, current: 1.6, levels: [1.5]), [1.5])
    }

    /// Two spellings of the same level must not alert twice.
    func testADuplicatedLevelFiresOnce() {
        XCTAssertEqual(
            BudgetPolicy.crossings(previous: 0.0, current: 1.0, levels: [0.8, 0.8, 0.8]),
            [0.8]
        )
    }

    /// A budget of zero divided into a spend is where these come from, and a
    /// comparison against one is meaningless in both directions.
    func testANonFiniteReadingIsNotACrossing() {
        XCTAssertEqual(BudgetPolicy.crossings(previous: .nan, current: 1.0, levels: [0.8]), [])
        XCTAssertEqual(BudgetPolicy.crossings(previous: 0.0, current: .nan, levels: [0.8]), [])
        XCTAssertEqual(BudgetPolicy.crossings(previous: 0.0, current: .infinity, levels: [0.8]), [])
        XCTAssertEqual(
            BudgetPolicy.crossings(previous: -.infinity, current: .infinity, levels: [0.8]),
            []
        )
    }

    func testANonFiniteLevelIsDroppedAndTheRestStillFire() {
        XCTAssertEqual(
            BudgetPolicy.crossings(previous: 0.0, current: 1.0, levels: [.nan, .infinity, 0.8]),
            [0.8]
        )
    }

    // MARK: - Untrusted input

    /// A budget that has been through UserDefaults is untrusted input, and a bad
    /// blob outlives the session that wrote it. What the policy is handed after
    /// decoding must already be clean enough that it never has to guess: an
    /// amount that decoded to nothing is refused as a budget, and the levels it
    /// alerts at come back as a usable ascending set.
    func testAMalformedStoredBudgetReachesThePolicyAlreadyCleaned() throws {
        let json = #"{"amountMinor":-4200,"currency":"   ","alertsAt":[1.5,-0.2,0.8,0.8]}"#
        let stored = try JSONDecoder().decode(Budget.self, from: Data(json.utf8))

        XCTAssertEqual(stored.amountMinor, 0)
        XCTAssertEqual(stored.currency, Budget.defaultCurrency)
        XCTAssertNil(
            BudgetPolicy.status(spend: report(1000), budget: stored),
            "an amount that decoded to nothing is not a limit every spend is over"
        )
        XCTAssertEqual(
            BudgetPolicy.crossings(previous: 0.0, current: 1.0, levels: stored.alertsAt),
            [0.8],
            "the level above the budget and the level below zero were both dropped on the way in"
        )
    }

    /// A blob written by an older version, missing fields a later one added.
    /// It has to keep working, because the alternative is silently losing the
    /// amounts the user set.
    func testAStoredBudgetMissingFieldsStillMeasuresSpend() throws {
        let stored = try JSONDecoder().decode(Budget.self, from: Data(#"{"amountMinor":5000}"#.utf8))

        XCTAssertEqual(stored.currency, Budget.defaultCurrency)
        XCTAssertEqual(stored.alertsAt, Budget.defaultAlerts)

        let status = BudgetPolicy.status(spend: report(2500), budget: stored)
        XCTAssertEqual(status?.fraction ?? .nan, 0.5, accuracy: 1e-12)
        XCTAssertEqual(status?.remainingMinor, 2500)
    }
}
