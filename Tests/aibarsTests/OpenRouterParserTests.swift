import XCTest
@testable import aibarsCore

final class OpenRouterUsageParserTests: XCTestCase {
    /// 2023-11-14T22:13:20Z, a Tuesday — fixed so the reset arithmetic is testable.
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testParsesDocumentedShapeOfBothEndpoints() throws {
        let credits: [String: Any] = ["data": ["total_credits": 100.5, "total_usage": 25.75]]
        let key: [String: Any] = ["data": [
            "label": "macbook",
            "limit": NSNull(),
            "limit_remaining": NSNull(),
            "limit_reset": NSNull(),
            "usage": 25.75,
            "usage_daily": 0.42,
            "usage_weekly": 3.1,
            "usage_monthly": 12.34,
            "byok_usage": 0,
            "is_free_tier": false
        ]]

        let data = try OpenRouterUsageParser.parse(credits, key: key, now: now)
        XCTAssertEqual(data.providerID, "openrouter")
        XCTAssertEqual(data.planName, "Pay-as-you-go")
        XCTAssertEqual(data.accountLabel, "macbook")
        XCTAssertEqual(data.primary.label, "Balance")
        // total_credits - total_usage; no balance field exists upstream.
        XCTAssertEqual(data.primary.used, 74.75, accuracy: 0.001)
        // Money with no ceiling stays status-only.
        XCTAssertEqual(data.primary.limit, 0)
        XCTAssertEqual(data.primary.percent, 0)
        XCTAssertEqual(data.primary.unit, "USD")
        // An uncapped key contributes no bar, and BYOK at zero earns no row.
        XCTAssertEqual(data.secondary.map(\.label), ["Spent all time", "Today", "This week", "This month"])
        XCTAssertEqual(try XCTUnwrap(data.secondary.first).used, 25.75, accuracy: 0.001)
        XCTAssertTrue(data.secondary.allSatisfy { $0.limit == 0 })
    }

    func testAlternativeKeySpellingsWithoutDataEnvelope() throws {
        let credits: [String: Any] = ["totalCredits": "40", "totalUsage": 15]
        let key: [String: Any] = [
            "name": "ci-runner",
            "limit": 10,
            "limitRemaining": 2.5,
            "limitReset": "MONTHLY",
            "usageDaily": 1,
            "isFreeTier": "false",
            "byokUsage": 4.5
        ]

        let data = try OpenRouterUsageParser.parse(credits, key: key, now: now)
        XCTAssertEqual(data.planName, "Pay-as-you-go")
        XCTAssertEqual(data.accountLabel, "ci-runner")
        XCTAssertEqual(data.primary.used, 25, accuracy: 0.001)
        XCTAssertEqual(data.secondary.map(\.label), ["Key limit", "Spent all time", "Today", "BYOK"])

        let cap = try XCTUnwrap(data.secondary.first)
        // Spend against the cap is cap - remaining, and this one has a ceiling.
        XCTAssertEqual(cap.used, 7.5, accuracy: 0.001)
        XCTAssertEqual(cap.limit, 10, accuracy: 0.001)
        XCTAssertEqual(cap.percent, 0.75, accuracy: 0.001)
        XCTAssertEqual(cap.windowLabel, "Monthly")
        XCTAssertEqual(cap.resetDate, ProviderDate.parse("2023-12-01T00:00:00Z"))
        XCTAssertEqual(try XCTUnwrap(data.secondary.last).used, 4.5, accuracy: 0.001)
    }

    func testGarbageResponseThrowsParseError() {
        // Neither endpoint said anything numeric.
        assertParseError([:], key: nil)
        assertParseError(["data": ["nonsense": true]], key: ["data": ["label": "x"]])
        assertParseError(["html": "<!doctype html>"], key: nil)
    }

    func testRejectedKeyEnvelopeThrowsParseError() {
        // What both routes return for a bad key, minus the 401.
        assertParseError(["error": ["message": "User not found.", "code": 401]], key: nil)
        assertParseError([:], key: ["error": ["message": "User not found."]])
        // A proxy can pass the envelope back inside the `data` wrapper.
        assertParseError(["data": ["error": ["message": "No auth credentials found"]]], key: nil)
    }

    /// The key route is best-effort, so its rejection must not discard credits
    /// that arrived intact.
    func testRejectedKeyRouteStillRendersTheCreditsThatArrived() throws {
        let credits: [String: Any] = ["data": ["total_credits": 10, "total_usage": 2]]
        let data = try OpenRouterUsageParser.parse(credits, key: ["error": ["message": "User not found."]], now: now)
        XCTAssertEqual(data.primary.label, "Balance")
        XCTAssertEqual(data.primary.used, 8, accuracy: 0.001)
        XCTAssertEqual(data.secondary.map(\.label), ["Spent all time"])
        XCTAssertNil(data.accountLabel)
    }

