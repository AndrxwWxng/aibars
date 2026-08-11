import XCTest
@testable import aibarsCore

/// Claude Code is the one provider whose input is a filesystem rather than a
/// payload, and the one with no ceiling to measure against.
///
/// Both of those are what these tests are about. The row must report tokens and
/// never a percentage, because nobody on this machine publishes a denominator;
/// the money must say it was estimated, because it is list prices applied to a
/// subscription; and the logs are untrusted input, because they are appended to
/// while we read them and half of what is in them is not a turn.
///
/// The shaping is tested against handwritten `ClaudeCodeTotals`, which is what
/// `ClaudeCodeReport` exists apart from the provider for. Only the cases that
/// genuinely need a directory get one.
final class ClaudeCodeProviderTests: XCTestCase {
    private var root: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("aibars-claudecode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A scratch domain, so the index's watermark never lands in the settings
        // of whoever is running the tests.
        suiteName = "aibars.tests.claudecode.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        defaults.removePersistentDomain(forName: suiteName)
        try super.tearDownWithError()
    }

    // MARK: - The primary window

    func testThePrimaryWindowCountsTokensAndCarriesNoCeiling() {
        let data = ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: totals(session: bucket(input: 1_200, output: 800, cacheCreation: 400, cacheRead: 10_000))
        )

