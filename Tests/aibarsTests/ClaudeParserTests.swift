import XCTest
@testable import aibarsCore

/// The window's length and its history key, both of which come from the
/// payload's `kind` rather than from anything on screen.
final class ClaudeWindowMappingTests: XCTestCase {
    private func parse(_ raw: [String: Any]) throws -> UsageData {
        try ClaudeUsageParser.parse(raw, planName: nil, orgName: "Test")
    }

    /// Anthropic publishes a kind and a reset instant, never a duration. Both
    /// kinds are documented product limits, so the two lengths are facts; a
    /// kind that is neither must get no length at all rather than a plausible
    /// one, because the pace notch is drawn against it.
    func testWindowDurationComesFromTheKind() throws {
        let raw: [String: Any] = [
            "limits": [
                ["kind": "session", "percent": 5],
                ["kind": "weekly_all", "percent": 79],
                ["kind": "weekly_scoped", "percent": 59, "scope": ["model": "Opus"]],
                ["kind": "monthly_experiment", "percent": 90]
            ]
        ]
        let data = try parse(raw)
        var byLabel: [String: UsageMetric] = [:]
        for metric in [data.primary] + data.secondary { byLabel[metric.label] = metric }

        XCTAssertEqual(byLabel["5h session"]?.windowDuration, 18_000)
        XCTAssertEqual(byLabel["Weekly · all models"]?.windowDuration, 604_800)
        XCTAssertEqual(byLabel["Weekly · Opus"]?.windowDuration, 604_800)
        XCTAssertNil(
            byLabel["Monthly experiment"]?.windowDuration,
            "a window nobody stated the length of must draw no notch"
        )
    }

    /// The legacy spelling is the same seven-day cap.
    func testLegacyKeysCarryTheSameDurations() throws {
        let raw: [String: Any] = [
            "five_hour": ["utilization": 42],
            "seven_day": ["utilization": 11],
            "seven_day_sonnet": ["utilization": 7]
        ]
        let data = try parse(raw)
        let durations = ([data.primary] + data.secondary).map(\.windowDuration)
        XCTAssertEqual(durations, [18_000, 604_800, 604_800])
    }

    /// The point of a key that is not the label: Anthropic renames these
    /// windows on screen, and a series keyed off the label forks on a rename
    /// and orphans everything recorded before it.
    func testWindowKeySurvivesALabelChange() throws {
        let renamed = try parse(["five_hour": ["utilization": 5, "label": "Current session"]])
        XCTAssertEqual(renamed.primary.label, "Current session", "the provider's own wording is shown")
        XCTAssertEqual(renamed.primary.windowKey, "session")

        let modern = try parse(["limits": [["kind": "session", "percent": 5]]])
        XCTAssertEqual(modern.primary.label, "5h session")
        XCTAssertEqual(
            modern.primary.windowKey, renamed.primary.windowKey,
            "the two spellings of one window are one series"
        )
    }

    /// `seven_day` and `weekly_all` are the same limit, and a model-scoped
    /// weekly cap keys on the model rather than on which shape reported it.
    func testTheTwoShapesAgreeOnKeys() throws {
        let legacy = try parse([
            "seven_day": ["utilization": 11],
            "seven_day_sonnet": ["utilization": 7]
        ])
        XCTAssertEqual(legacy.primary.windowKey, "weekly")
        XCTAssertEqual(legacy.secondary.first?.windowKey, "weekly-sonnet")

        let modern = try parse([
            "limits": [
                ["kind": "weekly_all", "percent": 11],
                ["kind": "weekly_scoped", "percent": 7, "scope": ["model": ["display_name": "Sonnet"]]]
            ]
        ])
        XCTAssertEqual(modern.primary.windowKey, "weekly")
        XCTAssertEqual(modern.secondary.first?.windowKey, "weekly-sonnet")
    }

    /// A scoped weekly cap with no model named still needs a key of its own,
    /// or it would file itself under the all-models series.
    func testUnnamedScopeKeepsItsOwnKey() throws {
        let data = try parse(["limits": [["kind": "weekly_scoped", "percent": 12]]])
        XCTAssertEqual(data.primary.label, "Weekly · per-model")
        XCTAssertEqual(data.primary.windowKey, "weekly-scoped")
    }
}

/// The legacy shape, which used to lose a whole limit and invent another.
final class ClaudeLegacyWindowTests: XCTestCase {
    private func parse(_ raw: [String: Any]) throws -> UsageData {
        try ClaudeUsageParser.parse(raw, planName: nil, orgName: "Test")
    }