    func testDailyAndWeeklyResetsLandAtMidnightUTC() throws {
        let daily = try capMetric(reset: "daily")
        XCTAssertEqual(daily.windowLabel, "Daily")
        XCTAssertEqual(daily.resetDate, ProviderDate.parse("2023-11-15T00:00:00Z"))

        // Tuesday the 14th; weeks run Monday to Sunday.
        let weekly = try capMetric(reset: "weekly")
        XCTAssertEqual(weekly.windowLabel, "Weekly")
        XCTAssertEqual(weekly.resetDate, ProviderDate.parse("2023-11-20T00:00:00Z"))

        // An unrecognised cadence is left unreported rather than guessed at.
        let unknown = try capMetric(reset: "fortnightly")
        XCTAssertNil(unknown.resetDate)
        XCTAssertNil(unknown.windowLabel)
    }

    func testFreeTierAccountReportsZeroBalanceWithoutClaimingExhaustion() throws {
        let credits: [String: Any] = ["data": ["total_credits": 0, "total_usage": 0]]
        let key: [String: Any] = ["data": ["is_free_tier": true, "usage": 0, "usage_daily": 0]]

        let data = try OpenRouterUsageParser.parse(credits, key: key, now: now)
        XCTAssertEqual(data.planName, "Free")
        XCTAssertEqual(data.primary.label, "Balance")
        XCTAssertEqual(data.primary.used, 0)
    }

    func testSpentCreditsAreLabelledExhausted() throws {
        let credits: [String: Any] = ["data": ["total_credits": 10, "total_usage": 10]]
        let data = try OpenRouterUsageParser.parse(credits, now: now)
        XCTAssertEqual(data.primary.label, "Balance (exhausted)")
        XCTAssertEqual(data.primary.used, 0)
        // No key payload, so no period breakdown — just the lifetime spend.
        XCTAssertEqual(data.secondary.map(\.label), ["Spent all time"])
    }

    /// Spend can outrun the credits bought, and free grants are spent without
    /// anything having been bought at all. Both are exhausted, and the figure is
    /// reported as it stands rather than floored at zero.
    func testSpendingPastTheCreditsBoughtIsFlaggedRatherThanHidden() throws {
        let overdrawn = try OpenRouterUsageParser.parse(
            ["data": ["total_credits": 5, "total_usage": 7]], now: now)
        XCTAssertEqual(overdrawn.primary.label, "Balance (exhausted)")
        XCTAssertEqual(overdrawn.primary.used, -2, accuracy: 0.001)

        let grantOnly = try OpenRouterUsageParser.parse(
            ["data": ["total_credits": 0, "total_usage": 3]], now: now)
        XCTAssertEqual(grantOnly.primary.label, "Balance (exhausted)")
        XCTAssertEqual(grantOnly.primary.used, -3, accuracy: 0.001)
    }

    func testKeyOnlyPayloadStillRendersWhenCreditsRouteIsRefused() throws {
        // The 403 "Management key required" path: /credits gave nothing.
        let key: [String: Any] = ["data": [
            "usage": 12.34,
            "usage_daily": 0.42,
            "usage_monthly": 12.34,
            "is_free_tier": false
        ]]
        let data = try OpenRouterUsageParser.parse([:], key: key, now: now)
        XCTAssertEqual(data.planName, "Pay-as-you-go")
        // Account-wide spend needs /credits, so the key's own total stands in and
        // says so — dropping it left an account with no period figures unreadable.
        XCTAssertEqual(data.primary.label, "Key spend")
        XCTAssertEqual(data.primary.used, 12.34, accuracy: 0.001)
        XCTAssertEqual(data.primary.limit, 0)
        XCTAssertEqual(data.secondary.map(\.label), ["Today", "This month"])
    }

    func testFloatNoiseIsRoundedToCents() throws {
        let credits: [String: Any] = ["data": ["total_credits": 100.1, "total_usage": 25.35]]
        let data = try OpenRouterUsageParser.parse(credits, now: now)
        XCTAssertEqual(data.primary.used, 74.75)
    }

    /// Money arriving as text is normal for this class of API, and a symbol or a
    /// thousands separator must not lose the figure.
    func testMoneyAsStringsWithSymbolsAndSeparators() throws {
        let credits: [String: Any] = ["data": ["total_credits": "$1,234.56", "total_usage": " 34.56 "]]
        let data = try OpenRouterUsageParser.parse(credits, now: now)
        XCTAssertEqual(data.primary.label, "Balance")
        XCTAssertEqual(data.primary.used, 1200, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(data.secondary.first).used, 34.56, accuracy: 0.001)
    }

