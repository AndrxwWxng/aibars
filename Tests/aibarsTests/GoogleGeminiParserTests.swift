import XCTest
@testable import aibarsCore

final class GoogleGeminiUsageParserTests: XCTestCase {
    // The literal buckets captured from a live Pro account. Each is
    // [creditsRemaining, fractionUsed, windowType, [[resetSeconds, nanos]]];
    // window type 1 is the rolling ~5-hour pool, 2 is the week. The payload puts
    // the weekly bucket first, which the parser must not depend on.
    private let proWeekly: [Any] = [46815, 0.03241196, 2, [[1779799240, 527944000]]]
    private let proFiveHour: [Any] = [2396, 0.01, 1, [[1779428440, 527781000]]]

    func testParsesCapturedProPayload() throws {
        let payload: [Any] = [2, [proWeekly, proFiveHour], false]
        let data = try GoogleGeminiUsageParser.parse(["payload": payload])

        XCTAssertEqual(data.providerID, "gemini")
        XCTAssertEqual(data.planName, "Google AI Pro")

        // The rolling window leads even though it arrives second.
        XCTAssertEqual(data.primary.label, "5 Hours")
        XCTAssertEqual(data.primary.used, 1.0, accuracy: 0.001)
        XCTAssertEqual(data.primary.limit, 100)
        XCTAssertEqual(data.primary.unit, "%")
        XCTAssertEqual(data.primary.windowLabel, "5h window")
        XCTAssertEqual(data.primary.resetDate, Date(timeIntervalSince1970: 1779428440))

        let weekly = try XCTUnwrap(data.secondary.first)
        XCTAssertEqual(weekly.label, "Weekly")
        XCTAssertEqual(weekly.used, 3.2, accuracy: 0.001)
        XCTAssertEqual(weekly.limit, 100)
        XCTAssertEqual(weekly.resetDate, Date(timeIntervalSince1970: 1779799240))

        // Credits remaining has no ceiling in the payload, so it stays status-only.
        let credits = data.secondary.filter { $0.unit == "credits" }
        XCTAssertEqual(credits.map(\.label), ["5h credits left", "Weekly credits left"])
        XCTAssertEqual(credits.first?.used, 2396)
        XCTAssertEqual(credits.first?.limit, 0)
        XCTAssertEqual(credits.first?.percent, 0)
    }

    func testAlternativeWrapperKeyAndFreeTier() throws {
        // Captured free-account payload, under `data` rather than `payload`.
        let weekly: [Any] = [11937, 0.01312496, 2, [[1779993414, 980543000]]]
        let fiveHour: [Any] = [599, 0.01, 1, [[1779442614, 980412000]]]
        let payload: [Any] = [1, [weekly, fiveHour], false]

        let data = try GoogleGeminiUsageParser.parse(["data": payload])
        XCTAssertEqual(data.planName, "Free")
        XCTAssertEqual(data.primary.label, "5 Hours")
        XCTAssertEqual(data.primary.used, 1.0, accuracy: 0.001)
        XCTAssertEqual(data.secondary.first?.label, "Weekly")
        XCTAssertEqual(data.secondary.first?.used ?? 0, 1.3, accuracy: 0.001)
    }

