import XCTest
import aibarsCore
@testable import aibarsCore

final class UsageMetricTests: XCTestCase {
    func testPercentClampedTo100() {
        let metric = UsageMetric(label: "msgs", used: 150, limit: 100)
        XCTAssertEqual(metric.percent, 1.0, accuracy: 0.0001)
    }

    func testPercentOfZeroLimit() {
        let metric = UsageMetric(label: "msgs", used: 5, limit: 0)
        XCTAssertEqual(metric.percent, 0)
    }

    func testFormatting() {
        XCTAssertEqual(UsageMetric(label: "x", used: 1_234, limit: 10_000).displayUsed, "1.2k")
        XCTAssertEqual(UsageMetric(label: "x", used: 12_345_678, limit: 0).displayUsed, "12.3M")
        XCTAssertEqual(UsageMetric(label: "x", used: 7, limit: 0).displayUsed, "7")
        XCTAssertEqual(UsageMetric(label: "x", used: 7.4, limit: 0).displayUsed, "7.4")
    }
}

final class ClaudeUsageParserTests: XCTestCase {
    /// The shape a live Max account returns: three enforced windows, one of
    /// them per-model. Reading only five_hour/seven_day dropped the third.
    func testParsesEveryEnforcedWindow() throws {
        let raw: [String: Any] = [
            "limits": [
                ["kind": "session", "group": "session", "percent": 5,
                 "resets_at": "2026-08-07T04:19:59Z", "severity": "normal"],
                ["kind": "weekly_all", "group": "weekly", "percent": 79,
                 "resets_at": "2026-08-09T15:59:59Z", "severity": "warning"],
                ["kind": "weekly_scoped", "group": "weekly", "percent": 59,
                 "resets_at": "2026-08-09T15:59:59Z", "scope": ["model": "Opus"]]
            ],
            "five_hour": ["utilization": 5, "resets_at": "2026-08-07T04:19:59Z"],
            "seven_day": ["utilization": 79, "resets_at": "2026-08-09T15:59:59Z"]
        ]
        let data = try ClaudeUsageParser.parse(raw, planName: "max", orgName: "Test")

        XCTAssertEqual(data.secondary.count, 2, "a window went missing")
        // Busiest first: the weekly cap is the one at risk, not the 5-hour one.
        XCTAssertEqual(data.primary.used, 79)
        XCTAssertEqual(data.primary.label, "Weekly · all models")
        XCTAssertEqual(data.secondary.map(\.used), [59, 5])
        XCTAssertEqual(data.secondary.first?.label, "Weekly · Opus")
        XCTAssertEqual(data.secondary.last?.label, "5h session")
    }

    func testUnnamedScopeStillReads() throws {
        let raw: [String: Any] = [
            "limits": [["kind": "weekly_scoped", "percent": 12, "scope": ["model": [:]]]]
        ]
        let data = try ClaudeUsageParser.parse(raw, planName: nil, orgName: "Test")
        XCTAssertEqual(data.primary.label, "Weekly · per-model")
    }

    /// Older responses carried only the two named buckets.
    func testFallsBackToTheNamedBuckets() throws {
        let raw: [String: Any] = [
            "five_hour": ["utilization": 42, "resets_at": "2026-08-01T18:00:00Z"],
            "seven_day": ["utilization": 11, "resets_at": "2026-08-05T00:00:00Z"]
        ]
        let data = try ClaudeUsageParser.parse(raw, planName: "pro", orgName: "Test")
        XCTAssertEqual(data.primary.used, 42, accuracy: 0.001)
        XCTAssertEqual(data.secondary.count, 1)
        XCTAssertEqual(try XCTUnwrap(data.secondary.first).used, 11, accuracy: 0.001)
    }

    func testNoWindowsIsAnError() {
        XCTAssertThrowsError(try ClaudeUsageParser.parse([:], planName: nil, orgName: "Test"))
    }
}

final class ChatGPTUsageParserTests: XCTestCase {
    /// The account-check payload, which is all ChatGPT exposes. There is no
    /// message allowance anywhere in its API — `/backend-api/usage`,
    /// `/conversation_limit` and `/rate_limits` are all 404 — so the metric is
    /// status-only and must never claim a quota.
    func testReportsAnActiveSubscription() throws {
        let raw: [String: Any] = [
            "accounts": [
                "70d6dbe3": [
                    "entitlement": [
                        "has_active_subscription": true,
                        "subscription_plan": "chatgptplusplan",
                        "renews_at": "2026-09-01T00:00:00Z"
                    ]
                ]
            ]
        ]
        let data = ChatGPTUsageParser.parse(raw, account: "someone@example.com")
        XCTAssertEqual(data.planName, "Plus")
        XCTAssertEqual(data.accountLabel, "someone@example.com")
        XCTAssertEqual(data.primary.limit, 0, "there is no quota to report")
        XCTAssertEqual(data.primary.label, "Subscription active")
        XCTAssertNotNil(data.primary.resetDate)
    }

    /// A lapsed subscription still returns its old plan identifier, so the flag
    /// decides — otherwise an expired account reads as Plus forever.
    func testLapsedSubscriptionReadsAsFree() {
        let raw: [String: Any] = [
            "accounts": [
                "a": [
                    "entitlement": [
                        "has_active_subscription": 0,
                        "subscription_plan": "chatgptplusplan",
                        "expires_at": "2025-12-03T04:55:31Z"
                    ]
                ]
            ]
        ]
        let data = ChatGPTUsageParser.parse(raw)
        XCTAssertEqual(data.planName, "Free")
        XCTAssertEqual(data.primary.label, "No active subscription")
    }

