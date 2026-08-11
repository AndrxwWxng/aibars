import XCTest
@testable import aibarsCore

final class GrokUsageParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_742_000_000)

    func testParsesDocumentedRateLimitShape() throws {
        let raw: [String: Any] = [
            "windowSizeSeconds": 7200,
            "remainingQueries": 24,
            "waitTimeSeconds": 0,
            "totalQueries": 25,
            "remainingTokens": 8830,
            "totalTokens": 10000,
            "lowEffortRateLimits": ["cost": 1, "waitTimeSeconds": 0, "remainingQueries": 24],
            "highEffortRateLimits": ["cost": 5, "waitTimeSeconds": 0, "remainingQueries": 4],
            "preGenerationDelayMs": 0
        ]
        let subscriptions: [String: Any] = [
            "subscriptions": [
                ["tier": "SUBSCRIPTION_TIER_SUPER_GROK_PRO", "status": "SUBSCRIPTION_STATUS_ACTIVE"]
            ]
        ]

        let data = try GrokUsageParser.parse(raw, subscriptions: subscriptions, now: now)

        XCTAssertEqual(data.providerID, "grok")
        XCTAssertEqual(data.planName, "SuperGrokPro")
        XCTAssertEqual(data.primary.label, "Queries")
        XCTAssertEqual(data.primary.used, 1, accuracy: 0.001)
        XCTAssertEqual(data.primary.limit, 25, accuracy: 0.001)
        XCTAssertEqual(data.primary.unit, "queries")
        // waitTimeSeconds is 0, so there is nothing to count down to: the 7200
        // window length is a cadence, not a reset time.
        XCTAssertNil(data.primary.resetDate)
        XCTAssertEqual(data.primary.windowLabel, "every 2h")

        XCTAssertEqual(data.secondary.map(\.label), ["Tokens", "Low effort left", "High effort left"])
        let tokens = try XCTUnwrap(data.secondary.first)
        XCTAssertEqual(tokens.used, 1170, accuracy: 0.001)
        XCTAssertEqual(tokens.limit, 10000, accuracy: 0.001)
        // The effort buckets have no ceiling of their own — status-only.
        XCTAssertEqual(data.secondary[1].used, 24, accuracy: 0.001)
        XCTAssertEqual(data.secondary[1].limit, 0)
        XCTAssertEqual(data.secondary[1].percent, 0)
    }

    func testSnakeCaseKeysInsideWrapperFallsBackToTokens() throws {
        let raw: [String: Any] = [
            "data": [
                "window_size_seconds": 86_400,
                "total_tokens": "10000",
                "remaining_tokens": "2500",
                "low_effort_rate_limits": ["remaining_queries": 7]
            ]
        ]

        let data = try GrokUsageParser.parse(raw, now: now)

        // No totalQueries, so the token pool is the meter.
        XCTAssertEqual(data.primary.label, "Tokens")
        XCTAssertEqual(data.primary.used, 7500, accuracy: 0.001)
        XCTAssertEqual(data.primary.limit, 10000, accuracy: 0.001)
        XCTAssertEqual(data.primary.unit, "tokens")
        XCTAssertEqual(data.primary.windowLabel, "every 1d")
        XCTAssertEqual(data.primary.windowDuration, 86_400)
        XCTAssertEqual(data.primary.windowKey, "tokens")
        XCTAssertEqual(data.secondary.map(\.label), ["Low effort left"])
        XCTAssertEqual(data.secondary.first?.used, 7)
        // A snake_cased payload keys to the same window as a camel one: the key
        // is pinned to the canonical field name, so the two spellings cannot
        // file the same bucket as two series.
        XCTAssertEqual(data.secondary.first?.windowKey, "lowEffortRateLimits")
        // Subscriptions weren't fetched, so no tier can be claimed.
        XCTAssertEqual(data.planName, "Grok")
    }

    func testExhaustedWindowUsesWaitTimeForReset() throws {
        let raw: [String: Any] = [
            "windowSizeSeconds": 7200,
            "waitTimeSeconds": 900,
            "totalQueries": 25,
            "remainingQueries": 0
        ]

        let data = try GrokUsageParser.parse(raw, now: now)

        XCTAssertEqual(data.primary.used, 25, accuracy: 0.001)
        XCTAssertEqual(data.primary.percent, 1, accuracy: 0.001)
        // The wait, not the window length: 900s away, not 7200s.
        XCTAssertEqual(data.primary.resetDate, now.addingTimeInterval(900))
        XCTAssertEqual(data.primary.windowLabel, "every 2h")
    }

    func testMissingRemainingReadsAsUntouched() throws {
        let data = try GrokUsageParser.parse(["totalQueries": 25], now: now)

        XCTAssertEqual(data.primary.used, 0)
        XCTAssertEqual(data.primary.limit, 25, accuracy: 0.001)
        XCTAssertNil(data.primary.resetDate)
        XCTAssertNil(data.primary.windowLabel)
    }

    func testFreeUsageGatesCoverAnEmptyRateLimitWindow() throws {
        let gates: [String: Any] = [
            "chat": ["allowance": 20, "remaining": 5],
            "imagine": ["allowance": 10, "remaining": 10],
            "voice": ["allowance": 0, "remaining": 0]
        ]

        let data = try GrokUsageParser.parse(["preGenerationDelayMs": 0], gates: gates, now: now)

        XCTAssertEqual(data.primary.label, "Chat")
        XCTAssertEqual(data.primary.used, 15, accuracy: 0.001)
        XCTAssertEqual(data.primary.limit, 20, accuracy: 0.001)
        XCTAssertEqual(data.primary.windowLabel, "free tier")
        // A gate says how much is left, never how long it runs for, so it gets
        // no duration and therefore no pace notch.
        XCTAssertNil(data.primary.windowDuration)
        XCTAssertEqual(data.primary.windowKey, "chat")
        // A zero-allowance surface is not a meter and is dropped.
        XCTAssertEqual(data.secondary.map(\.label), ["Imagine"])
        XCTAssertEqual(data.secondary.map(\.windowKey), ["imagine"])
    }

    /// Grok publishes its window length outright, so the pace notch is drawn on
    /// a stated figure. `windowLabel` is the sentence grok.com writes and
    /// `windowDuration` is the number the meter measures with; both come off
    /// the same field and must agree.
    func testStatedWindowLengthCarriesThroughAsADuration() throws {
        let raw: [String: Any] = [
            "windowSizeSeconds": 7200,
            "waitTimeSeconds": 900,
            "totalQueries": 25,
            "remainingQueries": 0,
            "totalTokens": 10000,
            "remainingTokens": 8830,
            "highEffortRateLimits": ["remainingQueries": 4]
        ]

        let data = try GrokUsageParser.parse(raw, now: now)

        XCTAssertEqual(data.primary.windowDuration, 7200)
        XCTAssertEqual(data.primary.windowLabel, "every 2h")
        XCTAssertEqual(data.primary.windowKey, "queries")

        let tokens = try XCTUnwrap(data.secondary.first)
        XCTAssertEqual(tokens.windowDuration, 7200)
        XCTAssertEqual(tokens.windowKey, "tokens")

        // A remaining count with no ceiling and no stated length: it keeps the
        // field it came from and takes the window's duration no more than it
        // takes its ceiling.
        let effort = try XCTUnwrap(data.secondary.last)
        XCTAssertEqual(effort.label, "High effort left")
        XCTAssertEqual(effort.windowKey, "highEffortRateLimits")
        XCTAssertNil(effort.windowDuration)
    }

    /// Absent, zero, negative, unreadable, or too large to be seconds: every one
    /// of them leaves the metric without a duration rather than with a house
    /// default. A notch on an invented denominator is an invented instrument,
    /// and the key is unaffected either way.
    func testUnstatedOrUnusableWindowLengthLeavesNoDuration() throws {
        let lengths: [Any?] = [nil, 0, -60, "soon", 400 * 24 * 60 * 60]

        for length in lengths {
            var raw: [String: Any] = ["totalQueries": 25, "remainingQueries": 10]
            if let length { raw["windowSizeSeconds"] = length }

            let data = try GrokUsageParser.parse(raw, now: now)

            let stated = length.map { String(describing: $0) } ?? "no windowSizeSeconds"
            XCTAssertNil(data.primary.windowDuration, "\(stated) is not a window length")
            XCTAssertEqual(data.primary.windowKey, "queries", "\(stated) moved the key")
        }
    }

    func testPlanNameTakesHighestActiveTier() {
        let subscriptions: [String: Any] = [
            "subscriptions": [
                ["tier": "SUBSCRIPTION_TIER_SUPER_GROK_PRO", "status": "SUBSCRIPTION_STATUS_INACTIVE"],
                ["tier": "SUBSCRIPTION_TIER_GROK_PRO", "status": "SUBSCRIPTION_STATUS_ACTIVE"],
                ["tier": "SUBSCRIPTION_TIER_X_PREMIUM", "status": "SUBSCRIPTION_STATUS_ACTIVE"]
            ]
        ]
        // GROK_PRO deliberately displays as "SuperGrok", and the inactive
        // higher tier must not win.
        XCTAssertEqual(GrokUsageParser.planName(from: subscriptions), "SuperGrok")
    }

    func testPlanNameDefaultsToFreeAndStaysVagueForUnknownTiers() {
        XCTAssertEqual(GrokUsageParser.planName(from: [:]), "Free")
        XCTAssertEqual(GrokUsageParser.planName(from: ["subscriptions": []]), "Free")
        let unknown: [String: Any] = [
            "subscriptions": [["tier": "SUBSCRIPTION_TIER_SUPER_GROK_ULTRA", "status": "SUBSCRIPTION_STATUS_ACTIVE"]]
        ]
        XCTAssertEqual(GrokUsageParser.planName(from: unknown), "Grok")
    }

    func testEmptyAndGarbageResponsesThrowParseError() {
        assertParseError([:])
        // The unauthenticated body, minus the 401 the HTTP layer would have
        // turned into .sessionExpired.
        assertParseError(["code": 16, "message": "No credentials presented."])
        // Right keys, useless values.
        assertParseError(["totalQueries": 0, "totalTokens": "not-a-number"])
    }

    private func assertParseError(_ raw: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try GrokUsageParser.parse(raw, now: now), file: file, line: line) { error in
            guard case ProviderError.parse = error else {
                return XCTFail("Expected ProviderError.parse, got \(error)", file: file, line: line)
            }
        }
    }
}