    func testDecodesBatchExecuteEnvelope() throws {
        // The chunk lengths are deliberately wrong: they are skipped, not
        // trusted. The rpcid is also not the one we asked for, which must not
        // matter — the payload is found by shape, because Google rotates ids.
        let body = #"""
        )]}'

        142
        [["wrb.fr","Xy9Zab","[2,[[2277,0.05,1,[[1779446440,527781000]]],[45244,0.06488441,2,[[1779799240,527944000]]]],false]",null,null,null,"generic"],["di",25],["af.httprm",25,"7301",6]]
        26
        [["e",4,null,null,131]]
        """#

        let data = try GoogleGeminiUsageParser.parse(GoogleGeminiUsageParser.envelope(body))
        XCTAssertEqual(data.primary.used, 5.0, accuracy: 0.001)
        XCTAssertEqual(data.secondary.first?.used ?? 0, 6.5, accuracy: 0.001)

        // The same body handed straight to the parser.
        let direct = try GoogleGeminiUsageParser.parse(["body": body])
        XCTAssertEqual(direct.primary.used, 5.0, accuracy: 0.001)
        XCTAssertEqual(direct.planName, "Google AI Pro")
    }

    func testUltraSentinelBucketIsSkipped() throws {
        // Ultra payloads carry an internal type-4 entry with no reset timestamp.
        let sentinel: [Any] = [4, 0.0, 4, NSNull()]
        let fiveHour: [Any] = [12000, 0.2, 1, [[1779446440, 1]]]
        let weekly: [Any] = [240000, 0.42, 2, [[1779799240, 1]]]
        let payload: [Any] = [6, [sentinel, fiveHour, weekly], true]

        let data = try GoogleGeminiUsageParser.parse(["payload": payload])
        XCTAssertEqual(data.planName, "Google AI Ultra")
        XCTAssertEqual(data.primary.used, 20, accuracy: 0.001)
        XCTAssertEqual(data.secondary.map(\.label), ["Weekly", "5h credits left", "Weekly credits left"])
    }

    func testUnknownPlanTierHasNoLabel() throws {
        let bucket: [Any] = [500, 0.5, 1, [[1779446440, 0]]]
        let payload: [Any] = [99, [bucket], false]

        let data = try GoogleGeminiUsageParser.parse(["payload": payload])
        XCTAssertNil(data.planName)
        XCTAssertEqual(data.primary.used, 50, accuracy: 0.001)
        XCTAssertTrue(data.secondary.contains { $0.label == "5h credits left" })
    }

    func testNamedWindowsCarryTheirLengthAndTheirType() throws {
        let payload: [Any] = [2, [proWeekly, proFiveHour], false]
        let data = try GoogleGeminiUsageParser.parse(["payload": payload])

        // The pace notch needs both ends of the window, and window type 1 is the
        // five-hour pool the label already names in words.
        XCTAssertEqual(data.primary.windowDuration, 5 * 60 * 60)
        XCTAssertEqual(data.primary.windowKey, "window_type_1")

        let weekly = try XCTUnwrap(data.secondary.first)
        XCTAssertEqual(weekly.windowDuration, 7 * 24 * 60 * 60)
        XCTAssertEqual(weekly.windowKey, "window_type_2")

        // Credits remaining is a balance, not a window: no length to notch.
        let credits = try XCTUnwrap(data.secondary.first { $0.unit == "credits" })
        XCTAssertNil(credits.windowDuration)
    }

    func testUnnamedWindowIsKeyedOnItsTypeNotItsLabel() throws {
        // A window type aibars has no name for gets a label this parser
        // generates, which is exactly the label that must not become the key.
        let unknown: [Any] = [900, 0.3, 7, [[1779446440, 1]]]
        let alone: [Any] = [2, [unknown], false]
        let crowded: [Any] = [2, [proWeekly, unknown, proFiveHour], false]

        let first = try GoogleGeminiUsageParser.parse(["payload": alone]).primary
        let crowdedData = try GoogleGeminiUsageParser.parse(["payload": crowded])
        let later = try XCTUnwrap(crowdedData.secondary.first { $0.unit == "%" && $0.label != "Weekly" })

        // One bucket in the payload or three, before its neighbours or after
        // them: one series.
        XCTAssertEqual(first.windowKey, "window_type_7")
        XCTAssertEqual(later.windowKey, first.windowKey)
        // And not the label, which the store would otherwise slugify into a key
        // that moves whenever the wording does.
        XCTAssertNotEqual(first.windowKey, HistorySeriesID.windowKey(for: first.label))

        // Never a denominator we made up: an unnamed window has no known length.
        XCTAssertNil(first.windowDuration)
        XCTAssertNil(later.windowDuration)
    }

    func testWeeklyOnlyPayloadLeadsWithWeekly() throws {
        let payload: [Any] = [2, [proWeekly], false]
        let data = try GoogleGeminiUsageParser.parse(["payload": payload])
        XCTAssertEqual(data.primary.label, "Weekly")
        XCTAssertEqual(data.primary.used, 3.2, accuracy: 0.001)
    }

    func testNanosAreNotMistakenForAResetDate() throws {
        // 527944000 is the nanosecond field, not an epoch; treating it as one
        // would render a reset date in 1986.
        let bucket: [Any] = [2396, 0.01, 1, [527944000]]
        let payload: [Any] = [2, [bucket], false]

        let data = try GoogleGeminiUsageParser.parse(["payload": payload])
        XCTAssertNil(data.primary.resetDate)
    }

    func testEmptyResponseThrowsParseError() {
        assertParseError([:])
    }

    func testGarbagePayloadThrowsParseError() {
        let junk: [Any] = ["nonsense", 7, ["quota": "unavailable"], [[1, 2], [3, 4]]]
        assertParseError(["payload": junk])
    }

    func testWireErrorRowThrowsParseError() {
        // batchexecute reports failures inside an HTTP 200; er[5] is the code.
        let body = #"""
        )]}'

        58
        [["er",null,null,null,null,400,null,null,null,[3]],["di",42]]
        """#
        XCTAssertThrowsError(try GoogleGeminiUsageParser.envelope(body)) { error in
            guard case ProviderError.parse(let message) = error else {
                return XCTFail("Expected ProviderError.parse, got \(error)")
            }
            XCTAssertTrue(message.contains("400"), "Expected the wire error code in \(message)")
            // The provider decides whether to re-scrape its tokens by matching
            // this prefix, so a reworded message must not silently drop the retry.
            XCTAssertTrue(
                message.hasPrefix(GoogleGeminiUsageParser.wireErrorPrefix),
                "Expected \(message) to start with the wire error prefix"
            )
        }
    }

    func testEmptyEnvelopeThrowsParseError() {
        XCTAssertThrowsError(try GoogleGeminiUsageParser.envelope(")]}'\n\n")) { error in
            guard case ProviderError.parse = error else {
                return XCTFail("Expected ProviderError.parse, got \(error)")
            }
        }
    }

    private func assertParseError(_ raw: [String: Any], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try GoogleGeminiUsageParser.parse(raw), file: file, line: line) { error in
            guard case ProviderError.parse = error else {
                return XCTFail("Expected ProviderError.parse, got \(error)", file: file, line: line)
            }
        }
    }
}
