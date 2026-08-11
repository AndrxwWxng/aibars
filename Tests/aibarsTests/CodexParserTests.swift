import XCTest
@testable import aibarsCore

final class CodexUsageParserTests: XCTestCase {
    /// 2026-08-05T15:06:40Z. Fixed, because half of what this parser produces is
    /// a date arrived at by adding a countdown to the current instant.
    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    // MARK: - The documented shape

    func testParsesBothWindowsCreditsAndPlan() throws {
        let raw: [String: Any] = [
            "plan_type": "pro",
            "rate_limit": [
                "primary_window": [
                    "used_percent": 41.2,
                    "limit_window_seconds": 18_000,
                    "reset_at": 1_786_007_200,
                    "reset_after_seconds": 7_200
                ],
                "secondary_window": [
                    "used_percent": 88,
                    "limit_window_seconds": 604_800,
                    "reset_at": 1_786_300_000
                ]
            ],
            "credits": ["balance": 821.7, "has_credits": true]
        ]

        let data = try CodexUsageParser.parse(raw, headers: [:], account: "ada@example.com", now: now)

        XCTAssertEqual(data.providerID, "codex")
        XCTAssertEqual(data.planName, "Pro 20×")
        XCTAssertEqual(data.accountLabel, "ada@example.com")

        // Busiest first: the weekly cap at 88% is the window at risk, not the
        // session at 41%. Credits are appended after the sort and stay last.
        XCTAssertEqual(data.primary.label, "Weekly")
        XCTAssertEqual(data.secondary.map(\.label), ["5h session", "Credits"])

        XCTAssertEqual(data.primary.used, 88, accuracy: 0.001)
        XCTAssertEqual(data.primary.limit, 100)
        XCTAssertEqual(data.primary.unit, "%")
        XCTAssertEqual(data.primary.windowLabel, "Weekly")
        XCTAssertEqual(data.primary.windowDuration, 604_800)
        XCTAssertEqual(data.primary.resetDate, Date(timeIntervalSince1970: 1_786_300_000))

        let session = try XCTUnwrap(data.secondary.first)
        XCTAssertEqual(session.used, 41.2, accuracy: 0.001)
        XCTAssertEqual(session.percent, 0.412, accuracy: 0.001)
        XCTAssertEqual(session.windowDuration, 18_000)
        // `reset_at` is absolute and wins over the countdown beside it.
        XCTAssertEqual(session.resetDate, Date(timeIntervalSince1970: 1_786_007_200))
    }

    // MARK: - A slot is not a kind

    /// The bug this parser exists to avoid: OpenAI drops one of the two limits
    /// and promotes the weekly window into `primary_window`. Reading the slot
    /// then tells a user their afternoon frees up in six days.
    func testWeeklyWindowInThePrimarySlotIsStillLabelledWeekly() throws {
        let raw: [String: Any] = ["rate_limit": ["primary_window": [
            "used_percent": 62,
            "limit_window_seconds": 604_800
        ]]]

        let data = try CodexUsageParser.parse(raw, headers: [:], now: now)

        XCTAssertEqual(data.primary.label, "Weekly")
        XCTAssertEqual(data.primary.windowLabel, "Weekly")
        XCTAssertEqual(data.primary.windowDuration, 604_800)
        XCTAssertTrue(data.secondary.isEmpty)
    }

    /// And the mirror image, so the classification is not just "primary means
    /// weekly now".
    func testSessionWindowInTheSecondarySlotIsStillLabelledSession() throws {
        let raw: [String: Any] = ["rate_limit": ["secondary_window": [
            "used_percent": 5,
            "limit_window_seconds": 18_000
        ]]]

        let data = try CodexUsageParser.parse(raw, headers: [:], now: now)
        XCTAssertEqual(data.primary.label, "5h session")
        XCTAssertEqual(data.primary.windowDuration, 18_000)
    }

