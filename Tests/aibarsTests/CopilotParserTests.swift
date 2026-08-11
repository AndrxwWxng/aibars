import XCTest
@testable import aibarsCore

final class CopilotUsageParserTests: XCTestCase {
    func testPlanComesFromEitherKeyAndIsPassedThroughUntidied() {
        XCTAssertEqual(CopilotUsageParser.parse(user: ["copilot_plan": "business"], usage: [:]).planName, "business")
        // The older spelling, for accounts the newer key is missing on.
        XCTAssertEqual(CopilotUsageParser.parse(user: ["plan": "enterprise"], usage: [:]).planName, "enterprise")
    }

    func testAnEmptyResponseIsAnActiveIndividualSeat() {
        let data = CopilotUsageParser.parse(user: [:], usage: [:])

        XCTAssertEqual(data.providerID, "copilot")
        XCTAssertEqual(data.planName, "Individual")
        // Chat is assumed on: a seat that answers at all is a seat that works.
        XCTAssertEqual(data.primary.label, "Active")
    }

    func testChatDisabledReadsAsPaused() {
        let data = CopilotUsageParser.parse(user: ["chat_enabled": false], usage: [:])

        XCTAssertEqual(data.primary.label, "Paused")
        XCTAssertEqual(data.primary.used, 0)
    }

    func testActiveSeatDoesNotFillTheMeter() {
        let data = CopilotUsageParser.parse(user: ["chat_enabled": true], usage: [:])

        // This row is a status, not a quota. The zero limit is what keeps
        // "active" from reading as 100% used and turning the menu bar red.
        XCTAssertEqual(data.primary.used, 1)
        XCTAssertEqual(data.primary.limit, 0)
        XCTAssertEqual(data.primary.percent, 0)
    }

    func testQuotaResetDate() {
        let data = CopilotUsageParser.parse(user: [:], usage: ["quota_reset_date": "2026-09-01T00:00:00Z"])
        XCTAssertEqual(data.primary.resetDate, ProviderDate.parse("2026-09-01T00:00:00Z"))

        XCTAssertNil(CopilotUsageParser.parse(user: [:], usage: ["quota_reset_date": "not-a-date"]).primary.resetDate)
        XCTAssertNil(CopilotUsageParser.parse(user: [:], usage: [:]).primary.resetDate)
    }
}
