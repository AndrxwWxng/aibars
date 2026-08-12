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

    /// A window the provider said nothing about the length of reports no
    /// duration, never a zero-length one. The meter draws its pace notch from
    /// this, and zero would pin the mark hard against the left edge of every
    /// track it touched — a made-up denominator drawn as a real one.
    func testWindowFieldsAreAbsentRatherThanZero() {
        let metric = UsageMetric(label: "5h session", used: 5, limit: 100)
        XCTAssertNil(metric.windowDuration)
        XCTAssertNil(metric.windowKey)
    }
}

final class UsageModelCodingTests: XCTestCase {
    func testWindowFieldsRoundTrip() throws {
        let metric = UsageMetric(
            label: "5h session",
            used: 5,
            limit: 100,
            resetDate: Date(timeIntervalSince1970: 1_770_000_000),
            windowLabel: "5h",
            windowDuration: 5 * 3_600,
            windowKey: "five_hour"
        )
        let decoded = try JSONDecoder().decode(
            UsageMetric.self, from: JSONEncoder().encode(metric)
        )
        XCTAssertEqual(decoded, metric)
        XCTAssertEqual(decoded.windowDuration, 5 * 3_600)
        XCTAssertEqual(decoded.windowKey, "five_hour")
    }

    func testSpendRoundTrips() throws {
        let report = SpendReport(
            amountMinor: 3_284,
            currency: "usd",
            limitMinor: 10_000,
            period: .month,
            confidence: .measured
        )
        let data = UsageData(
            providerID: "openrouter",
            primary: UsageMetric(label: "credits", used: 32.84, limit: 100),
            spend: report
        )
        let decoded = try JSONDecoder().decode(UsageData.self, from: JSONEncoder().encode(data))
        XCTAssertEqual(decoded.spend, report)
    }

    /// The snapshot store keeps every provider's last reading in one file, so a
    /// payload written before these keys existed has to decode rather than
    /// throw: a throw here costs the user every row, not one field.
    func testSnapshotWrittenBeforeTheseFieldsStillDecodes() throws {
        let json = Data("""
        {"providerID":"claude","fetchedAt":0,"planName":"Max",
         "primary":{"label":"5h session","used":42,"limit":100},"secondary":[]}
        """.utf8)
        let data = try JSONDecoder().decode(UsageData.self, from: json)
        XCTAssertNil(data.spend, "an old snapshot must not invent a spend figure")
        XCTAssertNil(data.primary.windowDuration)
        XCTAssertNil(data.primary.windowKey)
        XCTAssertEqual(data.primary.used, 42, accuracy: 0.001)
        XCTAssertEqual(data.planName, "Max")
    }
}

final class ProviderErrorTests: XCTestCase {
    /// `blocked` earns its place only by being told apart from a dead session:
    /// the refresh loop discards a credential on `isAuth`, and a Cloudflare
    /// challenge must not cost the user a browser cookie that still works.
    func testBlockedIsNotAnAuthFailure() {
        XCTAssertFalse(ProviderError.blocked("cloudflare challenge").isAuth)
        XCTAssertTrue(ProviderError.sessionExpired.isAuth)
        XCTAssertTrue(ProviderError.notAuthenticated.isAuth)
    }

    /// The sentence a row draws says what happened and that we will try again.
    /// What it no longer does is repeat whatever the server sent: the payload
    /// used to be interpolated straight into the panel, which put two lines of
    /// truncated JSON on one row and a Cloudflare parameter name on another.
    func testBlockedSaysWhatHappenedAndThatItWillRetry() throws {
        let error = ProviderError.blocked("cf_chl_opt")
        let message = try XCTUnwrap(error.errorDescription)
        XCTAssertFalse(message.contains("cf_chl_opt"), "the raw payload reached the panel")
        XCTAssertTrue(message.lowercased().contains("bot protection"))
        XCTAssertTrue(message.lowercased().contains("retry"))
        // It has not gone anywhere — it moved to the tooltip.
        XCTAssertEqual(error.diagnostic, "cf_chl_opt")
    }

    /// Every sentence in the closed set fits one line of the panel's 278pt text
    /// column, which is what "we wrote these" buys: a message from a server has
    /// no length we can plan a row around.
    func testEverySentenceFitsOneLine() throws {
        let all: [ProviderError] = [
            .notAuthenticated, .sessionExpired, .blocked("x"), .rateLimited,
            .network("x"), .parse("x"), .unsupported, .configuration("x")
        ]
        for error in all {
            let message = try XCTUnwrap(error.errorDescription)
            XCTAssertLessThanOrEqual(message.count, 38, "\(message) is too long for the row")
            // No enum case name, no colon-prefixed label: a sentence, not a log
            // line. "Network error: The endpoint did not respond" was both.
            XCTAssertFalse(message.contains(":"), "\(message) reads as a log line")
        }
    }