    /// With no duration in the payload there is nothing to classify by, so the
    /// slot decides and the row says as much by carrying no `windowDuration`:
    /// no duration means no pace notch, rather than a notch on a house guess.
    func testWithoutADurationTheSlotDecidesAndNoDurationIsClaimed() throws {
        let raw: [String: Any] = ["rate_limit": [
            "primary_window": ["used_percent": 70],
            "secondary_window": ["used_percent": 30]
        ]]

        let data = try CodexUsageParser.parse(raw, headers: [:], now: now)

        XCTAssertEqual(data.primary.label, "5h session")
        XCTAssertEqual(data.secondary.map(\.label), ["Weekly"])
        XCTAssertNil(data.primary.windowDuration)
        XCTAssertNil(try XCTUnwrap(data.secondary.first).windowDuration)
    }

    /// A window length OpenAI has not published before is named after itself.
    /// Forcing it into one of the two familiar names is the slot mistake again.
    func testAnUnfamiliarWindowIsNamedAfterItsOwnLength() throws {
        XCTAssertEqual(try label(durationSeconds: 3_600), "1h window")
        XCTAssertEqual(try label(durationSeconds: 1_800), "30m window")
        XCTAssertEqual(try label(durationSeconds: 86_400), "1d window")
        // One second either side of each familiar length. Neither is the window
        // the familiar name describes, and both say so — "5h window" is a
        // five-hour cap of some other kind, not the 5h session.
        XCTAssertEqual(try label(durationSeconds: 17_999), "5h window")
        XCTAssertEqual(try label(durationSeconds: 18_001), "5h window")
        XCTAssertEqual(try label(durationSeconds: 604_799), "7d window")
        XCTAssertEqual(try label(durationSeconds: 604_801), "7d window")
    }

    /// The bounds on what counts as a window length at all. Below a minute there
    /// is no readable name, so the slot name stands; past a year it is not a
    /// usage window, and `Int(_:)` on it would trap rather than mislabel.
    func testImplausibleWindowLengthsFallBackToTheSlotAndNeverTrap() throws {
        let year: Double = 366 * 24 * 60 * 60
        XCTAssertEqual(try label(durationSeconds: year), "366d window")
        XCTAssertEqual(try label(durationSeconds: year + 1), "5h session")
        XCTAssertEqual(try label(durationSeconds: 60), "1m window")
        XCTAssertEqual(try label(durationSeconds: 59), "5h session")
        XCTAssertEqual(try label(durationSeconds: 0), "5h session")
        XCTAssertEqual(try label(durationSeconds: -18_000), "5h session")
        XCTAssertEqual(try label(durationSeconds: 1e300), "5h session")

        // Nothing implausible reaches the row as a denominator either.
        for seconds in [0, -18_000, 1e300, year + 1] as [Double] {
            let data = try CodexUsageParser.parse(
                ["rate_limit": ["primary_window": ["used_percent": 10, "limit_window_seconds": seconds]]],
                headers: [:],
                now: now
            )
            XCTAssertNil(data.primary.windowDuration, "\(seconds) is not a window length")
        }
    }

    // MARK: - Headers

    /// The header and the body carry the same percentage. The header is the only
    /// source left when the body omits one, and header names are case-insensitive
    /// so the casing the server chose cannot matter.
    func testPercentagesComeFromTheHeadersWhenTheBodyOmitsThem() throws {
        let raw: [String: Any] = ["rate_limit": [
            "primary_window": ["limit_window_seconds": 18_000, "reset_after_seconds": 600],
            "secondary_window": ["limit_window_seconds": 604_800]
        ]]
        let headers = [
            "X-Codex-Primary-Used-Percent": "41.2",
            "x-codex-secondary-used-percent": "88"
        ]

        let data = try CodexUsageParser.parse(raw, headers: headers, now: now)

        XCTAssertEqual(data.primary.label, "Weekly")
        XCTAssertEqual(data.primary.used, 88, accuracy: 0.001)
        let session = try XCTUnwrap(data.secondary.first)
        XCTAssertEqual(session.used, 41.2, accuracy: 0.001)
        // The header carries a figure and nothing else; the duration and the
        // reset still come from the body.
        XCTAssertEqual(session.windowDuration, 18_000)
        XCTAssertEqual(session.resetDate, now.addingTimeInterval(600))
    }

