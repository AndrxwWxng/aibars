import XCTest
@testable import aibars

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
    func testParsesFastRequests() {
        let raw: [String: Any] = [
            "plan": "Pro",
            "usage": ["numRequests": 320, "limit": 500],
            "cycleEnd": 1_750_000_000_000
        ]
        let data = CursorUsageParser.parse(raw)
        XCTAssertEqual(data.primary.used, 320)
        XCTAssertEqual(data.primary.limit, 500)
        XCTAssertEqual(data.planName, "Pro")
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