    /// The four cases that carry a payload expose it, and the four that carry
    /// nothing say so rather than returning an empty string a tooltip would
    /// draw as a blank second line.
    func testOnlyTheCasesWithAPayloadHaveADiagnostic() {
        XCTAssertEqual(ProviderError.network("HTTP 500: {}").diagnostic, "HTTP 500: {}")
        XCTAssertEqual(ProviderError.parse("missing key").diagnostic, "missing key")
        XCTAssertEqual(ProviderError.configuration("no endpoint").diagnostic, "no endpoint")
        XCTAssertNil(ProviderError.network("   ").diagnostic)
        XCTAssertNil(ProviderError.rateLimited.diagnostic)
        XCTAssertNil(ProviderError.sessionExpired.diagnostic)
        XCTAssertNil(ProviderError.notAuthenticated.diagnostic)
        XCTAssertNil(ProviderError.unsupported.diagnostic)
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

    /// The window is the billing month's own length, so the pace notch is drawn
    /// against 31 days in July and 28 in February rather than a flat 30.
    func testWindowDurationIsTheBillingMonthsOwnLength() throws {
        let july = CursorUsageParser.parse([
            "gpt-4": ["numRequests": 10, "maxRequestUsage": 500],
            "startOfMonth": "2026-07-21T00:00:00.000Z"
        ])
        XCTAssertEqual(july.primary.windowDuration, 31 * 24 * 3_600)

        let february = CursorUsageParser.parse([
            "gpt-4": ["numRequests": 10, "maxRequestUsage": 500],
            "startOfMonth": "2026-02-01T00:00:00.000Z"
        ])
        XCTAssertEqual(february.primary.windowDuration, 28 * 24 * 3_600)
    }

    /// A cycle with one edge named has no length. Half a cycle is not a cycle,
    /// and a notch drawn on the difference would be drawn on nothing.
    func testWindowDurationIsNilWhenOnlyTheEndIsKnown() {
        let data = CursorUsageParser.parse([
            "gpt-4": ["numRequests": 10, "maxRequestUsage": 500],
            "cycleEnd": 1_785_000_000_000
        ])
        XCTAssertNotNil(data.primary.resetDate)
        XCTAssertNil(data.primary.windowDuration)
    }
}

/// `/api/usage-summary`, the second payload — the money, in cents, and the
/// billing cycle's own bounds.
final class CursorSpendParserTests: XCTestCase {
    private let requests: [String: Any] = [
        "gpt-4": ["numRequests": 320, "numRequestsTotal": 320, "maxRequestUsage": 500],
        "startOfMonth": "2026-07-01T00:00:00.000Z"
    ]

    /// The shape a live individual account returns: on-demand spend against a
    /// stated ceiling, both in cents.
    func testCentsBecomeDollarsAgainstTheStatedCeiling() throws {
        let data = CursorUsageParser.parse(requests, summary: [
            "billingCycleStart": "2026-07-01T00:00:00.000Z",
            "billingCycleEnd": "2026-08-01T00:00:00.000Z",
            "individualUsage": [
                "onDemand": ["enabled": true, "used": 3_284, "limit": 25_000, "remaining": 21_716]
            ]
        ])
        let spend = try XCTUnwrap(data.spend)
        XCTAssertEqual(spend.amountMinor, 3_284)
        XCTAssertEqual(spend.amount, Decimal(string: "32.84"))
        XCTAssertEqual(spend.limitMinor, 25_000)
        XCTAssertEqual(spend.currency, "USD")
        XCTAssertEqual(spend.confidence, .measured)
        XCTAssertEqual(spend.period, .month)
        XCTAssertEqual(spend.resetDate, ProviderDate.parse("2026-08-01T00:00:00.000Z"))
    }

    /// `enabled: false` is a placeholder Cursor sends beside a live bucket on
    /// team accounts. Reading it as a spend of zero would report $0.00 for an
    /// organisation that has spent hundreds.
    func testDisabledBucketIsSkippedEntirely() throws {
        let data = CursorUsageParser.parse(requests, summary: [
            "individualUsage": [
                "onDemand": ["enabled": false, "used": 0, "limit": 0]
            ],
            "teamUsage": [
                "onDemand": ["enabled": true, "used": 75_000, "limit": 600_000, "remaining": 525_000]
            ]
        ])
        let spend = try XCTUnwrap(data.spend)
        XCTAssertEqual(spend.amountMinor, 75_000)
        XCTAssertEqual(spend.limitMinor, 600_000)
    }

    /// Some shapes only move the remaining balance and leave `used` at zero, so
    /// a positive difference wins over a reported zero.
    func testZeroUsedFallsBackToTheRemainingDifference() throws {
        let data = CursorUsageParser.parse(requests, summary: [
            "individualUsage": [
                "onDemand": ["enabled": true, "used": 0, "limit": 100_000, "remaining": 75_000]
            ]
        ])
        let spend = try XCTUnwrap(data.spend)
        XCTAssertEqual(spend.amountMinor, 25_000)
        XCTAssertEqual(spend.limitMinor, 100_000)
    }