    func testTheBodyOutranksTheHeaderWhenBothArePresent() throws {
        let data = try CodexUsageParser.parse(
            ["rate_limit": ["primary_window": ["used_percent": 12]]],
            headers: ["x-codex-primary-used-percent": "99"],
            now: now
        )
        XCTAssertEqual(data.primary.used, 12, accuracy: 0.001)
    }

    /// A response with no body worth reading but a header that still measured
    /// something is a reading, not a failure.
    func testHeadersAloneStillProduceAWindow() throws {
        let data = try CodexUsageParser.parse(
            [:],
            headers: ["x-codex-primary-used-percent": "7"],
            now: now
        )
        XCTAssertEqual(data.primary.label, "5h session")
        XCTAssertEqual(data.primary.used, 7, accuracy: 0.001)
        XCTAssertNil(data.primary.windowDuration)
        XCTAssertNil(data.primary.resetDate)
    }

    func testHeadersThatAreNotFiguresContributeNothing() {
        for value in ["", " ", "n/a", "nan", "inf", "-inf"] {
            assertParseError([:], headers: ["x-codex-primary-used-percent": value])
        }
    }

    // MARK: - Resets

    /// `reset_at` is the absolute epoch second and `reset_after_seconds` the
    /// countdown to the same instant. Both spellings have to land on one date.
    func testTheAbsoluteResetAndTheCountdownAgree() throws {
        let absolute = try window(["used_percent": 50, "reset_at": 1_786_007_200])
        let countdown = try window(["used_percent": 50, "reset_after_seconds": 7_200])

        XCTAssertEqual(absolute.resetDate, Date(timeIntervalSince1970: 1_786_007_200))
        XCTAssertEqual(absolute.resetDate, countdown.resetDate)
    }

    func testResetsThatAreNotResets() throws {
        // Epoch zero is how an absent timestamp is spelled by a server that will
        // not send null, and it is fifty-six years in the past.
        XCTAssertNil(try window(["used_percent": 1, "reset_at": 0]).resetDate)
        // Zero seconds away is now, which is a real answer: the window has just
        // turned over.
        XCTAssertEqual(try window(["used_percent": 1, "reset_after_seconds": 0]).resetDate, now)
        // A countdown that has run backwards is not a date.
        XCTAssertNil(try window(["used_percent": 1, "reset_after_seconds": -60]).resetDate)
        XCTAssertNil(try window(["used_percent": 1, "reset_at": NSNull(), "reset_after_seconds": NSNull()]).resetDate)
        XCTAssertNil(try window(["used_percent": 1, "reset_at": "soon"]).resetDate)
        // `true` bridges to a number that reads as 1: one second past the epoch
        // is not a reset, and neither is one second from now.
        XCTAssertNil(try window(["used_percent": 1, "reset_at": true, "reset_after_seconds": true]).resetDate)

        // A dead `reset_at` falls through to the countdown beside it.
        let both = try window(["used_percent": 1, "reset_at": 0, "reset_after_seconds": 300])
        XCTAssertEqual(both.resetDate, now.addingTimeInterval(300))
    }

    // MARK: - Percentages

    func testPercentagesAtAndPastTheirBounds() throws {
        // Kept verbatim on Codex's own 0…100 scale: 1% on an untouched window is
        // reported as 1%.
        XCTAssertEqual(try window(["used_percent": 0]).used, 0)
        XCTAssertEqual(try window(["used_percent": 0]).percent, 0)
        XCTAssertEqual(try window(["used_percent": 100]).percent, 1)

        // Past the cap is the moment the row matters most, so the figure stands
        // and only the meter tops out.
        let over = try window(["used_percent": 130])
        XCTAssertEqual(over.used, 130, accuracy: 0.001)
        XCTAssertEqual(over.percent, 1)

        // Below zero is not a reading anybody can act on.
        XCTAssertEqual(try window(["used_percent": -5]).used, 0)

        // Figures arriving as text are normal for this class of API.
        XCTAssertEqual(try window(["used_percent": "37.5"]).used, 37.5, accuracy: 0.001)
    }

