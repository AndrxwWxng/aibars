import XCTest
@testable import aibarsCore

final class DeepSeekUsageParserTests: XCTestCase {
    func testParsesDocumentedBalanceShape() throws {
        let infos: [[String: Any]] = [
            [
                "currency": "USD",
                "total_balance": "110.00",
                "granted_balance": "10.00",
                "topped_up_balance": "100.00"
            ]
        ]
        let data = try DeepSeekUsageParser.parse(["is_available": true, "balance_infos": infos])
        XCTAssertEqual(data.providerID, "deepseek")
        XCTAssertEqual(data.planName, "Pay-as-you-go")
        XCTAssertEqual(data.primary.used, 110, accuracy: 0.001)
        // Prepaid credit has no ceiling, so the metric must stay status-only.
        XCTAssertEqual(data.primary.limit, 0)
        XCTAssertEqual(data.primary.percent, 0)
        XCTAssertEqual(data.primary.unit, "USD")
        XCTAssertEqual(data.primary.label, "Balance")
        XCTAssertEqual(data.secondary.map(\.label), ["Granted", "Topped up"])
        XCTAssertEqual(data.secondary.first?.used, 10)
    }

    func testPrefersUSDEntryOverOtherCurrencies() throws {
        let infos: [[String: Any]] = [
            ["currency": "CNY", "total_balance": "800.00"],
            ["currency": "USD", "total_balance": "12.50"]
        ]
        let data = try DeepSeekUsageParser.parse(["is_available": true, "balance_infos": infos])
        XCTAssertEqual(data.primary.used, 12.5, accuracy: 0.001)
        XCTAssertEqual(data.primary.unit, "USD")
    }

    func testFallsBackToFirstEntryWhenNoUSD() throws {
        let infos: [[String: Any]] = [["currency": "CNY", "total_balance": "800.00"]]
        let data = try DeepSeekUsageParser.parse(["is_available": true, "balance_infos": infos])
        XCTAssertEqual(data.primary.used, 800, accuracy: 0.001)
        XCTAssertEqual(data.primary.unit, "CNY")
    }

    func testAlternativeKeySpellingsAndNumericValues() throws {
        let infos: [[String: Any]] = [
            ["currencyCode": "usd", "grantedBalance": 5, "toppedUpBalance": 20.25]
        ]
        let nested: [String: Any] = ["isAvailable": true, "balanceInfos": infos]
        let data = try DeepSeekUsageParser.parse(["data": nested])
        // total_balance absent — reconstructed from granted + topped up.
        XCTAssertEqual(data.primary.used, 25.25, accuracy: 0.001)
        XCTAssertEqual(data.primary.unit, "USD")
        XCTAssertEqual(data.primary.label, "Balance")
        XCTAssertEqual(data.secondary.count, 2)
    }

    func testFlatSingleCurrencyPayload() throws {
        // No balance_infos wrapper at all — the shape the parser falls back to.
        let data = try DeepSeekUsageParser.parse(["currency": "USD", "balance": "42.00"])
        XCTAssertEqual(data.primary.used, 42, accuracy: 0.001)
        XCTAssertEqual(data.primary.limit, 0)
        XCTAssertTrue(data.secondary.isEmpty)
    }

    func testExhaustedAccountIsLabelled() throws {
        let infos: [[String: Any]] = [["currency": "USD", "total_balance": "0.00"]]
        let data = try DeepSeekUsageParser.parse(["is_available": false, "balance_infos": infos])
        XCTAssertEqual(data.primary.label, "Balance (exhausted)")
        XCTAssertEqual(data.primary.used, 0)
    }

    func testEmptyResponseThrowsParseError() {
        assertParseError([:])
    }

    func testAuthErrorPayloadThrowsParseError() {
        // What the endpoint actually returns for a bad key, minus the 401.
        let error: [String: Any] = ["message": "Authentication Fails", "type": "authentication_error"]
        assertParseError(["error": error, "balance_infos": ["not-a-dictionary"]])
    }

    func testEntryWithNoMoneyFieldsThrows() {
        let infos: [[String: Any]] = [["currency": "USD"]]
        assertParseError(["is_available": true, "balance_infos": infos])
    }

    private func assertParseError(_ raw: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try DeepSeekUsageParser.parse(raw), file: file, line: line) { error in
            guard let providerError = error as? ProviderError, case .parse = providerError else {
                XCTFail("Expected ProviderError.parse, got \(error)", file: file, line: line)
                return
            }
        }
    }
}
