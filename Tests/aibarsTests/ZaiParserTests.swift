import XCTest
@testable import aibarsCore

/// Z.ai is the one provider whose windows state their own length, so most of
/// what is asserted here is that nothing is inferred: the label, the duration
/// and the reset all come out of the entry that was actually sent, and a window
/// that does not carry them is left out or refused rather than guessed at.
final class ZaiUsageParserTests: XCTestCase {
    /// The shape a live GLM Coding Max account returns: two token windows that
    /// name their own lengths, and the monthly search count.
    private let sessionEntry: [String: Any] = [
        "type": "TOKENS_LIMIT", "unit": 3, "number": 5,
        "percentage": 25, "nextResetTime": 1_770_648_402_389
    ]
    private let weeklyEntry: [String: Any] = [
        "type": "TOKENS_LIMIT", "unit": 6, "number": 1,
        "percentage": 61, "nextResetTime": 1_771_000_000_000
    ]
    private let searchEntry: [String: Any] = [
        "type": "TIME_LIMIT", "unit": 5, "number": 1,
        "currentValue": 12, "usage": 1000, "nextResetTime": 1_772_000_000_000
    ]

    // MARK: - The documented payload

    func testParsesEveryWindowBusiestFirst() throws {
        let subscription: [String: Any] = ["data": [["productName": "GLM Coding Max"]]]
        let data = try ZaiUsageParser.parse(
            quota([sessionEntry, weeklyEntry, searchEntry]),
            subscription: subscription
        )

        XCTAssertEqual(data.providerID, "zai")
        XCTAssertEqual(data.planName, "GLM Coding Max")
        // 61% beats 25% beats 12/1000, so the week is the limit at risk.
        XCTAssertEqual(data.primary.label, "Weekly")
        XCTAssertEqual(data.secondary.map(\.label), ["Session", "Web search"])

        XCTAssertEqual(data.primary.used, 61, accuracy: 0.001)
        XCTAssertEqual(data.primary.limit, 100, accuracy: 0.001)
        XCTAssertEqual(data.primary.unit, "%")
        // The length is on the metric and nowhere else: a "7d" beside the label
        // would be a second copy of the same fact.
        XCTAssertNil(data.primary.windowLabel)
    }

    func testWindowDurationComesFromTheEntryOnBothTokenWindows() throws {
        let data = try ZaiUsageParser.parse(quota([sessionEntry, weeklyEntry, searchEntry]))

        let weekly = try XCTUnwrap(data.primary.windowDuration)
        XCTAssertEqual(weekly, 7 * 24 * 3600, accuracy: 0.001)

        let session = try XCTUnwrap(data.secondary.first?.windowDuration)
        XCTAssertEqual(session, 5 * 3600, accuracy: 0.001)

        // (5, 1) is Z.ai's month, which it bills as 30 days.
        let search = try XCTUnwrap(data.secondary.last?.windowDuration)
        XCTAssertEqual(search, 30 * 24 * 3600, accuracy: 0.001)
    }

    func testSubDailyWindowIsTheSessionAndMultiDayTheWeek() throws {
        XCTAssertEqual(try firstWindow(tokens(unit: 3, number: 1)).label, "Session")
        XCTAssertEqual(try firstWindow(tokens(unit: 3, number: 5)).label, "Session")
        XCTAssertEqual(try firstWindow(tokens(unit: 6, number: 1)).label, "Weekly")
        XCTAssertEqual(try firstWindow(tokens(unit: 4, number: 3)).label, "Weekly")
    }

    /// Either side of the one boundary the labelling turns on. A day is not
    /// sub-daily, so 24h reads as the longer window.
    func testDayBoundaryDecidesTheLabel() throws {
        XCTAssertEqual(try firstWindow(tokens(unit: 3, number: 23)).label, "Session")
        XCTAssertEqual(try firstWindow(tokens(unit: 3, number: 24)).label, "Weekly")
        XCTAssertEqual(try firstWindow(tokens(unit: 4, number: 1)).label, "Weekly")
    }

    // MARK: - Reset times

    /// `nextResetTime` is epoch milliseconds. Taken as seconds it lands around
    /// the year 58000, which no countdown recovers from.
    func testResetTimeIsMillisecondsNotSeconds() throws {
        let data = try ZaiUsageParser.parse(quota([sessionEntry]))
        let reset = try XCTUnwrap(data.primary.resetDate)

        XCTAssertEqual(reset.timeIntervalSince1970, 1_770_648_402.389, accuracy: 0.001)
        XCTAssertLessThan(
            reset, Date(timeIntervalSince1970: 4_000_000_000),
            "the milliseconds were read as seconds"
        )
    }