    /// `Double("nan")` parses, `true` bridges to a number that reads as 1, and
    /// either one reaching a metric puts a figure nobody sent on a meter — a NaN
    /// survives `UsageMetric.percent` and lands in the meter's own layout.
    func testNonFiniteAndBooleanPercentagesAreNotReadings() throws {
        for value in ["nan", "inf", "-inf", "NaN"] as [Any] {
            assertParseError(["rate_limit": ["primary_window": ["used_percent": value]]])
        }
        assertParseError(["rate_limit": ["primary_window": ["used_percent": true]]])
        assertParseError(["rate_limit": ["primary_window": ["used_percent": NSNull()]]])

        // And a window that survives beside them carries a drawable figure.
        let data = try CodexUsageParser.parse(
            ["rate_limit": [
                "primary_window": ["used_percent": "nan"],
                "secondary_window": ["used_percent": 20]
            ]],
            headers: [:],
            now: now
        )
        XCTAssertEqual(data.primary.label, "Weekly")
        let all = [data.primary] + data.secondary
        XCTAssertTrue(all.allSatisfy { $0.used.isFinite && $0.limit.isFinite && $0.percent.isFinite })
    }

    /// A window with no percentage from either source is a window this account
    /// does not have. A track at 0% would claim it exists and is untouched.
    func testAWindowWithNoFigureIsAbsentRatherThanZero() throws {
        let data = try CodexUsageParser.parse(
            ["rate_limit": [
                "primary_window": ["limit_window_seconds": 18_000, "reset_at": 1_786_007_200],
                "secondary_window": ["used_percent": 3]
            ]],
            headers: [:],
            now: now
        )
        XCTAssertEqual([data.primary.label] + data.secondary.map(\.label), ["Weekly"])
    }

    // MARK: - Spark

    func testSparkEntriesBecomeTheirOwnRows() throws {
        let raw: [String: Any] = [
            "rate_limit": ["primary_window": ["used_percent": 10, "limit_window_seconds": 18_000]],
            "additional_rate_limits": [
                ["limit_name": "GPT-5.3-Codex-SPARK", "metered_feature": "spark", "rate_limit": [
                    "primary_window": ["used_percent": 64, "limit_window_seconds": 18_000],
                    "secondary_window": ["used_percent": 30, "limit_window_seconds": 604_800]
                ]]
            ]
        ]

        let data = try CodexUsageParser.parse(raw, headers: [:], now: now)

        // Scoped in the row label, unscoped in the window label: the window is a
        // five-hour session whoever is spending against it.
        XCTAssertEqual(data.primary.label, "Spark · 5h session")
        XCTAssertEqual(data.primary.windowLabel, "5h session")
        XCTAssertEqual(data.primary.windowDuration, 18_000)
        XCTAssertEqual(data.secondary.map(\.label), ["Spark · Weekly", "5h session"])
    }

    /// Matched on either field, case-insensitively, so a change of wording on one
    /// of them still resolves the limit.
    func testSparkIsMatchedOnEitherFieldWhateverItsCasing() throws {
        let byName: [String: Any] = ["limit_name": "gpt-5.3-codex-spark", "rate_limit": [
            "primary_window": ["used_percent": 12]
        ]]
        let byFeature: [String: Any] = ["metered_feature": "SPARK", "rate_limit": [
            "primary_window": ["used_percent": 12]
        ]]

        for entry in [byName, byFeature] {
            let data = try CodexUsageParser.parse(["additional_rate_limits": [entry]], headers: [:], now: now)
            XCTAssertEqual(data.primary.label, "Spark · 5h session")
        }
    }