    /// `Double("nan")` and `Double("inf")` both succeed, and JSON `true` bridges
    /// to a number that reads as 1. None of those is a dollar figure, and a NaN
    /// reaching a metric propagates into the meter's layout.
    func testNonFiniteAndBooleanFiguresAreNotReportedAsMoney() throws {
        let credits: [String: Any] = ["data": ["total_credits": 10, "total_usage": 1]]
        let key: [String: Any] = ["data": [
            "limit": true,
            "limit_remaining": "nan",
            "usage": "inf",
            "usage_daily": "NaN",
            "usage_monthly": 0.5
        ]]

        let data = try OpenRouterUsageParser.parse(credits, key: key, now: now)
        XCTAssertEqual(data.primary.used, 9, accuracy: 0.001)
        // No cap from `true`, no Today from "NaN", no key spend from "inf".
        XCTAssertEqual(data.secondary.map(\.label), ["Spent all time", "This month"])
        let all = [data.primary] + data.secondary
        XCTAssertTrue(all.allSatisfy { $0.used.isFinite && $0.limit.isFinite && $0.percent.isFinite })

        // Nothing numeric survives at all here, which is a parse failure.
        assertParseError(["data": ["total_credits": "nan", "total_usage": "inf"]], key: nil)
    }

    /// `limit: null` is how an uncapped key is described. It is not a quota of
    /// zero and it is not a full bar.
    func testNullQuotaContributesNoBar() throws {
        let key: [String: Any] = ["data": ["limit": NSNull(), "limit_remaining": 5, "usage": 2]]
        let data = try OpenRouterUsageParser.parse([:], key: key, now: now)
        XCTAssertEqual(data.primary.label, "Key spend")
        let all = [data.primary] + data.secondary
        XCTAssertFalse(all.contains { $0.label == "Key limit" })
        XCTAssertTrue(all.allSatisfy { $0.limit == 0 })
    }

    /// A cap the key has already blown past reads as what was actually spent;
    /// `percent` tops out on its own.
    func testKeyOverItsCapReportsTheRealSpend() throws {
        let key: [String: Any] = ["data": ["limit": 10, "limit_remaining": -2]]
        let data = try OpenRouterUsageParser.parse([:], key: key, now: now)
        XCTAssertEqual(data.primary.label, "Key limit")
        XCTAssertEqual(data.primary.used, 12, accuracy: 0.001)
        XCTAssertEqual(data.primary.limit, 10, accuracy: 0.001)
        XCTAssertEqual(data.primary.percent, 1.0, accuracy: 0.001)
    }

    /// A cap with no spend figure anywhere is a ceiling and no measurement. A bar
    /// at zero would be aibars' invention, not the account's state.
    func testCapWithoutASpendFigureDrawsNoBar() throws {
        let key: [String: Any] = ["data": ["limit": 10, "usage_daily": 0.5]]
        let data = try OpenRouterUsageParser.parse([:], key: key, now: now)
        XCTAssertEqual(data.primary.label, "Today")
        XCTAssertEqual(data.primary.limit, 0)
        XCTAssertFalse(([data.primary] + data.secondary).contains { $0.label == "Key limit" })
    }

    /// Credits bought with no spend figure to subtract cannot be called a
    /// balance: that would assert nothing has been spent.
    func testCreditsWithoutASpendFigureAreNotCalledABalance() throws {
        let data = try OpenRouterUsageParser.parse(["data": ["total_credits": 25]], now: now)
        XCTAssertEqual(data.primary.label, "Credits purchased")
        XCTAssertEqual(data.primary.used, 25, accuracy: 0.001)
        XCTAssertEqual(data.primary.limit, 0)
        XCTAssertEqual(data.planName, "Pay-as-you-go")
        XCTAssertTrue(data.secondary.isEmpty)
    }

    /// An unnamed key is labelled with the key itself, which names no account and
    /// puts credential material on screen.
    func testKeyShapedLabelIsNotUsedAsAnAccountName() throws {
        let key: [String: Any] = ["data": ["label": "sk-or-v1-9f2c...b41d", "usage": 1]]
        let data = try OpenRouterUsageParser.parse([:], key: key, now: now)
        XCTAssertNil(data.accountLabel)
        XCTAssertEqual(data.primary.label, "Key spend")
    }

    // MARK: - Helpers

    private func capMetric(reset: String) throws -> UsageMetric {
        let key: [String: Any] = ["data": ["limit": 5, "limit_remaining": 1, "limit_reset": reset]]
        let data = try OpenRouterUsageParser.parse([:], key: key, now: now)
        XCTAssertEqual(data.primary.label, "Key limit")
        return data.primary
    }

    private func assertParseError(
        _ credits: [String: Any],
        key: [String: Any]?,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try OpenRouterUsageParser.parse(credits, key: key, now: now), file: file, line: line) { error in
            guard let providerError = error as? ProviderError, case .parse = providerError else {
                XCTFail("Expected ProviderError.parse, got \(error)", file: file, line: line)
                return
            }
        }
    }
}
