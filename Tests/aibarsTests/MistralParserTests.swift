import XCTest
@testable import aibarsCore

final class MistralUsageParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    // MARK: - The documented shape

    func testParsesDocumentedUsageCreditsAndVibe() throws {
        let prices: [[String: Any]] = [
            ["event_type": "completion", "billing_metric": "input_tokens",
             "billing_group": "mistral-large-latest", "price": "0.000002"],
            ["event_type": "completion", "billing_metric": "output_tokens",
             "billing_group": "mistral-large-latest", "price": "0.000006"],
            ["event_type": "ocr", "billing_metric": "pages",
             "billing_group": "mistral-ocr-latest", "price": "0.001"]
        ]
        let raw: [String: Any] = [
            "organization_name": "Acme Research",
            "currency": "USD",
            "currency_symbol": "$",
            "start_date": "2026-08-01T00:00:00Z",
            "end_date": "2026-08-31T23:59:59Z",
            "prices": prices,
            "completion": ["models": ["mistral-large-latest": [
                "input": [entry(event: "completion", metric: "input_tokens",
                                group: "mistral-large-latest", value: 1_000_000, paid: 800_000)],
                "output": [entry(event: "completion", metric: "output_tokens",
                                 group: "mistral-large-latest", value: 200_000, paid: 200_000)],
                // Cached tokens were used but not billed: they count towards the
                // token figure and contribute nothing to the spend.
                "cached": [entry(event: "completion", metric: "input_tokens",
                                 group: "mistral-large-latest", value: 50_000, paid: 0)]
            ]]],
            "ocr": ["models": ["mistral-ocr-latest": [
                "pages": [entry(event: "ocr", metric: "pages",
                                group: "mistral-ocr-latest", value: 100, paid: 100)]
            ]]]
        ]
        let credits: [String: Any] = [
            "wallet_amount": 50,
            "credit_notes_amount": 5,
            "ongoing_usage_balance": 2.5,
            "currency": "USD"
        ]
        let vibe: [Any] = [["result": ["data": ["json": [
            "usage_percentage": 42.5,
            "reset_at": "2026-09-01T00:00:00Z"
        ]]]]]

        let data = try MistralUsageParser.parse(raw, credits: credits, vibe: vibe, now: now)

        XCTAssertEqual(data.providerID, "mistral")
        XCTAssertEqual(data.accountLabel, "Acme Research")
        // Nothing in these responses names a plan, so none is invented.
        XCTAssertNil(data.planName)

        // The quota percentage is the only real bar Mistral reports, so it leads.
        XCTAssertEqual(data.primary.label, "Vibe quota")
        XCTAssertEqual(data.primary.used, 42.5, accuracy: 0.001)
        XCTAssertEqual(data.primary.limit, 100)
        XCTAssertEqual(data.primary.unit, "%")
        XCTAssertEqual(data.primary.resetDate, ProviderDate.parse("2026-09-01T00:00:00Z"))

        XCTAssertEqual(data.secondary.map(\.label), ["Spend", "Balance", "Tokens"])

        let spend = try XCTUnwrap(data.secondary.first)
        // 800k × 0.000002 + 200k × 0.000006 + 100 × 0.001
        XCTAssertEqual(spend.used, 2.9, accuracy: 0.0001)
        // Money with no ceiling stays status-only rather than reading as capped.
        XCTAssertEqual(spend.limit, 0)
        XCTAssertEqual(spend.unit, "USD")
        XCTAssertEqual(spend.windowLabel, "Month to date")
        XCTAssertEqual(spend.resetDate, ProviderDate.parse("2026-08-31T23:59:59Z"))

        let balance = data.secondary[1]
        // 50 + 5 − 2.5
        XCTAssertEqual(balance.used, 52.5, accuracy: 0.0001)
        XCTAssertEqual(balance.limit, 0)

        let tokens = data.secondary[2]
        XCTAssertEqual(tokens.used, 1_250_000, accuracy: 0.5)
        XCTAssertEqual(tokens.unit, "tokens")
    }

    // MARK: - Other spellings of the same thing

    func testCamelCaseKeysNestedPayloadAndCoarsePriceFallback() throws {
        // The price row carries no billing_group while the entry does, so the
        // join has to fall back to the (event_type, billing_metric) pair.
        let nested: [String: Any] = [
            "currency": "usd",
            "endDate": "2026-08-31T23:59:59Z",
            "organizationName": "Acme",
            "prices": [["eventType": "completion", "billingMetric": "tokens", "price": "0.00001"]],
            "completion": ["models": ["open-mistral-nemo": [
                "input": [[
                    "eventType": "completion",
                    "billingMetric": "tokens",
                    "billingGroup": "open-mistral-nemo",
                    "value": 400_000,
                    "valuePaid": 300_000
                ]]
            ]]]
        ]

        let data = try MistralUsageParser.parse(
            ["data": nested],
            credits: ["walletAmount": 10],
            // The same payload without the tRPC batch array around it.
            vibe: ["result": ["data": ["json": ["usagePercentage": 12]]]],
            now: now
        )

        XCTAssertEqual(data.accountLabel, "Acme")
        XCTAssertEqual(data.primary.label, "Vibe quota")
        XCTAssertEqual(data.primary.used, 12, accuracy: 0.001)
        XCTAssertNil(data.primary.resetDate)

        let spend = try XCTUnwrap(data.secondary.first)
        XCTAssertEqual(spend.used, 3, accuracy: 0.0001)
        XCTAssertEqual(spend.unit, "USD")
        XCTAssertEqual(data.secondary[1].used, 10, accuracy: 0.0001)
        // Tokens come from `value`, not `value_paid`: the count answers how much
        // was used, not how much of it was billed.
        XCTAssertEqual(data.secondary[2].used, 400_000, accuracy: 0.5)
    }

    // MARK: - Responses that are not answers

    func testGarbageResponseThrows() {
        assertParseError([:])
        // What a signed-out request answers with, minus the redirect.
        assertParseError(["error": "unauthorized"])
        // A category present as a string is not a category, and a price table on
        // its own says nothing about what was used.
        assertParseError(["completion": "nope", "prices": [["price": "0.1"]]])
    }

    func testEmptyMonthIsZeroSpendRatherThanAnError() throws {
        let raw: [String: Any] = [
            "completion": ["models": [String: Any]()],
            "prices": [[String: Any]](),
            "currency": "EUR",
            "end_date": "2026-08-31T23:59:59Z"
        ]

        let data = try MistralUsageParser.parse(raw, now: now)

        XCTAssertEqual(data.primary.label, "Spend")
        XCTAssertEqual(data.primary.used, 0)
        XCTAssertEqual(data.primary.limit, 0)
        XCTAssertEqual(data.primary.unit, "EUR")
        XCTAssertTrue(data.secondary.isEmpty)
    }

    func testUnpricedAmbiguousAndNonFiniteRowsAreSkipped() throws {
        let prices: [[String: Any]] = [
            // Double("nan") parses, so an unusable price has to be rejected on
            // the way into the table.
            ["event_type": "audio", "billing_metric": "seconds", "price": "nan"],
            ["event_type": "completion", "billing_metric": "input_tokens", "price": "0.000001"],
            // Two prices for the same pair: the coarse fallback must not pick one.
            ["event_type": "ocr", "billing_metric": "pages", "billing_group": "a", "price": "1"],
            ["event_type": "ocr", "billing_metric": "pages", "billing_group": "b", "price": "2"]
        ]
        let raw: [String: Any] = [
            "currency": "USD",
            "prices": prices,
            "completion": ["models": ["mistral-small": [
                "input": [entry(event: "completion", metric: "input_tokens",
                                group: "mistral-small", value: 1_000_000, paid: 1_000_000)]
            ]]],
            "audio": ["models": ["voxtral": [
                "input": [entry(event: "audio", metric: "seconds", group: "voxtral", value: 100, paid: 100)]
            ]]],
            "ocr": ["models": ["mistral-ocr-latest": [
                "pages": [entry(event: "ocr", metric: "pages", group: "c", value: 10, paid: 10)]
            ]]],
            // Priced nowhere at all.
            "connectors": ["models": ["web-search": [
                "requests": [entry(event: "connectors", metric: "requests", group: "web-search", value: 5, paid: 5)]
            ]]]
        ]

        let data = try MistralUsageParser.parse(raw, now: now)

        XCTAssertEqual(data.primary.label, "Spend")
        XCTAssertEqual(data.primary.used, 1, accuracy: 0.0001)
        XCTAssertTrue(data.primary.used.isFinite)
        // Only the completion category feeds the token count.
        let tokens = try XCTUnwrap(data.secondary.first)
        XCTAssertEqual(tokens.label, "Tokens")
        XCTAssertEqual(tokens.used, 1_000_000, accuracy: 0.5)
    }

    func testImpossibleVibePercentFallsBackToTheReportedNumber() throws {
        let raw: [String: Any] = [
            "currency": "USD",
            "prices": [[String: Any]](),
            "vibe_usage": 3,
            "completion": ["models": [String: Any]()]
        ]
        let vibe: [Any] = [["result": ["data": ["json": [
            "usage_percentage": 4_200,
            "reset_at": NSNull()
        ]]]]]

        let data = try MistralUsageParser.parse(raw, vibe: vibe, now: now)

        // Ten times past the ceiling is not the percentage the field is named
        // after, so it is refused rather than clamped into a full bar.
        XCTAssertEqual(data.primary.label, "Spend")
        XCTAssertEqual(data.primary.limit, 0)
        let reported = try XCTUnwrap(data.secondary.first)
        XCTAssertEqual(reported.label, "Vibe")
        XCTAssertEqual(reported.used, 3, accuracy: 0.001)
        // Units undocumented, so none is claimed.
        XCTAssertNil(reported.unit)
    }

    func testAnAccountOverItsQuotaStillLeadsWithTheQuotaBar() throws {
        let raw: [String: Any] = [
            "currency": "USD",
            "prices": [[String: Any]](),
            "completion": ["models": [String: Any]()]
        ]
        let vibe: [Any] = [["result": ["data": ["json": ["usage_percentage": 112.4]]]]]

        let data = try MistralUsageParser.parse(raw, vibe: vibe, now: now)

        // Being past the allowance is the moment this row matters most, so the
        // bar is pinned full rather than dropped for going over.
        XCTAssertEqual(data.primary.label, "Vibe quota")
        XCTAssertEqual(data.primary.used, 100)
        XCTAssertEqual(data.primary.limit, 100)
        XCTAssertEqual(data.primary.percent, 1)
        XCTAssertEqual(data.secondary.map(\.label), ["Spend"])
    }

    func testVibeQuotaBounds() {
        XCTAssertNil(MistralUsageParser.vibeQuota(["usage_percentage": -1]))
        XCTAssertNil(MistralUsageParser.vibeQuota(["usage_percentage": 1_001]))
        XCTAssertNil(MistralUsageParser.vibeQuota(["usage_percentage": "not a number"]))
        // A tRPC error body, and a batch with nothing in it.
        XCTAssertNil(MistralUsageParser.vibeQuota([["error": ["code": -32_001]]]))
        XCTAssertNil(MistralUsageParser.vibeQuota([Any]()))
        XCTAssertEqual(MistralUsageParser.vibeQuota(["usage_percentage": "37.5"])?.percent, 37.5)
    }

    func testNullsAreTreatedAsAbsentRatherThanZero() throws {
        let prices: [[String: Any]] = [[
            "event_type": "ocr", "billing_metric": "pages",
            "billing_group": "mistral-ocr-latest", "price": NSNull()
        ]]
        let raw: [String: Any] = [
            "currency": "USD",
            "prices": prices,
            "vibe_usage": NSNull(),
            "end_date": NSNull(),
            "ocr": ["models": ["mistral-ocr-latest": [
                "pages": [["event_type": "ocr", "billing_metric": "pages",
                           "billing_group": "mistral-ocr-latest",
                           "value": NSNull(), "value_paid": NSNull()]]
            ]]]
        ]

        let data = try MistralUsageParser.parse(
            raw,
            credits: ["wallet_amount": NSNull(), "currency": NSNull()],
            vibe: [["result": ["data": ["json": NSNull()]]]],
            now: now
        )

        XCTAssertEqual(data.primary.label, "Spend")
        XCTAssertEqual(data.primary.used, 0)
        XCTAssertNil(data.primary.resetDate)
        // No balance either: a null wallet is not a wallet of nothing.
        XCTAssertTrue(data.secondary.isEmpty)
    }

    // MARK: - Categories this parser has not heard of

    func testAnUndocumentedCategoryStillCountsTowardsSpend() throws {
        let prices: [[String: Any]] = [
            ["event_type": "embeddings", "billing_metric": "input_tokens",
             "billing_group": "mistral-embed", "price": "0.0000001"],
            ["event_type": "agents", "billing_metric": "steps",
             "billing_group": "agent", "price": "0.01"]
        ]
        let raw: [String: Any] = [
            "currency": "USD",
            "prices": prices,
            "completion": ["models": [String: Any]()],
            // Neither of these is in the shape this parser was written against,
            // and both are billed.
            "embeddings": ["models": ["mistral-embed": [
                "input": [entry(event: "embeddings", metric: "input_tokens",
                                group: "mistral-embed", value: 10_000_000, paid: 10_000_000)]
            ]]],
            "agents": ["models": ["agent": [
                "steps": [entry(event: "agents", metric: "steps", group: "agent", value: 50, paid: 50)]
            ]]]
        ]

        let data = try MistralUsageParser.parse(raw, now: now)

        // 10M × 0.0000001 + 50 × 0.01
        XCTAssertEqual(data.primary.used, 1.5, accuracy: 0.0001)
        let tokens = try XCTUnwrap(data.secondary.first)
        XCTAssertEqual(tokens.label, "Tokens")
        // Steps are not tokens, whatever the category is called.
        XCTAssertEqual(tokens.used, 10_000_000, accuracy: 0.5)
    }

    func testChatIsReadOnlyWhenCompletionIsAbsent() throws {
        let models: [String: Any] = ["models": ["mistral-medium": [
            "input": [entry(event: "completion", metric: "input_tokens",
                            group: "mistral-medium", value: 100, paid: 100)]
        ]]]
        let prices: [[String: Any]] = [[
            "event_type": "completion", "billing_metric": "input_tokens",
            "billing_group": "mistral-medium", "price": "0.01"
        ]]

        let chatOnly = try MistralUsageParser.parse(["prices": prices, "chat": models], now: now)
        XCTAssertEqual(chatOnly.primary.used, 1, accuracy: 0.0001)

        // The same entries under both spellings are one month's usage, not two.
        let both = try MistralUsageParser.parse(
            ["prices": prices, "chat": models, "completion": models],
            now: now
        )
        XCTAssertEqual(both.primary.used, 1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(both.secondary.first).used, 100, accuracy: 0.5)
    }

    // MARK: - Credits

    func testNegativeWalletIsNotANegativeBalance() throws {
        let balance = try XCTUnwrap(MistralUsageParser.availableBalance([
            "wallet_amount": 1,
            "ongoing_usage_balance": 5
        ]))

        XCTAssertEqual(balance.amount, 0, accuracy: 0.0001)
        XCTAssertEqual(balance.currency, "USD")
    }

    func testMoneyArrivingAsAString() throws {
        let balance = try XCTUnwrap(MistralUsageParser.availableBalance([
            "wallet_amount": "50.00",
            "credit_notes_amount": "$1,234.56",
            "ongoing_usage_balance": "4.56",
            "currency": "eur"
        ]))

        XCTAssertEqual(balance.amount, 1_280, accuracy: 0.0001)
        XCTAssertEqual(balance.currency, "EUR")
    }

    func testABalanceWithNoCreditFigureIsNotReported() {
        // A debit with nothing to draw it against. Reporting "0 left" would be
        // stating a balance this response never gave.
        XCTAssertNil(MistralUsageParser.availableBalance(["ongoing_usage_balance": 2.5]))
        XCTAssertNil(MistralUsageParser.availableBalance([:]))
        // `Double("nan")` parses, and a NaN balance renders as a blank row.
        XCTAssertNil(MistralUsageParser.availableBalance(["wallet_amount": "nan"]))

        // Credit notes on their own are a balance.
        XCTAssertEqual(MistralUsageParser.availableBalance(["credit_notes_amount": 7])?.amount, 7)
    }

    func testAccountLabelAndBalanceComeThroughACreditsWrapper() throws {
        let data = try MistralUsageParser.parse(
            ["completion": ["models": [String: Any]()], "currency": "USD"],
            credits: ["credits": ["wallet_amount": 12, "organization_name": "Acme GmbH"]],
            now: now
        )

        XCTAssertEqual(data.accountLabel, "Acme GmbH")
        XCTAssertEqual(data.secondary.map(\.label), ["Balance"])
        XCTAssertEqual(data.secondary.first?.used, 12)
    }

    // MARK: - Request shape

    func testUsageURLAsksForTheUTCMonth() throws {
        // 00:30 UTC on the 1st: any calendar west of Greenwich is still in the
        // previous month, which is not the month the endpoint buckets by.
        let boundary = try XCTUnwrap(ProviderDate.parse("2026-01-01T00:30:00Z"))
        let url = try XCTUnwrap(MistralProvider.usageURL(for: boundary))

        XCTAssertEqual(url.query, "month=1&year=2026")
        XCTAssertEqual(url.host, "admin.mistral.ai")
        XCTAssertEqual(url.path, "/api/billing/v2/usage")
    }

    // MARK: - Helpers

    private func entry(
        event: String,
        metric: String,
        group: String,
        value: Int,
        paid: Int
    ) -> [String: Any] {
        [
            "usage_type": metric,
            "event_type": event,
            "billing_metric": metric,
            "billing_display_name": metric,
            "billing_group": group,
            "timestamp": "2026-08-14T12:00:00Z",
            "value": value,
            "value_paid": paid
        ]
    }

    private func assertParseError(_ raw: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try MistralUsageParser.parse(raw, now: now), file: file, line: line) { error in
            guard case ProviderError.parse = error else {
                return XCTFail("Expected ProviderError.parse, got \(error)", file: file, line: line)
            }
        }
    }
}