    /// The array is a list of named caps and only the first match is drawn: two
    /// entries matching would put two rows called the same thing on screen.
    func testOnlyTheFirstSparkEntryIsDrawnAndOthersAreIgnored() throws {
        let raw: [String: Any] = ["additional_rate_limits": [
            // Not Spark, and not an error either — accounts carry limits this
            // app has no row for.
            ["limit_name": "GPT-5-Codex-Mini", "rate_limit": ["primary_window": ["used_percent": 99]]],
            ["metered_feature": "spark", "rate_limit": ["primary_window": ["used_percent": 40]]],
            ["metered_feature": "spark", "rate_limit": ["primary_window": ["used_percent": 41]]]
        ]]

        let data = try CodexUsageParser.parse(raw, headers: [:], now: now)
        XCTAssertEqual(data.primary.label, "Spark · 5h session")
        XCTAssertEqual(data.primary.used, 40, accuracy: 0.001)
        XCTAssertTrue(data.secondary.isEmpty)
    }

    /// An account without the limit simply has no entry, which is the common case
    /// and never an error, and never an empty row.
    func testNoSparkEntryProducesNoSparkRow() throws {
        let variants: [Any?] = [
            nil,
            [Any](),
            NSNull(),
            "spark",
            // The array holding something that is not an entry at all.
            ["spark"],
            // Named, but with nothing to measure inside it.
            [["metered_feature": "spark"]],
            [["metered_feature": "spark", "rate_limit": [String: Any]()]]
        ]

        for variant in variants {
            var raw: [String: Any] = ["rate_limit": ["primary_window": ["used_percent": 10]]]
            if let variant { raw["additional_rate_limits"] = variant }

            let data = try CodexUsageParser.parse(raw, headers: [:], now: now)
            let labels = [data.primary.label] + data.secondary.map(\.label)
            XCTAssertEqual(labels, ["5h session"], "\(String(describing: variant))")
        }
    }

    // MARK: - Credits

    /// Codex floors the count before pricing it. Pricing 821.7 credits at 4¢
    /// gives $32.868, and a dollar figure two cents away from what the service
    /// itself shows is worse than none.
    func testCreditsAreFlooredBeforeTheyArePriced() throws {
        let report = try XCTUnwrap(CodexUsageParser.credits(in: ["credits": ["balance": 821.7]], headers: [:]))

        XCTAssertEqual(report.amountMinor, 3_284)
        XCTAssertEqual(report.amount, try XCTUnwrap(Decimal(string: "32.84")))
        XCTAssertEqual(report.currency, "USD")
        XCTAssertEqual(report.period, .lifetime)
        XCTAssertEqual(report.confidence, .measured)
        // A balance is not spent against a ceiling, so there is none to be a
        // fraction of.
        XCTAssertNil(report.limitMinor)
        XCTAssertNil(report.percent)

        // The row `parse` emits is the same figure in the shape the list can draw.
        let data = try CodexUsageParser.parse(["credits": ["balance": 821.7]], headers: [:], now: now)
        XCTAssertEqual(data.primary.label, "Credits")
        XCTAssertEqual(data.primary.used, 32.84, accuracy: 0.0001)
        XCTAssertEqual(data.primary.unit, "USD")
        // Prepaid credit has no ceiling: limit 0 keeps a healthy balance from
        // rendering as fully consumed.
        XCTAssertEqual(data.primary.limit, 0)
        XCTAssertEqual(data.primary.percent, 0)
        XCTAssertNil(data.primary.windowDuration)
    }