    /// `seven_day_sonnet` is a literal top-level key, a sibling of the other
    /// two rather than an entry in a limits array — so reading only `five_hour`
    /// and `seven_day` dropped the model-scoped weekly cap entirely.
    func testReadsTheModelScopedWeeklySibling() throws {
        let raw: [String: Any] = [
            "five_hour": ["utilization": 5, "resets_at": "2026-08-07T04:19:59Z"],
            "seven_day": ["utilization": 11],
            "seven_day_sonnet": ["utilization": 64],
            "seven_day_opus": ["utilization": 30]
        ]
        let data = try parse(raw)
        let labels = ([data.primary] + data.secondary).map(\.label)
        XCTAssertEqual(labels, ["Weekly · Sonnet", "Weekly · Opus", "Weekly · all models", "5h session"])
        XCTAssertEqual(data.primary.used, 64)
    }

    /// On Pro and standard seats the model-scoped cap runs on usage credits and
    /// is genuinely absent. A zero there is a full green meter for a limit the
    /// account does not have.
    func testAnAbsentScopedLimitIsNoRowRatherThanZero() throws {
        let raw: [String: Any] = [
            "five_hour": ["utilization": 5],
            "seven_day": ["utilization": 11],
            "seven_day_sonnet": ["resets_at": "2026-08-09T15:59:59Z"]
        ]
        let data = try parse(raw)
        let labels = ([data.primary] + data.secondary).map(\.label)
        XCTAssertEqual(labels, ["Weekly · all models", "5h session"])
        XCTAssertFalse(labels.contains { $0.contains("Sonnet") }, "an absent limit must not become 0%")
    }

    /// Same rule in the array form: a limits entry with no percentage is a
    /// window this seat does not have.
    func testAnEntryWithNoPercentageIsSkipped() throws {
        let raw: [String: Any] = [
            "limits": [
                ["kind": "session", "percent": 5],
                ["kind": "weekly_scoped", "scope": ["model": "Opus"], "resets_at": "2026-08-09T15:59:59Z"]
            ]
        ]
        let data = try parse(raw)
        XCTAssertTrue(data.secondary.isEmpty)
        XCTAssertEqual(data.primary.label, "5h session")
    }
}

/// Overage spend: what Anthropic says has been billed past the plan.
final class ClaudeSpendParserTests: XCTestCase {
    private let windows: [String: Any] = ["limits": [["kind": "session", "percent": 5]]]

    private func parse(_ extra: [String: Any]) throws -> UsageData {
        try ClaudeUsageParser.parse(windows.merging(extra) { _, new in new }, planName: nil, orgName: "Test")
    }

    /// The newer object is the account's own statement about overages, and it
    /// carries a currency the older one never had.
    func testPrefersTheSpendObjectOverExtraUsage() throws {
        let data = try parse([
            "spend": [
                "enabled": true,
                "used": ["amount_minor": 3_284, "currency": "USD", "exponent": 2],
                "limit": ["amount_minor": 10_000, "currency": "USD", "exponent": 2]
            ],
            "extra_usage": ["is_enabled": true, "used_credits": 99, "monthly_limit": 500]
        ])
        let spend = try XCTUnwrap(data.spend)
        XCTAssertEqual(spend.amountMinor, 3_284)
        XCTAssertEqual(spend.limitMinor, 10_000)
        XCTAssertEqual(spend.currency, "USD")
        XCTAssertEqual(spend.confidence, .measured)
        XCTAssertEqual(spend.period, .month)
    }

    func testReadsTheOlderExtraUsageShape() throws {
        let data = try parse(["extra_usage": [
            "is_enabled": true,
            "used_credits": 1_250,
            "monthly_limit": 5_000,
            "decimal_places": 2
        ]])
        let spend = try XCTUnwrap(data.spend)
        XCTAssertEqual(spend.amountMinor, 1_250)
        XCTAssertEqual(spend.limitMinor, 5_000)
        XCTAssertEqual(spend.exponent, 2)
        XCTAssertEqual(spend.display, "$12.50")
    }

    /// `extra_usage: null` means overages are switched off, which is why a full
    /// meter with no spend beside it is not the same warning as a full meter
    /// with one: the first account is stopped, the second is billing.
    func testNullExtraUsageMeansOveragesAreOff() throws {
        XCTAssertNil(try parse(["extra_usage": NSNull()]).spend)
        XCTAssertNil(try parse([:]).spend)
        XCTAssertNil(try parse(["extra_usage": ["is_enabled": false, "used_credits": 400]]).spend)
    }

    /// An absent limit is genuinely uncapped; a limit that is there and cannot
    /// be read poisons the report, because "no ceiling" is the one wrong answer
    /// a spend row must never give.
    func testAnUnreadableLimitYieldsNoReportAtAll() throws {
        XCTAssertNil(try parse(["spend": [
            "enabled": true,
            "used": ["amount_minor": 3_284, "currency": "USD"],
            "limit": ["amount_minor": "as much as you like"]
        ]]).spend)

        let uncapped = try XCTUnwrap(try parse(["spend": [
            "enabled": true,
            "used": ["amount_minor": 3_284, "currency": "USD"]
        ]]).spend)
        XCTAssertNil(uncapped.limitMinor)
        XCTAssertNil(uncapped.percent, "an uncapped spend is not a fraction of anything")
    }
}