    func testResetTimeAcceptsAStringAndRejectsNonsense() throws {
        let fromString = try XCTUnwrap(firstWindow(tokens(reset: "1770648402389")).resetDate)
        XCTAssertEqual(fromString.timeIntervalSince1970, 1_770_648_402.389, accuracy: 0.001)
        // Nothing to count down to, in each of the ways the field goes wrong.
        XCTAssertNil(try firstWindow(tokens(reset: 0)).resetDate)
        XCTAssertNil(try firstWindow(tokens(reset: -1_770_648_402_389)).resetDate)
        XCTAssertNil(try firstWindow(tokens(reset: true)).resetDate)
        XCTAssertNil(try firstWindow(tokens(reset: "soon")).resetDate)
        XCTAssertNil(try firstWindow(tokens()).resetDate)
    }

    // MARK: - The search count

    func testWebSearchWindowReadsUsageAsTheCeiling() throws {
        let metric = try firstWindow(searchEntry)

        XCTAssertEqual(metric.label, "Web search")
        // The field named for usage is the allowance, which reads backwards.
        XCTAssertEqual(metric.used, 12, accuracy: 0.001)
        XCTAssertEqual(metric.limit, 1000, accuracy: 0.001)
        XCTAssertEqual(metric.unit, "searches")
        XCTAssertEqual(metric.percent, 0.012, accuracy: 0.0001)
    }

    func testWebSearchWindowKeepsItsCountsWithoutAWindowPair() throws {
        // Identified by its type rather than its length, so a missing pair costs
        // the notch and nothing else.
        let metric = try firstWindow(["type": "TIME_LIMIT", "currentValue": 40, "usage": 200])
        XCTAssertNil(metric.windowDuration)
        XCTAssertEqual(metric.used, 40, accuracy: 0.001)
    }

    func testWebSearchWindowWithNothingSpentIsNotAnError() throws {
        let metric = try firstWindow(["type": "TIME_LIMIT", "currentValue": 0, "usage": 0])
        XCTAssertEqual(metric.used, 0)
        XCTAssertEqual(metric.limit, 0)
        // A zero ceiling is status-only, never a full meter.
        XCTAssertEqual(metric.percent, 0)
    }

    func testWebSearchWindowWithoutAUsableCountThrows() {
        assertParseError(quota([["type": "TIME_LIMIT", "usage": 200]]))
        assertParseError(quota([["type": "TIME_LIMIT", "currentValue": 40]]))
        assertParseError(quota([["type": "TIME_LIMIT", "currentValue": -1, "usage": 200]]))
        assertParseError(quota([["type": "TIME_LIMIT", "currentValue": 40, "usage": -200]]))
        assertParseError(quota([["type": "TIME_LIMIT", "currentValue": true, "usage": 200]]))
        assertParseError(quota([["type": "TIME_LIMIT", "currentValue": 40, "usage": Double.nan]]))
    }

    func testWebSearchCountsCoerceFromStrings() throws {
        let metric = try firstWindow(["type": "TIME_LIMIT", "currentValue": "12", "usage": "1000"])
        XCTAssertEqual(metric.used, 12, accuracy: 0.001)
        XCTAssertEqual(metric.limit, 1000, accuracy: 0.001)
    }

    // MARK: - Missing and malformed values

    /// A window with no usage figure is an invalid response. Reporting it as 0%
    /// would tell the user they have quota left when nothing said so.
    func testTokenWindowWithNoPercentageThrows() {
        assertParseError(quota([["type": "TOKENS_LIMIT", "unit": 3, "number": 5]]))
    }

    func testTokenWindowWithNoWindowLengthThrows() {
        assertParseError(quota([["type": "TOKENS_LIMIT", "number": 5, "percentage": 25]]))
        assertParseError(quota([["type": "TOKENS_LIMIT", "unit": 3, "percentage": 25]]))
        assertParseError(quota([tokens(unit: 3, number: 0)]))
        assertParseError(quota([tokens(unit: 3, number: -5)]))
        assertParseError(quota([tokens(unit: true, number: 5)]))
        assertParseError(quota([tokens(unit: 3, number: "many")]))
        assertParseError(quota([tokens(unit: 3, number: Double.infinity)]))
    }