    func testCreditBalancesAtTheirEdges() throws {
        // A measured zero earns its row: "you have none left" is an answer.
        XCTAssertEqual(CodexUsageParser.credits(in: ["credits": ["balance": 0]], headers: [:])?.amountMinor, 0)
        // No credit facility at all says so rather than reporting a balance, and
        // that is still a measured zero.
        XCTAssertEqual(
            CodexUsageParser.credits(in: ["credits": ["has_credits": false]], headers: [:])?.amountMinor,
            0
        )
        // A negative balance is not money owed to draw a row about.
        XCTAssertEqual(CodexUsageParser.credits(in: ["credits": ["balance": -5]], headers: [:])?.amountMinor, 0)
        // Sub-credit balances floor to nothing, which is what Codex shows.
        XCTAssertEqual(CodexUsageParser.credits(in: ["credits": ["balance": 0.99]], headers: [:])?.amountMinor, 0)
        XCTAssertEqual(CodexUsageParser.credits(in: ["credits": ["balance": 1]], headers: [:])?.amountMinor, 4)

        // Clamped before the conversion, because `Int(_:)` traps above `Int.max`
        // and a payload is not a promise.
        XCTAssertEqual(
            CodexUsageParser.credits(in: ["credits": ["balance": 1e18]], headers: [:])?.amountMinor,
            4_000_000_000
        )
    }

    func testABalanceThatIsNotAFigureIsNotABalance() {
        // `has_credits: true` with no number attached says a facility exists, not
        // how much is in it.
        XCTAssertNil(CodexUsageParser.credits(in: ["credits": ["has_credits": true]], headers: [:]))
        XCTAssertNil(CodexUsageParser.credits(in: ["credits": ["balance": NSNull()]], headers: [:]))
        XCTAssertNil(CodexUsageParser.credits(in: ["credits": ["balance": "nan"]], headers: [:]))
        XCTAssertNil(CodexUsageParser.credits(in: ["credits": ["balance": true]], headers: [:]))
        XCTAssertNil(CodexUsageParser.credits(in: ["credits": "none"], headers: [:]))
        XCTAssertNil(CodexUsageParser.credits(in: [:], headers: [:]))
    }

    func testTheCreditsHeaderStandsInForAnAbsentBody() throws {
        let fromHeader = try XCTUnwrap(CodexUsageParser.credits(
            in: [:],
            headers: ["X-Codex-Credits-Balance": "821.7"]
        ))
        XCTAssertEqual(fromHeader.amountMinor, 3_284)

        // The body wins where it has a figure of its own.
        let both = try XCTUnwrap(CodexUsageParser.credits(
            in: ["credits": ["balance": 10]],
            headers: ["x-codex-credits-balance": "999"]
        ))
        XCTAssertEqual(both.amountMinor, 40)

        // A body that names the field without a number falls through to it.
        let unreadableBody = try XCTUnwrap(CodexUsageParser.credits(
            in: ["credits": ["balance": NSNull(), "has_credits": true]],
            headers: ["x-codex-credits-balance": "3"]
        ))
        XCTAssertEqual(unreadableBody.amountMinor, 12)
    }

    /// Credits are appended after the busiest-first sort, so they sit last
    /// however large the figure is — $821 of credit is not an 821% window.
    func testCreditsNeverOutrankAWindow() throws {
        let raw: [String: Any] = [
            "rate_limit": ["primary_window": ["used_percent": 1]],
            "credits": ["balance": 821.7]
        ]
        let data = try CodexUsageParser.parse(raw, headers: [:], now: now)
        XCTAssertEqual(data.primary.label, "5h session")
        XCTAssertEqual(data.secondary.map(\.label), ["Credits"])
    }

    /// An account with credit and no window at all is still worth a card.
    func testCreditsAloneCarryTheCard() throws {
        let data = try CodexUsageParser.parse(["credits": ["balance": 12.9]], headers: [:], now: now)
        XCTAssertEqual(data.primary.label, "Credits")
        XCTAssertEqual(data.primary.used, 0.48, accuracy: 0.0001)
        XCTAssertTrue(data.secondary.isEmpty)
    }

    // MARK: - Plans

    /// The two Pro tiers name the rate multiplier Codex sells rather than a rank,
    /// so nobody could guess them; every other tier is tidied the way the rest of
    /// aibars tidies a plan identifier.
    func testPlanTypesMapAsDocumented() throws {
        XCTAssertEqual(try planName("prolite"), "Pro 5×")
        XCTAssertEqual(try planName("pro"), "Pro 20×")
        XCTAssertEqual(try planName("PRO"), "Pro 20×")
        XCTAssertEqual(try planName("  prolite  "), "Pro 5×")
        XCTAssertEqual(try planName("plus"), "Plus")
        XCTAssertEqual(try planName("business"), "Business")
        XCTAssertEqual(try planName("enterprise_plan"), "Enterprise")
    }

