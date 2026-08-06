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
    func testParsesFiveHourAndWeekly() throws {
        let raw: [String: Any] = [
            "five_hour": [
                "utilization": 0.42,
                "resets_at": "2026-08-01T18:00:00Z"
            ],
            "seven_day": [
                "utilization": 0.11,
                "resets_at": "2026-08-05T00:00:00Z"
            ]
        ]
        let data = try! ClaudeUsageParser.parse(raw, planName: "pro", orgName: "Test")
        XCTAssertEqual(data.primary.used, 0.42, accuracy: 0.001)
        XCTAssertEqual(data.primary.windowLabel, "5h window")
        XCTAssertEqual(data.secondary.count, 1)
        let weekly = try XCTUnwrap(data.secondary.first)
        XCTAssertEqual(weekly.used, 0.11, accuracy: 0.001)
    }
}

final class ChatGPTUsageParserTests: XCTestCase {
    func testPicksAdvancedAsPrimary() throws {
        let raw: [String: Any] = [
            "account_plan": "Plus",
            "rate_limits": [
                "gpt-4o": ["primary": ["used": 5, "limit": 80, "reset_at": "2026-08-01T20:00:00Z"]],
                "gpt-5":  ["primary": ["used": 30, "limit": 40, "reset_at": "2026-08-01T20:00:00Z"]]
            ]
        ]
        let data = ChatGPTUsageParser.parse(raw)
        XCTAssertEqual(data.primary.label, "GPT-5")
        XCTAssertEqual(data.primary.used, 30)
        XCTAssertEqual(data.secondary.count, 1)
        let secondary = try XCTUnwrap(data.secondary.first)
        XCTAssertEqual(secondary.label, "GPT-4o")
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