    /// JSON `true` bridges to NSNumber and reads as 1, and `Double("nan")`
    /// succeeds; either would put a figure nobody sent on the meter.
    func testBooleanAndNonFinitePercentagesAreRefused() {
        assertParseError(quota([tokens(percentage: true)]))
        assertParseError(quota([tokens(percentage: Double.nan)]))
        assertParseError(quota([tokens(percentage: Double.infinity)]))
        assertParseError(quota([tokens(percentage: "nan")]))
        assertParseError(quota([tokens(percentage: NSNull())]))
        assertParseError(quota([tokens(percentage: ["value": 25])]))
    }

    func testPercentageIsClampedToTheWindowItReports() throws {
        XCTAssertEqual(try firstWindow(tokens(percentage: -5)).used, 0)
        XCTAssertEqual(try firstWindow(tokens(percentage: 140)).used, 100)
        XCTAssertEqual(try firstWindow(tokens(percentage: 140)).percent, 1.0, accuracy: 0.0001)
        XCTAssertEqual(try firstWindow(tokens(percentage: "92.4")).used, 92.4, accuracy: 0.001)
        XCTAssertEqual(try firstWindow(tokens(percentage: 0)).percent, 0)
    }

    // MARK: - Which entries survive

    /// A unit aibars has never seen is left out rather than guessed at, and it
    /// must not take the windows that are still understood down with it.
    func testUnrecognisedUnitIsDroppedWithoutHidingTheRest() throws {
        let future: [String: Any] = [
            "type": "TOKENS_LIMIT", "unit": 9, "number": 1, "percentage": 99
        ]
        let data = try ZaiUsageParser.parse(quota([future, sessionEntry]))

        XCTAssertEqual(data.primary.label, "Session")
        XCTAssertEqual(data.primary.used, 25, accuracy: 0.001)
        XCTAssertTrue(data.secondary.isEmpty)
    }

    func testAPayloadOfNothingButUnknownsThrows() {
        assertParseError(quota([["type": "TOKENS_LIMIT", "unit": 9, "number": 1, "percentage": 99]]))
        assertParseError(quota([["type": "SOMETHING_NEW", "percentage": 50]]))
        assertParseError(quota([[:]]))
    }

    /// The kind moved from `name` to `type`; both spellings still have to read.
    func testKindIsReadFromEitherField() throws {
        let older: [String: Any] = [
            "name": "TOKENS_LIMIT", "unit": 3, "number": 5, "percentage": 42
        ]
        XCTAssertEqual(try firstWindow(older).label, "Session")

        let olderSearch: [String: Any] = ["name": "TIME_LIMIT", "currentValue": 3, "usage": 9]
        XCTAssertEqual(try firstWindow(olderSearch).label, "Web search")
    }

    // MARK: - The envelope

    func testUnwrappedBodyIsAccepted() throws {
        // Dropping the `data` envelope is the cheapest way an internal API
        // changes shape, so a bare body still parses.
        let data = try ZaiUsageParser.parse(["limits": [sessionEntry]])
        XCTAssertEqual(data.primary.label, "Session")
    }

    func testDataThatIsNotAnObjectThrows() {
        assertParseError(["data": NSNull()])
        assertParseError(["data": "limits"])
        assertParseError(["data": 5])
        assertParseError(["data": [sessionEntry]])
    }

    func testMalformedLimitsThrows() {
        assertParseError([:])
        assertParseError(["data": [:]])
        assertParseError(["data": ["limits": "none"]])
        assertParseError(["data": ["limits": ["TOKENS_LIMIT"]]])
        assertParseError(["data": ["limits": NSNull()]])
    }

    /// An empty array is a real state — a plan that has metered nothing — but a
    /// row needs a reading, and a made-up zero is not one.
    func testEmptyLimitsThrowsRatherThanDrawingAnEmptyCard() {
        assertParseError(quota([]))
    }

    // MARK: - Plan name

    func testNilSubscriptionStillProducesEveryMeter() throws {
        let data = try ZaiUsageParser.parse(quota([sessionEntry, weeklyEntry, searchEntry]))

        XCTAssertNil(data.planName)
        XCTAssertEqual(data.secondary.count, 2)
        XCTAssertEqual(data.primary.used, 61, accuracy: 0.001)
    }

    func testSubscriptionWithNoCodingPlanKeepsTheMetersItHas() throws {
        // The quota route answered, so there is usage to show; the subscription
        // route simply has no product to name.
        let data = try ZaiUsageParser.parse(quota([sessionEntry]), subscription: ["data": []])
        XCTAssertNil(data.planName)
        XCTAssertEqual(data.primary.label, "Session")

        let unnamed = try ZaiUsageParser.parse(
            quota([sessionEntry]),
            subscription: ["success": false, "msg": "no active coding plan"]
        )
        XCTAssertNil(unnamed.planName)
        XCTAssertEqual(unnamed.primary.used, 25, accuracy: 0.001)
    }