    func testAnAbsentOrUnreadablePlanIsNotInvented() throws {
        XCTAssertNil(try planName(nil))
        XCTAssertNil(try planName(""))
        XCTAssertNil(try planName("   "))
        XCTAssertNil(try planName(NSNull()))
        XCTAssertNil(try planName(5))
        XCTAssertNil(try planName(true))
    }

    // MARK: - Responses that are not answers

    func testEmptyAndUnreadablePayloadsThrow() {
        assertParseError([:])
        // A plan with nothing measured against it is not a usage card.
        assertParseError(["plan_type": "pro"])
        // What a signed-out request answers with, minus the redirect.
        assertParseError(["detail": "Unauthorized"])
        assertParseError(["rate_limit": [:]])
        assertParseError(["rate_limit": NSNull()])
        assertParseError(["rate_limit": "unavailable"])
        assertParseError(["rate_limit": ["primary_window": "unavailable"]])
        assertParseError(["credits": ["has_credits": true]])
    }

    // MARK: - The payload the panel keeps

    /// `rawJSON` is persisted and shown in the raw-response field, so it has to
    /// survive the round trip it is stored for.
    func testTheStoredPayloadRoundTrips() throws {
        let raw: [String: Any] = [
            "plan_type": "pro",
            "rate_limit": ["primary_window": ["used_percent": 41.2]]
        ]

        let data = try CodexUsageParser.parse(raw, headers: [:], now: now)
        let encoded = try XCTUnwrap(data.rawJSON)
        let decoded = try JSONSerialization.jsonObject(
            with: try XCTUnwrap(Data(base64Encoded: encoded))
        ) as? [String: Any]

        XCTAssertEqual(decoded?["plan_type"] as? String, "pro")
    }

    /// `data(withJSONObject:)` raises an Objective-C exception rather than
    /// throwing for a value that is not JSON, and `parse` is public: anything can
    /// hand it a dictionary. The card still has to arrive, minus the copy of the
    /// payload it could not make.
    func testAPayloadThatIsNotJSONStillProducesACardWithNoStoredCopy() throws {
        let raw: [String: Any] = [
            "rate_limit": ["primary_window": ["used_percent": 41.2]],
            "fetched": Date(timeIntervalSince1970: 1_786_000_000)
        ]

        let data = try CodexUsageParser.parse(raw, headers: [:], now: now)
        XCTAssertEqual(data.primary.used, 41.2, accuracy: 0.001)
        XCTAssertNil(data.rawJSON)
    }

    // MARK: - Helpers

    /// One window in the primary slot, as a metric.
    private func window(
        _ payload: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> UsageMetric {
        let data = try CodexUsageParser.parse(
            ["rate_limit": ["primary_window": payload]],
            headers: [:],
            now: now
        )
        XCTAssertTrue(data.secondary.isEmpty, file: file, line: line)
        return data.primary
    }

    private func label(durationSeconds: Double) throws -> String {
        try window(["used_percent": 10, "limit_window_seconds": durationSeconds]).label
    }

    private func planName(_ value: Any?) throws -> String? {
        var raw: [String: Any] = ["rate_limit": ["primary_window": ["used_percent": 1]]]
        if let value { raw["plan_type"] = value }
        return try CodexUsageParser.parse(raw, headers: [:], now: now).planName
    }

    private func assertParseError(
        _ raw: [String: Any],
        headers: [String: String] = [:],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try CodexUsageParser.parse(raw, headers: headers, now: now),
            file: file,
            line: line
        ) { error in
            guard let providerError = error as? ProviderError, case .parse = providerError else {
                XCTFail("Expected ProviderError.parse, got \(error)", file: file, line: line)
                return
            }
        }
    }
}