    /// The individual bucket is the signed-in account's own spend and the team
    /// one is the organisation's aggregate. Both present is the ordinary case on
    /// a team seat, and the personal figure is the one the row is about.
    func testIndividualWinsOverTheTeamAggregate() throws {
        let data = CursorUsageParser.parse(requests, summary: [
            "individualUsage": [
                "onDemand": ["enabled": true, "used": 2_500, "limit": 25_000, "remaining": 22_500]
            ],
            "teamUsage": [
                "onDemand": ["enabled": true, "used": 75_000, "limit": 600_000],
                "pooled": ["enabled": true, "used": 125_000, "limit": 4_000_000]
            ]
        ])
        XCTAssertEqual(try XCTUnwrap(data.spend).amountMinor, 2_500)
    }

    /// An individual bucket carrying no figures at all is not a reading of zero.
    /// Reporting it would hide the pooled bucket that does have figures.
    func testEmptyIndividualBucketFallsThroughToPooled() throws {
        let data = CursorUsageParser.parse(requests, summary: [
            "individualUsage": ["onDemand": ["enabled": true]],
            "teamUsage": [
                "pooled": ["enabled": true, "used": 125_000, "limit": 4_000_000, "remaining": 3_875_000]
            ]
        ])
        XCTAssertEqual(try XCTUnwrap(data.spend).amountMinor, 125_000)
    }

    /// Cursor writes 0 for a bucket with no hard limit. That is genuinely
    /// uncapped, and not a ceiling the spend has already blown through.
    func testZeroLimitIsUncappedRatherThanFull() throws {
        let data = CursorUsageParser.parse(requests, summary: [
            "individualUsage": [
                "onDemand": ["enabled": true, "used": 4_200, "limit": 0]
            ]
        ])
        let spend = try XCTUnwrap(data.spend)
        XCTAssertEqual(spend.amountMinor, 4_200)
        XCTAssertNil(spend.limitMinor)
        XCTAssertNil(spend.percent)
    }

    /// A ceiling that is there and cannot be read poisons the whole report:
    /// showing it as uncapped would invent headroom the account may not have.
    func testUnreadableCeilingReportsNoSpendAtAll() {
        let data = CursorUsageParser.parse(requests, summary: [
            "individualUsage": [
                "onDemand": ["enabled": true, "used": 4_200, "limit": ["amount": 25_000]]
            ]
        ])
        XCTAssertNil(data.spend)
    }

    /// The summary is a best-effort second request. When it does not arrive the
    /// row still has the thing it is actually for.
    func testMissingSummaryLeavesTheQuotaCardIntact() {
        let data = CursorUsageParser.parse(requests)
        XCTAssertNil(data.spend)
        XCTAssertEqual(data.primary.used, 320)
        XCTAssertEqual(data.primary.limit, 500)
        XCTAssertEqual(data.primary.windowDuration, 31 * 24 * 3_600)
    }

    /// Enterprise responses can omit `startOfMonth` altogether, and the summary
    /// states both bounds outright. Taking them is reading the cycle Cursor
    /// published, not assuming one.
    func testSummaryBoundsSupplyTheCycleWhenUsageOmitsIt() throws {
        let data = CursorUsageParser.parse([
            "gpt-4": ["numRequests": 37, "maxRequestUsage": 750]
        ], summary: [
            "billingCycleStart": "2026-07-01T00:00:00.000Z",
            "billingCycleEnd": "2026-08-01T00:00:00.000Z",
            "individualUsage": [
                "onDemand": ["enabled": true, "used": 0, "limit": 25_000, "remaining": 25_000]
            ]
        ])
        XCTAssertEqual(data.primary.windowDuration, 31 * 24 * 3_600)
        XCTAssertEqual(data.primary.resetDate, ProviderDate.parse("2026-08-01T00:00:00.000Z"))
        XCTAssertEqual(try XCTUnwrap(data.spend).amountMinor, 0)
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

final class ClaudeTierNameTests: XCTestCase {
    /// The tier identifiers this account has actually reported.
    func testMapsRealTiers() throws {
        func plan(_ tier: String) throws -> String? {
            let raw: [String: Any] = ["limits": [["kind": "session", "percent": 1]]]
            return try ClaudeUsageParser.parse(raw, planName: tier, orgName: "").planName
        }
        XCTAssertEqual(try plan("Default_Claude_Max_20X"), "Max 20×")
        XCTAssertEqual(try plan("Default_Claude_Max_5X"), "Max 5×")
        // Stripping boilerplate off this one used to leave "Ai" — the product's
        // name, not a plan.
        XCTAssertEqual(try plan("Default_Claude_Ai"), "Free")
        XCTAssertEqual(try plan("claude_pro"), "Pro")
        XCTAssertEqual(try plan("Default_Claude_Team"), "Team")
    }

    /// Every personal organisation is "<email>'s Organization", so the suffix
    /// distinguishes nothing and pushed the address into an ellipsis.
    func testDropsTheOrganisationSuffix() throws {
        let raw: [String: Any] = ["limits": [["kind": "session", "percent": 1]]]
        let data = try ClaudeUsageParser.parse(
            raw, planName: nil, orgName: "someone@example.com's Organization"
        )
        XCTAssertEqual(data.accountLabel, "someone@example.com")

        let team = try ClaudeUsageParser.parse(raw, planName: nil, orgName: "Acme Inc")
        XCTAssertEqual(team.accountLabel, "Acme Inc", "a real org name must survive")
    }
}