    func testPlanNameIsTidiedAndReadsEitherKey() throws {
        XCTAssertEqual(try planName(["data": [["productName": "GLM Coding Plan Max"]]]), "GLM Coding Max")
        XCTAssertEqual(try planName(["data": [["product_name": "GLM-Coding-Plan-Lite"]]]), "GLM Coding Lite")
        // An empty name is not a name: the next subscription gets its turn.
        XCTAssertEqual(
            try planName(["data": [["productName": ""], ["productName": "GLM Coding Pro"]]]),
            "GLM Coding Pro"
        )
    }

    func testPlanNameIsAbsentWhenTheSubscriptionShapeIsWrong() throws {
        XCTAssertNil(try planName([:]))
        XCTAssertNil(try planName(["data": "GLM Coding Max"]))
        XCTAssertNil(try planName(["data": ["GLM Coding Max"]]))
        XCTAssertNil(try planName(["data": [["productName": 5]]]))
        XCTAssertNil(try planName(["data": [[:]]]))
    }

    // MARK: - No coding plan

    /// A valid key on an account with no plan: nothing is malformed, so this is
    /// configuration, and the message has to say what to do about it.
    func testNoCodingPlanIsAConfigurationErrorNotAParseFailure() {
        let refusal: [String: Any] = [
            "success": false, "code": 500,
            "msg": "The current account has not subscribed to the coding plan"
        ]
        XCTAssertThrowsError(try ZaiUsageParser.parse(refusal)) { error in
            guard let providerError = error as? ProviderError,
                  case .configuration(let message) = providerError else {
                return XCTFail("Expected ProviderError.configuration, got \(error)")
            }
            XCTAssertTrue(message.contains("GLM Coding Plan"))
            XCTAssertTrue(message.contains("z.ai/subscribe"))
        }
    }

    func testAnUnrelatedBusinessFailureDoesNotClaimToKnowTheCause() {
        // No mention of a coding plan, so nothing here knows why it failed.
        assertParseError(["success": false, "code": 500, "msg": "internal error"])
        assertParseError(["success": false])
        // `success: true` is not a refusal, whatever the message says.
        assertParseError(["success": true, "msg": "coding plan"])
    }

    func testSuccessFlagAlongsideRealLimitsStillParses() throws {
        var payload = quota([sessionEntry])
        payload["success"] = true
        XCTAssertEqual(try ZaiUsageParser.parse(payload).primary.label, "Session")
    }

    // MARK: - Raw JSON

    func testRawJSONCarriesBothPayloads() throws {
        let subscription: [String: Any] = ["data": [["productName": "GLM Coding Max"]]]
        let data = try ZaiUsageParser.parse(quota([sessionEntry]), subscription: subscription)

        let encoded = try XCTUnwrap(data.rawJSON)
        let decoded = try XCTUnwrap(Data(base64Encoded: encoded))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded) as? [String: Any])

        XCTAssertNotNil(object["quota"] as? [String: Any])
        XCTAssertNotNil(object["subscription"] as? [String: Any])
    }

    func testRawJSONHoldsAnEmptySubscriptionWhenThereWasNone() throws {
        let data = try ZaiUsageParser.parse(quota([sessionEntry]))
        let encoded = try XCTUnwrap(data.rawJSON)
        let decoded = try XCTUnwrap(Data(base64Encoded: encoded))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: decoded) as? [String: Any])

        XCTAssertEqual((object["subscription"] as? [String: Any])?.isEmpty, true)
    }

    /// `parse` is public, and `data(withJSONObject:)` raises rather than throws
    /// for a value that is not JSON. Losing the debug copy is fine; taking the
    /// meters down with it is not.
    func testAValueThatIsNotJSONCostsTheRawCopyAndNothingElse() throws {
        var payload = quota([sessionEntry])
        payload["stamp"] = Date()

        let data = try ZaiUsageParser.parse(payload)
        XCTAssertEqual(data.primary.label, "Session")
        XCTAssertNil(data.rawJSON)
    }

    // MARK: - Helpers

    private func quota(_ limits: [[String: Any]]) -> [String: Any] {
        ["data": ["limits": limits]]
    }

    /// A token window with every field defaulted to something valid, so each
    /// test can spoil exactly one of them.
    private func tokens(
        unit: Any = 3,
        number: Any = 5,
        percentage: Any = 25,
        reset: Any? = nil
    ) -> [String: Any] {
        var entry: [String: Any] = [
            "type": "TOKENS_LIMIT", "unit": unit, "number": number, "percentage": percentage
        ]
        if let reset { entry["nextResetTime"] = reset }
        return entry
    }

    private func firstWindow(_ entry: [String: Any]) throws -> UsageMetric {
        try ZaiUsageParser.parse(quota([entry])).primary
    }

    private func planName(_ subscription: [String: Any]) throws -> String? {
        try ZaiUsageParser.parse(quota([sessionEntry]), subscription: subscription).planName
    }

    private func assertParseError(
        _ raw: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try ZaiUsageParser.parse(raw), file: file, line: line) { error in
            guard let providerError = error as? ProviderError, case .parse = providerError else {
                XCTFail("Expected ProviderError.parse, got \(error)", file: file, line: line)
                return
            }
        }
    }
}

