import XCTest
@testable import aibarsCore

final class PerplexityUsageParserTests: XCTestCase {
    /// Before the fixtures' promo expiry (1750000000, mid-2025) so the bonus
    /// pool is still live.
    private let now = Date(timeIntervalSince1970: 1_742_000_000)

    func testParsesDocumentedCreditsShape() throws {
        let grants: [[String: Any]] = [
            ["type": "recurring", "amount_cents": 10_000, "expires_at_ts": 1_750_000_000],
            ["type": "promotional", "amount_cents": 20_000, "expires_at_ts": 1_750_000_000]
        ]
        let raw: [String: Any] = [
            "balance_cents": 7_250,
            "renewal_date_ts": 1_743_000_000,
            "current_period_purchased_cents": 0,
            "credit_grants": grants,
            "total_usage_cents": 2_750
        ]

        let data = try PerplexityUsageParser.parse(raw, now: now)

        // Cents normalised to whole credits; all 2750 lands on the recurring pool.
        XCTAssertEqual(data.providerID, "perplexity")
        XCTAssertEqual(data.primary.label, "Credits")
        XCTAssertEqual(data.primary.used, 27.5, accuracy: 0.001)
        XCTAssertEqual(data.primary.limit, 100, accuracy: 0.001)
        XCTAssertEqual(data.primary.unit, "credits")
        XCTAssertEqual(data.primary.resetDate, Date(timeIntervalSince1970: 1_743_000_000))
        XCTAssertEqual(data.planName, "Max")

        let bonus = try XCTUnwrap(data.secondary.first)
        XCTAssertEqual(bonus.label, "Bonus")
        XCTAssertEqual(bonus.used, 0, accuracy: 0.001)
        XCTAssertEqual(bonus.limit, 200, accuracy: 0.001)
        XCTAssertNil(bonus.resetDate)
        // Formatted in the local calendar, so only the shape is asserted.
        XCTAssertTrue(bonus.windowLabel?.hasPrefix("exp. ") ?? false)
    }

    func testCamelCaseKeysNestedPayloadAndExpiredPromo() throws {
        let grants: [[String: Any]] = [
            ["grant_type": "recurring", "amountCents": 4_000],
            ["kind": "promotional", "amount": 1_000, "expires_at": 1_600_000_000]
        ]
        let nested: [String: Any] = [
            "balanceCents": 5_000,
            "totalUsageCents": 3_000,
            "currentPeriodPurchasedCents": 2_000,
            "renewalDateTs": 1_743_000_000,
            "creditGrants": grants
        ]

        let data = try PerplexityUsageParser.parse(["data": nested], now: now)

        XCTAssertEqual(data.primary.used, 30, accuracy: 0.001)
        XCTAssertEqual(data.primary.limit, 40, accuracy: 0.001)
        XCTAssertEqual(data.planName, "Pro")
        // The promo grant expired in 2020, so it contributes no lane.
        XCTAssertEqual(data.secondary.count, 1)
        let purchased = try XCTUnwrap(data.secondary.first)
        XCTAssertEqual(purchased.label, "Purchased")
        XCTAssertEqual(purchased.limit, 20, accuracy: 0.001)
    }

    func testUndocumentedGrantTypesStillLandInAPool() throws {
        // Not the type strings this parser was written against: a rename, and a
        // grant with no type at all. Neither may be dropped on the floor, or a
        // paying account reads as "Free" with nothing to show.
        let grants: [[String: Any]] = [
            ["type": "monthly_subscription", "amount_cents": 3_000],
            ["amount_cents": 1_000],
            ["type": "top_up", "amount_cents": 3_000],
            ["type": "promo_credit", "amount_cents": 2_000]
        ]

        let data = try PerplexityUsageParser.parse(
            ["total_usage_cents": 1_000, "credit_grants": grants],
            now: now
        )

        XCTAssertEqual(data.primary.label, "Credits")
        XCTAssertEqual(data.primary.limit, 40, accuracy: 0.001)
        XCTAssertEqual(data.primary.used, 10, accuracy: 0.001)
        XCTAssertEqual(data.planName, "Pro")
        XCTAssertEqual(data.secondary.map(\.label), ["Bonus", "Purchased"])
        let topUp = try XCTUnwrap(data.secondary.last)
        XCTAssertEqual(topUp.limit, 30, accuracy: 0.001)
    }

    func testDerivesUsageFromBalanceWhenUsageMissing() throws {
        let grants: [[String: Any]] = [["type": "recurring", "amount_cents": 10_000]]

        let data = try PerplexityUsageParser.parse(
            ["balance_cents": 6_000, "credit_grants": grants],
            now: now
        )

        XCTAssertEqual(data.primary.used, 40, accuracy: 0.001)
        XCTAssertEqual(data.primary.limit, 100, accuracy: 0.001)
    }

    func testPromoOnlyAccountLeadsWithTheLivePool() throws {
        let grants: [[String: Any]] = [
            ["type": "recurring", "amount_cents": 0],
            ["type": "promotional", "amount_cents": 2_000, "expires_at_ts": 1_750_000_000]
        ]

        let data = try PerplexityUsageParser.parse(
            ["total_usage_cents": 500, "credit_grants": grants],
            now: now
        )

        // No 0/0 subscription bar in front of the pool that actually has credits.
        XCTAssertEqual(data.primary.label, "Bonus")
        XCTAssertEqual(data.primary.used, 5, accuracy: 0.001)
        XCTAssertEqual(data.primary.limit, 20, accuracy: 0.001)
        XCTAssertTrue(data.secondary.isEmpty)
        XCTAssertEqual(data.planName, "Free")
    }