/// Which organisation the usage call is made against.
final class ClaudeOrganizationTests: XCTestCase {
    private let payload: [Any] = [
        ["uuid": "org-first", "name": "Acme Inc", "rate_limit_tier": "Default_Claude_Team"],
        ["uuid": "org-active", "name": "someone@example.com's Organization", "rate_limit_tier": "Default_Claude_Max_20X"]
    ]

    /// Array order is not the organisation the user is working in. The browser
    /// writes that into `lastActiveOrg`, and on an account in several orgs it
    /// is the only thing that knows.
    func testPrefersTheActiveOrganisationOverArrayOrder() {
        let organizations = ClaudeOrganization.list(in: payload)
        XCTAssertEqual(organizations.count, 2)
        XCTAssertEqual(ClaudeOrganization.choose(from: organizations, hint: "org-active")?.id, "org-active")
        XCTAssertEqual(
            ClaudeOrganization.choose(from: organizations, hint: nil)?.id, "org-first",
            "with nothing to go on the list's own order stands"
        )
    }

    /// An id this session has no membership in is not somewhere to go asking
    /// for usage, whatever wrote it.
    func testAHintMatchingNothingLosesToTheList() {
        let organizations = ClaudeOrganization.list(in: payload)
        XCTAssertEqual(ClaudeOrganization.choose(from: organizations, hint: "org-elsewhere")?.id, "org-first")
    }

    /// `uuid` is what claude.ai answers with and `id` is what the other routes
    /// call the same field. Reading only the first lost the whole list.
    func testAcceptsEitherSpellingOfTheIdentifier() {
        let organizations = ClaudeOrganization.list(in: [
            ["id": "org-a", "name": "A"],
            ["nothing": true],
            ["uuid": "  ", "name": "blank"]
        ])
        XCTAssertEqual(organizations.map(\.id), ["org-a"])
    }

    /// The routes that are not a list of organisations each bury the id
    /// somewhere different, and any of them may be the only one answering.
    func testFindsTheIdentifierInTheOtherRoutes() {
        XCTAssertEqual(ClaudeOrganization.identifier(in: ["organization_id": "org-a"]), "org-a")
        XCTAssertEqual(ClaudeOrganization.identifier(in: ["org_id": "org-b"]), "org-b")
        XCTAssertEqual(ClaudeOrganization.identifier(in: ["organizations": [["id": "org-c"]]]), "org-c")
        XCTAssertEqual(
            ClaudeOrganization.identifier(in: ["account": ["lastActiveOrgId": "org-d"]]), "org-d",
            "bootstrap names the active organisation outright"
        )
        XCTAssertEqual(
            ClaudeOrganization.identifier(in: [
                "account": ["memberships": [["organization": ["uuid": "org-e"]]]]
            ]),
            "org-e"
        )
        XCTAssertNil(ClaudeOrganization.identifier(in: ["account": ["memberships": []]]))
    }

    /// The tier and the account label come from this list and nowhere else,
    /// which is why it is still fetched when the cookie already knows the id.
    func testCarriesTheTierAndTheName() {
        let chosen = ClaudeOrganization.choose(from: ClaudeOrganization.list(in: payload), hint: "org-active")
        XCTAssertEqual(chosen?.tier, "Default_Claude_Max_20X")
        XCTAssertEqual(chosen?.name, "someone@example.com's Organization")
    }
}

/// The two 403s, which aibars must never confuse: it discards a browser cookie
/// on `sessionExpired`, so reading a challenge as an expiry costs the user a
/// session that was working.
final class ClaudeResponseFailureTests: XCTestCase {
    private func failure(_ status: Int, _ body: String) -> ProviderError? {
        ClaudeUsageParser.failure(status: status, body: Data(body.utf8))
    }

    func testSuccessIsNoFailure() {
        XCTAssertNil(failure(200, "[]"))
    }

    func testTheNamedSessionFailureIsAnExpiry() throws {
        let error = try XCTUnwrap(failure(403, #"{"error":{"type":"account_session_invalid"}}"#))
        guard case .sessionExpired = error else { return XCTFail("expected an expiry, got \(error)") }
    }

    func testAnUnnamed403IsABlock() throws {
        let error = try XCTUnwrap(failure(403, "<html>Attention Required! | Cloudflare</html>"))
        guard case .blocked = error else { return XCTFail("expected a block, got \(error)") }
        XCTAssertFalse(error.isAuth, "a challenge must not cost the user their session")
    }

    func testAnUnauthorisedResponseIsStillAnExpiry() throws {
        let error = try XCTUnwrap(failure(401, ""))
        guard case .sessionExpired = error else { return XCTFail("expected an expiry, got \(error)") }
    }

    func testRateLimitingAndEverythingElse() throws {
        guard case .rateLimited = try XCTUnwrap(failure(429, "")) else {
            return XCTFail("429 is a rate limit")
        }
        guard case .network = try XCTUnwrap(failure(500, "boom")) else {
            return XCTFail("500 is a network failure")
        }
    }
}