/// The provider around the parser: identity, where it sends the user, and what
/// it does with a credential it has not been given.
final class ZaiProviderTests: XCTestCase {
    /// Account ids no real install uses, so nothing here can overwrite a
    /// credential or a preference somebody depends on.
    private let probeIDs = ["zai#probe-enabled", "zai#probe-token", "zai#probe-empty"]

    override func setUp() {
        super.setUp()
        // A run that crashed out could have left either behind, and both are
        // read at construction.
        forgetProbes()
    }

    override func tearDown() {
        forgetProbes()
        super.tearDown()
    }

    private func forgetProbes() {
        for id in probeIDs {
            SessionStore.shared.clear(id)
            UserDefaults.standard.removeObject(forKey: "aibars.\(id).enabled")
        }
    }

    @MainActor
    func testAccountsGetDistinctIdsButShareTheService() {
        let first = ZaiProvider()
        let second = ZaiProvider(accountID: "2")

        XCTAssertEqual(first.id, "zai")
        XCTAssertNil(first.accountID)
        XCTAssertEqual(second.id, "zai#2")
        XCTAssertEqual(second.accountID, "2")
        XCTAssertEqual(first.serviceID, second.serviceID)
        XCTAssertEqual(first.serviceID, "zai")
        XCTAssertEqual(first.displayName, "Z.ai")
    }

    @MainActor
    func testSendsTheUserToPagesOnTheServiceItTracks() throws {
        let provider = ZaiProvider()

        XCTAssertEqual(try XCTUnwrap(provider.dashboardURL).host, "z.ai")

        let login = try XCTUnwrap(provider.webLogin)
        XCTAssertEqual(login.startURL.host, "z.ai")
        XCTAssertEqual(login.dataDomains, ["z.ai"])
        // The key is copied off the page; there is no cookie to watch for.
        guard case .tokenShownOnPage = login.capture else {
            return XCTFail("expected the pasted-key flow, got \(login.capture)")
        }
    }

    @MainActor
    func testEnabledStateIsPersistedPerAccount() {
        let provider = ZaiProvider(accountID: "probe-enabled")
        XCTAssertTrue(provider.isEnabled, "a new account starts shown")

        provider.setEnabled(false)
        XCTAssertFalse(ZaiProvider(accountID: "probe-enabled").isEnabled)
    }

    /// The key is copied off a page that puts a newline after it, and whatever
    /// is stored goes into an Authorization header verbatim.
    @MainActor
    func testPastedKeyIsTrimmedBeforeItIsStored() throws {
        let provider = ZaiProvider(accountID: "probe-token")
        try provider.saveTokenManually("  0123abc.def \n")

        XCTAssertEqual(SessionStore.shared.token(for: "zai#probe-token"), "0123abc.def")
    }

    @MainActor
    func testSignOutRemovesTheCredential() async throws {
        let provider = ZaiProvider(accountID: "probe-token")
        try provider.saveTokenManually("0123abc.def")

        try await provider.signOut()

        XCTAssertNil(SessionStore.shared.token(for: "zai#probe-token"))
        // The metadata goes too, so a provider built after this starts out
        // disconnected rather than claiming a key it no longer has.
        XCTAssertFalse(SessionStore.shared.hasCredential(for: "zai#probe-token"))
    }

    /// No credential means no request: a second account never inherits the
    /// environment key, so this cannot reach the network.
    @MainActor
    func testFetchWithoutACredentialReportsItRatherThanAsking() async {
        SessionStore.shared.clear("zai#probe-empty")
        let provider = ZaiProvider(accountID: "probe-empty")

        do {
            _ = try await provider.fetchUsage()
            XCTFail("fetch should not succeed without a credential")
        } catch let error as ProviderError {
            XCTAssertTrue(error.isAuth, "expected an auth error, got \(error)")
        } catch {
            XCTFail("expected a ProviderError, got \(error)")
        }
    }
}