    func testPrefersThePayingAccount() {
        let raw: [String: Any] = [
            "accounts": [
                "free": ["entitlement": ["has_active_subscription": 0, "subscription_plan": "free"]],
                "paid": ["entitlement": ["has_active_subscription": true, "subscription_plan": "chatgptproplan"]]
            ]
        ]
        XCTAssertEqual(ChatGPTUsageParser.parse(raw).planName, "Pro")
    }

    func testUnknownPlanIdentifierIsTidiedRatherThanShown() {
        let raw: [String: Any] = [
            "accounts": ["a": ["entitlement": ["has_active_subscription": true, "subscription_plan": "chatgptbusinessplan"]]]
        ]
        XCTAssertEqual(ChatGPTUsageParser.parse(raw).planName, "Business")
    }

    func testEmptyPayloadDoesNotCrash() {
        let data = ChatGPTUsageParser.parse([:])
        XCTAssertEqual(data.planName, "Free")
        XCTAssertEqual(data.primary.limit, 0)
    }
}

final class CursorUsageParserTests: XCTestCase {
    /// The shape `/api/usage` actually returns, captured from a live session:
    /// one entry per model, plus the start of the billing cycle.
    func testParsesTheMeteredModelBucket() throws {
        let raw: [String: Any] = [
            "gpt-4": ["numRequests": 320, "numRequestsTotal": 320, "maxRequestUsage": 500],
            "gpt-3.5-turbo": ["numRequests": 12, "maxRequestUsage": 0],
            "startOfMonth": "2026-07-21T23:37:30.000Z"
        ]
        let data = CursorUsageParser.parse(raw)
        XCTAssertEqual(data.primary.used, 320)
        XCTAssertEqual(data.primary.limit, 500)
        XCTAssertEqual(data.planName, "Pro")
        // The cycle rolls a month after it started.
        let reset = try XCTUnwrap(data.primary.resetDate)
        XCTAssertGreaterThan(reset, try XCTUnwrap(ProviderDate.parse("2026-08-20T00:00:00Z")))
    }

    /// Usage-based plans report a null ceiling. Inventing a percentage there
    /// would show a full bar for an account that simply isn't metered.
    func testNullCeilingBecomesStatusOnly() {
        let raw: [String: Any] = [
            "gpt-4": ["numRequests": 0, "numRequestsTotal": 0, "maxRequestUsage": NSNull()],
            "startOfMonth": "2026-07-21T23:37:30.000Z"
        ]
        let data = CursorUsageParser.parse(raw)
        XCTAssertEqual(data.primary.limit, 0, "a null ceiling must not become a quota")
        XCTAssertEqual(data.primary.percent, 0)
    }

    func testStillReadsTheOlderNestedShape() {
        let raw: [String: Any] = [
            "plan": "Business",
            "usage": ["gpt-4": ["numRequests": 40, "maxRequestUsage": 100]]
        ]
        let data = CursorUsageParser.parse(raw)
        XCTAssertEqual(data.primary.used, 40)
        XCTAssertEqual(data.primary.limit, 100)
        XCTAssertEqual(data.planName, "Business")
    }

    func testEmptyResponseDoesNotCrash() {
        let data = CursorUsageParser.parse([:])
        XCTAssertEqual(data.primary.limit, 0)
    }
}

final class MiniMaxUsageParserTests: XCTestCase {
    func testFlattenedShape() {
        let raw: [String: Any] = [
            "used": 73,
            "limit": 100,
            "reset_at": "2026-08-02T00:00:00Z"
        ]
        let data = MiniMaxUsageParser.parse(raw, planName: "Team")
        XCTAssertEqual(data.primary.used, 73)
        XCTAssertEqual(data.primary.limit, 100)
        XCTAssertEqual(data.planName, "Team")
    }

    func testNestedShape() {
        let raw: [String: Any] = [
            "data": [
                "tokens": ["used": 1_200_000, "limit": 5_000_000, "reset_at": "2026-09-01T00:00:00Z"]
            ]
        ]
        let data = MiniMaxUsageParser.parse(raw, planName: "Pro")
        XCTAssertEqual(data.primary.used, 1_200_000)
        XCTAssertEqual(data.primary.limit, 5_000_000)
        XCTAssertEqual(data.primary.label, "tokens")
    }
}

final class PlanNameTests: XCTestCase {
    /// Claude reports its tier as an internal identifier.
    func testStripsBoilerplateAndTheServiceName() {
        XCTAssertEqual(PlanName.pretty("Default_Claude_Max_20X", service: "Claude"), "Max 20×")
        XCTAssertEqual(PlanName.pretty("claude_pro", service: "Claude"), "Pro")
        XCTAssertEqual(PlanName.pretty("Plus", service: "ChatGPT"), "Plus")
    }

    func testLeavesDeliberateCasingAlone() {
        XCTAssertEqual(PlanName.pretty("API", service: "MiniMax"), "API")
        XCTAssertEqual(PlanName.pretty("AI Pro", service: "Google Gemini"), "AI Pro")
    }

    /// Never return an empty pill: if everything looked like noise, the raw
    /// value is more use than nothing.
    func testFallsBackToTheRawValue() {
        XCTAssertEqual(PlanName.pretty("Default", service: "Claude"), "Default")
        XCTAssertEqual(PlanName.pretty("Cursor", service: "Cursor"), "Cursor")
    }
}