        XCTAssertEqual(data.primary.label, "in the last 5h")
        XCTAssertEqual(data.primary.unit, "tokens")
        XCTAssertEqual(data.primary.windowLabel, "5h")
        XCTAssertNil(data.primary.resetDate, "the logs carry no reset time and one must not be invented")
        // The zero limit is the whole point: there is no local quota, so the row
        // is a figure and a bar would have to make its denominator up.
        XCTAssertEqual(data.primary.limit, 0)
        XCTAssertEqual(data.primary.percent, 0)
        // Cache reads are tokens the model processed. Leaving them out would
        // report 2.4k where the session actually cost 12.4k.
        XCTAssertEqual(data.primary.used, 12_400)
        XCTAssertNil(data.planName, "there is no plan on disk; the subscription belongs to claude.ai")
        XCTAssertNil(data.accountLabel)
    }

    /// A figure large enough to fill any invented meter still reads as no
    /// percentage at all, which is what keeps this row out of the menu bar's
    /// worst-first ordering and out of the alert thresholds.
    func testAHugeSessionIsStillNotAPercentage() {
        let data = ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: totals(session: bucket(input: .max / 8, output: .max / 8))
        )

        XCTAssertGreaterThan(data.primary.used, 0)
        XCTAssertEqual(data.primary.percent, 0)
    }

    /// A count below zero can only come from a corrupt persisted index. It must
    /// not become a percentage and it must not trap on the way to the row.
    func testANegativeCountIsNotAPercentageEither() {
        let data = ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: totals(session: bucket(input: -5_000, output: 1_000))
        )

        XCTAssertEqual(data.primary.used, -4_000)
        XCTAssertEqual(data.primary.percent, 0)
    }

    func testAnEmptyScanReportsZeroRatherThanNothing() {
        let data = ClaudeCodeReport.data(providerID: "claudecode", totals: .empty)

        XCTAssertEqual(data.primary.used, 0)
        XCTAssertEqual(data.primary.limit, 0)
        XCTAssertEqual(data.secondary.map(\.used), [0, 0, 0])
        // `.empty` is a directory that was read and held no turns, which is a
        // priced bucket of nothing rather than an unpriceable one.
        XCTAssertEqual(data.spend?.amountMinor, 0)
    }

    /// The doc comment on `sessionLabel` promises the row reads "45.0k tokens in
    /// the last 5h". This is the half of that sentence the metric owns.
    func testTheFigureIsAbbreviatedTheWayTheRowWillReadIt() {
        let data = ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: totals(session: bucket(input: 45_000))
        )

        XCTAssertEqual(data.primary.displayUsed, "45.0k")
    }

    // MARK: - The secondary windows

    func testSecondaryWindowsAreTodaySevenAndThirtyInThatOrder() {
        let data = ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: totals(
                today: bucket(input: 10),
                week: bucket(input: 20),
                month: bucket(input: 30)
            )
        )

        XCTAssertEqual(data.secondary.map(\.label), ["Today", "7 days", "30 days"])
        // Order is the widening one, and each window is the sum over its own
        // span rather than a share of the one before it.
        XCTAssertEqual(data.secondary.map(\.used), [10, 20, 30])
        XCTAssertEqual(data.secondary.map(\.limit), [0, 0, 0])
        XCTAssertEqual(data.secondary.compactMap(\.unit), ["tokens", "tokens", "tokens"])
        XCTAssertTrue(data.secondary.allSatisfy { $0.percent == 0 })
    }

    /// History files a reading under the window's key, so two windows sharing
    /// one key would merge into a single series and plot the wrong line.
    func testEachWindowKeysToItsOwnSeries() {
        let data = ClaudeCodeReport.data(providerID: "claudecode", totals: .empty)
        let keys = ([data.primary] + data.secondary)
            .map { HistorySeriesID.windowKey(for: $0.label) }

        XCTAssertEqual(Set(keys).count, 4, "the four windows must not collapse into one series")
        XCTAssertFalse(keys.contains("window"), "no label should fall through to the empty-label fallback")
    }

    // MARK: - Spend

    func testSpendIsAlwaysEstimatedAndNeverMeasured() throws {
        let data = ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: totals(month: bucket(input: 1_000, usd: 12.5))
        )
        let spend = try XCTUnwrap(data.spend)

        // Measured would claim this is the provider's own accounting. It is our
        // arithmetic over a rate card a subscription does not charge.
        XCTAssertEqual(spend.confidence, .estimated)
        XCTAssertEqual(spend.currency, "USD")
        XCTAssertEqual(spend.exponent, 2)
        XCTAssertEqual(spend.amountMinor, 1_250)
        XCTAssertNil(spend.limitMinor, "nobody publishes a ceiling for local Claude Code use")
        XCTAssertNil(spend.percent, "no ceiling means no fraction of one")
        XCTAssertNil(spend.resetDate)
        // A sliding thirty days, not the calendar month the index never aligns to.
        XCTAssertEqual(spend.period, .rollingHours(24 * 30))
    }

    func testSpendComesFromTheThirtyDayWindowNotTheSession() throws {
        let data = ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: totals(session: bucket(usd: 999), month: bucket(usd: 4))
        )

        XCTAssertEqual(try XCTUnwrap(data.spend).amountMinor, 400)
    }

    /// The first thing a new model does is arrive without a price. A bill
    /// missing one model is not a smaller bill, so the money goes away and the
    /// tokens — which were measured — stay.
    func testAnUnpricedModelLeavesSpendNilWhileTheTokensStillReport() {
        let data = ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: totals(
                session: bucket(input: 900, usd: nil),
                today: bucket(input: 900, usd: nil),
                week: bucket(input: 900, usd: nil),
                month: bucket(input: 900, output: 100, usd: nil)
            )
        )

        XCTAssertNil(data.spend)
        XCTAssertEqual(data.primary.used, 900)
        XCTAssertEqual(data.secondary.map(\.used), [900, 900, 1_000])
    }

    func testANonFiniteFigureIsNotABill() {
        for usd in [Double.nan, .infinity, -.infinity] {
            let data = ClaudeCodeReport.data(
                providerID: "claudecode",
                totals: totals(month: bucket(input: 10, usd: usd))
            )
            XCTAssertNil(data.spend, "\(usd) reached the spend row")
            XCTAssertEqual(data.secondary.last?.used, 10, "the tokens survive the unusable price")
        }
    }

    /// `Int(_:)` traps outside its range, so the guard either side of it is
    /// load-bearing rather than defensive.
    func testAnAbsurdFigureIsRefusedRatherThanTrapping() throws {
        // 9e13 dollars is 9e15 cents exactly, which is the first value refused.
        XCTAssertNil(ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: totals(month: bucket(usd: 9e13))
        ).spend)
        XCTAssertNil(ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: totals(month: bucket(usd: -9e13))
        ).spend, "the magnitude is what matters, not the sign")
        XCTAssertNil(ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: totals(month: bucket(usd: Double.greatestFiniteMagnitude))
        ).spend)

        // Just inside it, and still a number.
        let inside = try XCTUnwrap(ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: totals(month: bucket(usd: 8.9e13))
        ).spend)
        XCTAssertGreaterThan(inside.amountMinor, 0)
    }

    /// A negative total is unreachable through `ModelPricing`, which floors
    /// every rate at zero. If one ever arrives it is reported as it is: clamping
    /// it to zero would read as "nothing was spent", which is the lie in the
    /// other direction.
    func testANegativeTotalIsReportedRatherThanClamped() throws {
        let data = ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: totals(month: bucket(usd: -0.5))
        )

        XCTAssertEqual(try XCTUnwrap(data.spend).amountMinor, -50)
    }

    func testCentsAreRoundedRatherThanTruncated() throws {
        // 0.125 and 12.5 are both exact in binary, so this tests the rounding
        // rule and not the floating point underneath it.
        XCTAssertEqual(try XCTUnwrap(ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: totals(month: bucket(usd: 0.125))
        ).spend).amountMinor, 13)

        // A sub-cent charge is a real charge and must not floor to nothing.
        XCTAssertEqual(try XCTUnwrap(ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: totals(month: bucket(usd: 0.006))
        ).spend).amountMinor, 1)
    }

    // MARK: - The raw payload

    func testRawJSONCarriesThePerModelWorking() throws {
        let last = Date(timeIntervalSince1970: 1_800_000_000)
        let data = ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: totals(
                month: bucket(turns: 3, input: 1_200, output: 800, cacheCreation: 400, cacheRead: 10_000, usd: 0.0335),
                byModel: [
                    "claude-opus-5": bucket(turns: 3, input: 1_200, output: 800, cacheCreation: 400, cacheRead: 10_000, usd: 0.0335)
                ],
                lastTurnAt: last
            )
        )

        let payload = try rawObject(data)
        XCTAssertEqual(payload["source"] as? String, "claude-code")
        XCTAssertEqual(payload["window"] as? String, "30d")
        // The age of the rate card travels with the figure it priced, so a table
        // that has fallen behind is visible rather than merely wrong.
        XCTAssertEqual(payload["priced_as_of"] as? String, ModelPricing.asOf)
        XCTAssertEqual(ProviderDate.parse(payload["last_turn_at"] as? String ?? ""), last)

        let models = try XCTUnwrap(payload["models"] as? [String: Any])
        let entry = try XCTUnwrap(models["claude-opus-5"] as? [String: Any])
        XCTAssertEqual(entry["turns"] as? Int, 3)
        XCTAssertEqual(entry["input"] as? Int, 1_200)
        XCTAssertEqual(entry["output"] as? Int, 800)
        XCTAssertEqual(entry["cache_creation"] as? Int, 400)
        XCTAssertEqual(entry["cache_read"] as? Int, 10_000)
        XCTAssertEqual(entry["estimated_usd"] as? Double, 0.0335)
    }

    func testRawJSONOmitsAPriceItCouldNotWork() throws {
        let data = ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: totals(byModel: [
                "claude-unheard-of": bucket(turns: 1, input: 5, usd: nil),
                "claude-broken": bucket(turns: 1, input: 5, usd: Double.nan)
            ])
        )

        let models = try XCTUnwrap(try rawObject(data)["models"] as? [String: Any])
        for id in ["claude-unheard-of", "claude-broken"] {
            let entry = try XCTUnwrap(models[id] as? [String: Any])
            XCTAssertNil(entry["estimated_usd"], "\(id) published a price it does not have")
            XCTAssertEqual(entry["input"] as? Int, 5, "the tokens are known even when the money is not")
        }
    }

    func testRawJSONSaysNothingAboutALastTurnThatNeverHappened() throws {
        let payload = try rawObject(ClaudeCodeReport.data(providerID: "claudecode", totals: .empty))

        XCTAssertNil(payload["last_turn_at"])
        XCTAssertEqual((payload["models"] as? [String: Any])?.isEmpty, true)
    }

    /// A model id is a string out of a log file, so it can be anything. An id
    /// that made the payload unserialisable would cost the whole row its raw
    /// JSON, not just its own line.
    func testAnOddModelIdStillSerialises() throws {
        let data = ClaudeCodeReport.data(
            providerID: "claudecode",
            totals: totals(byModel: [
                "": bucket(turns: 1),
                "us.anthropic.claude-opus-5-v1:0": bucket(turns: 1),
                "emoji 🙂 / slash": bucket(turns: 1)
            ])
        )

        let models = try XCTUnwrap(try rawObject(data)["models"] as? [String: Any])
        XCTAssertEqual(models.count, 3)
    }

    func testTheProviderIDIsCarriedThrough() {
        let data = ClaudeCodeReport.data(providerID: "claudecode#2", totals: .empty)
        XCTAssertEqual(data.providerID, "claudecode#2")
    }

    // MARK: - Identity

    func testIdentityIsSharedAcrossAccountsAndTheIDIsNot() {
        let first = ClaudeCodeProvider(root: root, userDefaults: defaults)
        let second = ClaudeCodeProvider(accountID: "2", root: root, userDefaults: defaults)

        XCTAssertEqual(first.id, "claudecode")
        XCTAssertEqual(second.id, "claudecode#2")
        XCTAssertEqual(first.serviceID, second.serviceID)
        XCTAssertEqual(first.serviceID, "claudecode")
        XCTAssertEqual(first.displayName, "Claude Code")
        XCTAssertEqual(first.iconName, "terminal")
        // There is nothing to log into and no page anywhere that shows this.
        XCTAssertNil(first.webLogin)
        XCTAssertNil(first.dashboardURL)
    }

    // MARK: - Whether Claude Code has ever run here

    func testAnEmptyRootIsNotConnected() async {
        let provider = ClaudeCodeProvider(root: root, userDefaults: defaults)
        XCTAssertFalse(provider.isAuthenticated)

        do {
            _ = try await provider.fetchUsage()
            XCTFail("an empty log directory reported usage")
        } catch {
            assertNotAuthenticated(error)
        }
    }

    /// A directory holding nothing but a `.DS_Store` is a Claude Code that has
    /// never run, and calling it connected leaves a permanently empty row.
    func testADirectoryOfDotFilesIsNotConnected() throws {
        try Data().write(to: root.appendingPathComponent(".DS_Store"))

        XCTAssertFalse(ClaudeCodeProvider(root: root, userDefaults: defaults).isAuthenticated)
    }

    func testAMissingRootIsNotConnected() async {
        let missing = root.appendingPathComponent("nowhere", isDirectory: true)
        let provider = ClaudeCodeProvider(root: missing, userDefaults: defaults)

        XCTAssertFalse(provider.isAuthenticated)
        do {
            _ = try await provider.fetchUsage()
            XCTFail("a root that does not exist reported usage")
        } catch {
            assertNotAuthenticated(error)
        }
    }

    /// `CLAUDE_CONFIG_DIR` can point at anything, including a file.
    func testARootThatIsAFileIsNotConnected() throws {
        let file = root.appendingPathComponent("projects")
        try Data("not a directory".utf8).write(to: file)

        XCTAssertFalse(ClaudeCodeProvider(root: file, userDefaults: defaults).isAuthenticated)
    }

    func testAuthenticateFailsWithNothingToRead() async {
        let provider = ClaudeCodeProvider(root: root, userDefaults: defaults)

        do {
            try await provider.authenticate()
            XCTFail("authenticate succeeded against an empty directory")
        } catch let error as ProviderError {
            guard case .configuration = error else {
                return XCTFail("expected .configuration, got \(error)")
            }
        } catch {
            XCTFail("expected a ProviderError, got \(error)")
        }
        XCTAssertFalse(provider.isAuthenticated)
    }

    /// Someone who installs Claude Code after aibars gets a working row on the
    /// next refresh rather than on the next launch, so the question is asked
    /// again rather than answered once at init.
    func testAuthenticateNoticesAnInstallThatArrivedLater() async throws {
        let provider = ClaudeCodeProvider(root: root, userDefaults: defaults)
        XCTAssertFalse(provider.isAuthenticated)

        try writeTranscript(oneGoodTurn())
        try await provider.authenticate()

        XCTAssertTrue(provider.isAuthenticated)
    }

    // MARK: - Reading the logs

    func testOneSessionReportsItsTokensAndNoPercentage() async throws {
        try writeTranscript(oneGoodTurn())
        let provider = ClaudeCodeProvider(root: root, userDefaults: defaults)
        XCTAssertTrue(provider.isAuthenticated)

        let data = try await provider.fetchUsage()

        XCTAssertEqual(data.providerID, "claudecode")
        XCTAssertEqual(data.primary.used, 12_400)
        XCTAssertEqual(data.primary.limit, 0)
        XCTAssertEqual(data.primary.percent, 0)
        XCTAssertEqual(data.secondary.map(\.used), [12_400, 12_400, 12_400])
        XCTAssertEqual(data.spend?.confidence, SpendReport.Confidence.estimated)
    }

    /// Half of what is in a transcript is not a turn, and some of it is not even
    /// JSON. One unreadable line costs its own row and nothing else.
    func testMalformedLinesCostTheirOwnRowAndNothingElse() async throws {
        let at = Date().addingTimeInterval(-60)
        let lines = [
            "",
            "not json at all",
            "{",
            #"{"type":"user","message":{"content":"hi"}}"#,
            // An API error, rendered as an assistant turn. It reached no model.
            assistantLine(id: "msg_synth", model: "<synthetic>", at: at, usage: #""output_tokens":5"#),
            // `true` bridges to a number and would otherwise coerce to 1.
            assistantLine(id: "msg_bool", at: at, usage: #""input_tokens":true,"output_tokens":true"#),
            assistantLine(id: "msg_negative", at: at, usage: #""input_tokens":-500,"output_tokens":-1"#),
            // Beyond `Int`, which is not a token count at any scale.
            assistantLine(id: "msg_huge", at: at, usage: #""input_tokens":1e30"#),
            // No timestamp, so it belongs to no window and is dropped.
            #"{"type":"assistant","message":{"id":"msg_undated","model":"claude-opus-5","usage":{"input_tokens":9}}}"#,
            oneGoodTurn(at: at)
        ]
        // A final line that was still being written when we read the file.
        try writeTranscript(
            lines.joined(separator: "\n") + "\n" + #"{"type":"assistant","timestam"#,
            terminated: false
        )

        let data = try await ClaudeCodeProvider(root: root, userDefaults: defaults).fetchUsage()

        XCTAssertEqual(data.primary.used, 12_400, "a broken row contributed tokens")
        let models = try XCTUnwrap(try rawObject(data)["models"] as? [String: Any])
        XCTAssertEqual(
            Set(models.keys), ["claude-opus-5"],
            "a model nobody ran reached the per-model breakdown"
        )
    }

    /// Claude Code writes an assistant message once per content block as it
    /// streams, each line repeating the id with a larger output count. The last
    /// line supersedes the ones before it, or a turn caught mid-stream is
    /// recorded at six tokens for ever.
    func testAMessageWrittenTwiceIsCountedOnce() async throws {
        let at = Date().addingTimeInterval(-60)
        let text = [
            assistantLine(id: "msg_stream", at: at, usage: #""output_tokens":6"#),
            assistantLine(id: "msg_stream", at: at, usage: #""output_tokens":17000"#)
        ].joined(separator: "\n")
        try writeTranscript(text)

        let data = try await ClaudeCodeProvider(root: root, userDefaults: defaults).fetchUsage()

        XCTAssertEqual(data.primary.used, 17_000)
    }

    func testTwoRefreshesOverAnUnchangedRootAgree() async throws {
        try writeTranscript(oneGoodTurn())
        let provider = ClaudeCodeProvider(root: root, userDefaults: defaults)

        let first = try await provider.fetchUsage()
        let second = try await provider.fetchUsage()

        // Everything but the timestamp: a refresh that read nothing new must say
        // exactly what the one before it said, or the row jitters and the
        // forecast fits a line to noise.
        XCTAssertEqual(first.providerID, second.providerID)
        XCTAssertEqual(first.planName, second.planName)
        XCTAssertEqual(first.primary, second.primary)
        XCTAssertEqual(first.secondary, second.secondary)
        XCTAssertEqual(first.spend, second.spend)
        XCTAssertEqual(first.accountLabel, second.accountLabel)
        XCTAssertEqual(first.rawJSON, second.rawJSON)
        XCTAssertGreaterThanOrEqual(second.fetchedAt, first.fetchedAt)
    }

    /// The stored index is a defaults value written by an older version of this
    /// app, which makes it untrusted input. A value it cannot decode has to be
    /// dropped, not retried at every launch from now on.
    func testAMalformedStoredIndexIsDiscardedRatherThanTrusted() async throws {
        let key = "aibars.claudeCode.index"
        let garbage = Data("this was never an index".utf8)
        defaults.set(garbage, forKey: key)
        try writeTranscript(oneGoodTurn())

        let data = try await ClaudeCodeProvider(root: root, userDefaults: defaults).fetchUsage()

        XCTAssertEqual(data.primary.used, 12_400, "the sweep did not start from scratch")
        XCTAssertNotEqual(defaults.data(forKey: key), garbage, "the unusable value was left in place")
    }

    /// Well-formed JSON of the wrong shape fails at the same point, and must
    /// fail the same way.
    func testAStoredIndexOfTheWrongShapeIsAlsoDiscarded() async throws {
        let key = "aibars.claudeCode.index"
        defaults.set(Data(#"{"f":"not an array of files"}"#.utf8), forKey: key)
        try writeTranscript(oneGoodTurn())

        let data = try await ClaudeCodeProvider(root: root, userDefaults: defaults).fetchUsage()

        XCTAssertEqual(data.primary.used, 12_400)
    }

    // MARK: - Enabling, signing out, credentials

    func testEnabledDefaultsToTrueAndIsRemembered() {
        XCTAssertTrue(ClaudeCodeProvider(root: root, userDefaults: defaults).isEnabled)

        ClaudeCodeProvider(root: root, userDefaults: defaults).setEnabled(false)
        XCTAssertFalse(ClaudeCodeProvider(root: root, userDefaults: defaults).isEnabled)
    }

    func testTheEnabledFlagIsPerAccount() {
        ClaudeCodeProvider(root: root, userDefaults: defaults).setEnabled(false)

        XCTAssertTrue(
            ClaudeCodeProvider(accountID: "2", root: root, userDefaults: defaults).isEnabled,
            "hiding one root hid the other"
        )
    }

    /// The transcripts are the user's own history rather than anything aibars
    /// put there. Signing out of a local source can only mean stopping reading
    /// it; deleting the logs to satisfy a button would be vandalism.
    func testSigningOutStopsReadingAndLeavesTheLogsAlone() async throws {
        let file = try writeTranscript(oneGoodTurn())
        let provider = ClaudeCodeProvider(root: root, userDefaults: defaults)

        try await provider.signOut()

        XCTAssertFalse(provider.isEnabled)
        XCTAssertFalse(ClaudeCodeProvider(root: root, userDefaults: defaults).isEnabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "sign-out deleted the user's logs")
    }

    func testThereIsNoTokenToPaste() {
        let provider = ClaudeCodeProvider(root: root, userDefaults: defaults)

        XCTAssertThrowsError(try provider.saveTokenManually("anything")) { error in
            guard let error = error as? ProviderError, case .unsupported = error else {
                return XCTFail("expected .unsupported, got \(error)")
            }
        }
    }

    // MARK: - Fixtures

    /// The four counts of the one turn every filesystem test writes. They come
    /// to 12,400, and cache reads dominate that deliberately: a total that
    /// dropped them would read 2,400 and the assertions would catch it.
    private enum Turn {
        static let input = 1_200
        static let output = 800
        static let cacheCreation = 400
        static let cacheRead = 10_000
    }

    private func bucket(
        turns: Int = 1,
        input: Int = 0,
        output: Int = 0,
        cacheCreation: Int = 0,
        cacheRead: Int = 0,
        usd: Double? = 0
    ) -> ClaudeCodeBucket {
        ClaudeCodeBucket(
            turns: turns,
            inputTokens: input,
            outputTokens: output,
            cacheCreationTokens: cacheCreation,
            cacheReadTokens: cacheRead,
            estimatedUSD: usd
        )
    }

    private func totals(
        session: ClaudeCodeBucket = .empty,
        today: ClaudeCodeBucket = .empty,
        week: ClaudeCodeBucket = .empty,
        month: ClaudeCodeBucket = .empty,
        byModel: [String: ClaudeCodeBucket] = [:],
        lastTurnAt: Date? = nil
    ) -> ClaudeCodeTotals {
        ClaudeCodeTotals(
            sessionWindow: session,
            today: today,
            week: week,
            month: month,
            byModel: byModel,
            lastTurnAt: lastTurnAt
        )
    }

    /// One assistant row as Claude Code writes it: type, timestamp, and a usage
    /// block inside the message.
    private func assistantLine(
        id: String,
        model: String = "claude-opus-5",
        at: Date,
        usage: String
    ) -> String {
        let stamp = ProviderDate.iso8601.string(from: at)
        return """
        {"type":"assistant","timestamp":"\(stamp)","sessionId":"s","isSidechain":false,\
        "message":{"id":"\(id)","model":"\(model)","usage":{\(usage)}}}
        """
    }

    /// A minute ago, so the turn lands inside the five-hour block, today, and
    /// both rolling windows without depending on when the test runs.
    private func oneGoodTurn(at: Date = Date().addingTimeInterval(-60)) -> String {
        assistantLine(
            id: "msg_good",
            at: at,
            usage: """
            "input_tokens":\(Turn.input),"output_tokens":\(Turn.output),\
            "cache_creation_input_tokens":\(Turn.cacheCreation),\
            "cache_read_input_tokens":\(Turn.cacheRead)
            """
        )
    }

    /// Laid out the way Claude Code does it: one directory per project, one
    /// JSONL per session, so the sweep has to walk rather than list.
    ///
    /// `terminated` is what makes a half-written log possible: a session that is
    /// running has a last line with no newline after it yet, and the scan has to
    /// leave that line in the file rather than parse it.
    @discardableResult
    private func writeTranscript(
        _ text: String,
        named name: String = "session.jsonl",
        terminated: Bool = true
    ) throws -> URL {
        let project = root.appendingPathComponent("-Users-someone-code", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent(name)
        try Data((terminated ? text + "\n" : text).utf8).write(to: file)
        return file
    }

    private func rawObject(_ data: UsageData) throws -> [String: Any] {
        let encoded = try XCTUnwrap(data.rawJSON)
        let bytes = try XCTUnwrap(Data(base64Encoded: encoded))
        let object = try JSONSerialization.jsonObject(with: bytes)
        return try XCTUnwrap(object as? [String: Any])
    }

    /// `ProviderError` is not `Equatable` and its description is prose that is
    /// allowed to change, so the case is what gets asserted.
    private func assertNotAuthenticated(
        _ error: Error,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let error = error as? ProviderError, case .notAuthenticated = error else {
            return XCTFail("expected .notAuthenticated, got \(error)", file: file, line: line)
        }
    }
}