    func testFreeAccountIsStatusOnly() throws {
        let raw: [String: Any] = [
            "balance_cents": 0,
            "total_usage_cents": 0,
            "credit_grants": [[String: Any]]()
        ]

        let data = try PerplexityUsageParser.parse(raw, now: now)

        XCTAssertEqual(data.planName, "Free")
        XCTAssertEqual(data.primary.label, "No credit pool")
        // Status-only: a free account has no ceiling to be measured against.
        XCTAssertEqual(data.primary.limit, 0)
        XCTAssertEqual(data.primary.percent, 0)
    }

    func testPeriodLengthComesFromBothEdgesWhenStated() throws {
        // A 31-day period, deliberately not the 30 days a house guess would use:
        // the pace notch is drawn against this, so the length has to be the
        // period's own.
        let grants: [[String: Any]] = [
            ["type": "recurring", "amount_cents": 10_000],
            ["type": "promotional", "amount_cents": 2_000, "expires_at_ts": 1_750_000_000],
            ["type": "purchased", "amount_cents": 1_000]
        ]
        let raw: [String: Any] = [
            "total_usage_cents": 2_000,
            "currentPeriodStartTs": 1_740_321_600,
            "renewal_date_ts": 1_743_000_000,
            "credit_grants": grants
        ]

        let data = try PerplexityUsageParser.parse(raw, now: now)

        XCTAssertEqual(data.primary.windowDuration ?? 0, 31 * 24 * 3600, accuracy: 0.5)
        // The other two pools never reset, so a length on them would be a notch
        // measured against nothing.
        XCTAssertEqual(data.secondary.map(\.windowDuration), [nil, nil])
    }

    func testNoPeriodLengthWithoutBothEdges() throws {
        let grants: [[String: Any]] = [["type": "recurring", "amount_cents": 10_000]]

        // The renewal names the far edge and nothing names the near one.
        let openEnded = try PerplexityUsageParser.parse(
            ["total_usage_cents": 2_000, "renewal_date_ts": 1_743_000_000, "credit_grants": grants],
            now: now
        )
        XCTAssertNil(openEnded.primary.windowDuration)
        XCTAssertEqual(openEnded.primary.resetDate, Date(timeIntervalSince1970: 1_743_000_000))

        // A start on the far side of the renewal is a pair of dates that cannot
        // be divided by, not a period running backwards.
        let inverted = try PerplexityUsageParser.parse(
            [
                "total_usage_cents": 2_000,
                "current_period_start_ts": 1_744_000_000,
                "renewal_date_ts": 1_743_000_000,
                "credit_grants": grants
            ],
            now: now
        )
        XCTAssertNil(inverted.primary.windowDuration)

        // No renewal at all: nothing to measure a length against either.
        let noRenewal = try PerplexityUsageParser.parse(
            ["total_usage_cents": 2_000, "current_period_start_ts": 1_740_321_600, "credit_grants": grants],
            now: now
        )
        XCTAssertNil(noRenewal.primary.windowDuration)
    }

    func testWindowKeysFollowThePoolNotTheSlot() throws {
        let subscribed = try PerplexityUsageParser.parse(
            [
                "total_usage_cents": 500,
                "credit_grants": [
                    ["type": "recurring", "amount_cents": 10_000],
                    ["type": "promotional", "amount_cents": 2_000, "expires_at_ts": 1_750_000_000]
                ] as [[String: Any]]
            ],
            now: now
        )
        XCTAssertEqual(subscribed.primary.windowKey, "recurring_credits")
        XCTAssertEqual(subscribed.secondary.map(\.windowKey), ["promotional_credits"])

        // The bonus pool leads on a promo-only account. Its key must not move
        // with it, or the series forks the day the user subscribes.
        let promoOnly = try PerplexityUsageParser.parse(
            [
                "total_usage_cents": 500,
                "credit_grants": [
                    ["type": "promotional", "amount_cents": 2_000, "expires_at_ts": 1_750_000_000]
                ] as [[String: Any]]
            ],
            now: now
        )
        XCTAssertEqual(promoOnly.primary.label, "Bonus")
        XCTAssertEqual(promoOnly.primary.windowKey, "promotional_credits")

        // The free-account placeholder is not one of Perplexity's pools, so it
        // gets no series of its own.
        let free = try PerplexityUsageParser.parse(
            ["balance_cents": 0, "total_usage_cents": 0, "credit_grants": [[String: Any]]()],
            now: now
        )
        XCTAssertNil(free.primary.windowKey)
    }

    func testGarbageResponseThrows() {
        assertParseError([:])
        // What a signed-out request answers with, minus the 401.
        assertParseError(["error": "unauthorized"])
        // Grants present but not objects: nothing usable, so not a silent zero.
        assertParseError(["credit_grants": ["nope"]])
    }

    private func assertParseError(_ raw: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try PerplexityUsageParser.parse(raw, now: now), file: file, line: line) { error in
            guard case ProviderError.parse = error else {
                return XCTFail("Expected ProviderError.parse, got \(error)", file: file, line: line)
            }
        }
    }
}
