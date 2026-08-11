import XCTest
@testable import aibarsCore

/// The price table is the one place in aibars where being confidently wrong
/// costs the user money in their head: a dollar figure looks measured whatever
/// it was built from. So these tests are mostly about the refusals — an unknown
/// model, a not-quite-dated snapshot id, a routing prefix nobody anticipated —
/// because every one of those has an attractive wrong answer sitting next to it
/// in the table, usually a neighbouring family at three times the rate.
///
/// Model ids arrive from Claude Code's own JSONL logs, which are untrusted
/// input as far as this table is concerned: they carry whatever the platform
/// that served the turn wrote down, including ids released after this table was
/// typed. Every malformed shape below is therefore a real one to expect, not a
/// hypothetical.
///
/// `ModelPricing` is pure and has no clock and no I/O, so there is nothing to
/// stub and nothing to tidy up.
final class ModelPricingTests: XCTestCase {
    /// The natural unit: rates are per million, so a million tokens of one kind
    /// costs exactly the rate and the arithmetic under test stays visible in
    /// the expectations.
    private let million = 1_000_000

    /// Every id the table publishes. Typed out rather than read off the table,
    /// which is private on purpose — a test that asks the implementation what it
    /// contains cannot notice a model going missing.
    private let published = [
        "claude-fable-5", "claude-mythos-5",
        "claude-opus-5", "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
        "claude-opus-4-5", "claude-opus-4-1", "claude-opus-4", "claude-3-opus",
        "claude-sonnet-5", "claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4",
        "claude-3-7-sonnet", "claude-3-5-sonnet", "claude-3-sonnet",
        "claude-haiku-4-5", "claude-3-5-haiku", "claude-3-haiku",
    ]

    // MARK: - Harness

    /// The loose overload with every count defaulted to nothing, so each test
    /// names only the token kind it is about.
    private func cost(
        _ model: String,
        input: Int = 0,
        output: Int = 0,
        cacheWrite5m: Int = 0,
        cacheRead: Int = 0
    ) -> Double? {
        ModelPricing.cost(
            input: input,
            output: output,
            cacheWrite5m: cacheWrite5m,
            cacheRead: cacheRead,
            model: model
        )
    }

    private func assertCost(
        _ actual: Double?,
        _ expected: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("expected a priced total, got nil", file: file, line: line)
        }
        // Sums of a handful of terms, so the tolerance only has to absorb
        // binary representation of rates like 6.25 and 0.08.
        XCTAssertEqual(actual, expected, accuracy: 1e-9, file: file, line: line)
    }

    // MARK: - The table

    func testKnownModelReportsAllFourRates() {
        guard let opus = ModelPricing.price(for: "claude-opus-5") else {
            return XCTFail("claude-opus-5 must be priced")
        }
        XCTAssertEqual(opus.input, 5)
        XCTAssertEqual(opus.output, 25)
        XCTAssertEqual(opus.cacheWrite5m, 6.25)
        XCTAssertEqual(opus.cacheRead, 0.5)
    }

    func testEveryPublishedModelCarriesEveryRate() {
        for model in published {
            guard let price = ModelPricing.price(for: model) else {
                XCTFail("\(model) is listed but not priced")
                continue
            }
            // A published model missing a cache rate would silently nil out the
            // total of any bucket that touched the cache, which in Claude Code
            // is nearly all of them.
            XCTAssertNotNil(price.cacheWrite5m, "\(model) has no cache-write rate")
            XCTAssertNotNil(price.cacheRead, "\(model) has no cache-read rate")

            XCTAssertGreaterThan(price.input, 0, "\(model) input")
            XCTAssertGreaterThan(price.output, 0, "\(model) output")
            XCTAssertTrue(price.input.isFinite && price.output.isFinite, "\(model) is not finite")

            // The shape every Anthropic tier has held to: output above input,
            // a cache write above input, a cache read far below it. A typo that
            // shifts a decimal point usually breaks one of these.
            XCTAssertGreaterThan(price.output, price.input, "\(model) output vs input")
            if let write = price.cacheWrite5m { XCTAssertGreaterThan(write, price.input, model) }
            if let read = price.cacheRead { XCTAssertLessThan(read, price.input, model) }
        }
    }

    func testTiersAreDistinctWhereTheyShouldBe() {
        // The 4.5 halving is the single most expensive thing to get wrong: a
        // dated opus 4 id filed under opus 4.5 reads at a third of the bill.
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4")?.input, 15)
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4-5")?.input, 5)
        XCTAssertEqual(ModelPricing.price(for: "claude-sonnet-4-5")?.input, 3)
        XCTAssertEqual(ModelPricing.price(for: "claude-haiku-4-5")?.input, 1)
        XCTAssertEqual(ModelPricing.price(for: "claude-3-haiku")?.input, 0.25)
    }

    func testSonnet5CarriesTheListRateNotTheIntroductoryOne() {
        // The introductory 2/10 expires on a date this table cannot see, so
        // carrying it would go on applying a discount that has ended.
        XCTAssertEqual(ModelPricing.price(for: "claude-sonnet-5")?.input, 3)
        XCTAssertEqual(ModelPricing.price(for: "claude-sonnet-5")?.output, 15)
    }

    // MARK: - Unknown models

    func testUnknownModelHasNoPriceAndNoCost() {
        for model in ["gpt-5", "gemini-3-pro", "llama-4", "claude-opus-4-9", "claude-opus-9"] {
            XCTAssertNil(ModelPricing.price(for: model), model)
            // Nil, never zero: a free-looking bucket and an unpriceable one have
            // to be told apart by the caller.
            XCTAssertNil(cost(model, input: million, output: million), model)
        }
    }

    func testUnpricedModelRefusesEvenAnEmptyBucket() {
        // Zero tokens at an unknown rate is still an unknown rate, and the
        // caller adds these up.
        XCTAssertNil(cost("gpt-5"))
    }

    func testAFamilyNumberIsNotADate() {
        // "-9" is not a snapshot date, so an unheard-of opus does not inherit
        // opus 4's rates just because it starts the same way.
        XCTAssertNil(ModelPricing.price(for: "claude-opus-4-9"))
        XCTAssertNil(ModelPricing.price(for: "claude-sonnet-4-9"))
        XCTAssertNil(ModelPricing.price(for: "claude-haiku-4-9"))
    }

    // MARK: - Dated snapshot ids

    func testDatedSnapshotResolvesToItsFamily() {
        assertResolves("claude-opus-4-5-20251101", to: "claude-opus-4-5")
        assertResolves("claude-sonnet-4-5-20250929", to: "claude-sonnet-4-5")
        assertResolves("claude-3-5-haiku-20241022", to: "claude-3-5-haiku")
        assertResolves("claude-3-opus-20240229", to: "claude-3-opus")
    }

    func testEveryPublishedModelIsReachableWithADate() {
        for model in published {
            let dated = model + "-20250101"
            XCTAssertEqual(
                ModelPricing.price(for: dated),
                ModelPricing.price(for: model),
                dated
            )
        }
    }

    func testADatedOpus4KeepsOpus4Rates() {
        // The dated id is prefixed by "claude-opus-4" and by nothing longer that
        // ends in a date, so the expensive tier stays expensive.
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4-20250514")?.input, 15)
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4-1-20250805")?.input, 15)
        // And the cheap one stays cheap.
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4-5-20251101")?.input, 5)
    }

    func testSixDigitsIsTheFloorForADate() {
        // Either side of the rule that keeps a family number from reading as a
        // date. Five digits is not a date and gets no rates at all.
        XCTAssertNil(ModelPricing.price(for: "claude-opus-4-12345"))
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4-123456")?.input, 15)
        XCTAssertEqual(ModelPricing.price(for: "claude-opus-4-1234567890")?.input, 15)
    }

    func testADateMustBeAllDigitsAndMustFollowAHyphen() {
        XCTAssertNil(ModelPricing.price(for: "claude-opus-5-2025110a"))
        XCTAssertNil(ModelPricing.price(for: "claude-opus-5-2025-11-01"))
        XCTAssertNil(ModelPricing.price(for: "claude-opus-5-"))
        XCTAssertNil(ModelPricing.price(for: "claude-opus-5-preview"))
        XCTAssertNil(ModelPricing.price(for: "claude-opus-5-20251101-thinking"))
        // No hyphen at all: a longer model number, not a snapshot of this one.
        XCTAssertNil(ModelPricing.price(for: "claude-opus-50"))
        XCTAssertNil(ModelPricing.price(for: "claude-opus-52025110"))
    }

    // MARK: - Normalising a model id

    func testRoutingPrefixesAreStripped() {
        assertResolves("anthropic/claude-opus-5", to: "claude-opus-5")
        assertResolves("openrouter/anthropic/claude-opus-5", to: "claude-opus-5")
        assertResolves("us.anthropic.claude-opus-5-v1:0", to: "claude-opus-5")
        assertResolves("eu.anthropic.claude-3-5-haiku-20241022-v1:0", to: "claude-3-5-haiku")
        assertResolves("claude-haiku-4-5@20251001", to: "claude-haiku-4-5")
        assertResolves("publishers/anthropic/models/claude-sonnet-4-5@20250929", to: "claude-sonnet-4-5")
    }

    func testCaseAndSurroundingWhitespaceDoNotMatter() {
        assertResolves("CLAUDE-OPUS-5", to: "claude-opus-5")
        assertResolves("Claude-Opus-5", to: "claude-opus-5")
        assertResolves("  claude-opus-5  ", to: "claude-opus-5")
        // A log line read with its newline still attached.
        assertResolves("\n\tclaude-opus-5\n", to: "claude-opus-5")
    }

    func testAVersionSuffixIsStrippedOnlyWhenItIsDigits() {
        XCTAssertEqual(ModelPricing.normalised("claude-opus-5-v1"), "claude-opus-5")
        XCTAssertEqual(ModelPricing.normalised("claude-opus-5-v12"), "claude-opus-5")
        // "-vnext" is part of a name we do not know, not a platform version, so
        // it stays and the id goes unpriced rather than guessed.
        XCTAssertEqual(ModelPricing.normalised("claude-opus-5-vnext"), "claude-opus-5-vnext")
        XCTAssertNil(ModelPricing.price(for: "claude-opus-5-vnext"))
        XCTAssertEqual(ModelPricing.normalised("claude-opus-5-v"), "claude-opus-5-v")
        XCTAssertNil(ModelPricing.price(for: "claude-opus-5-v"))
    }

    func testNormalisingLeavesAForeignIdAlone() {
        // Nothing to find, so nothing is cut: the id stays whole and simply
        // misses the table.
        XCTAssertEqual(ModelPricing.normalised("GPT-5-2025-08-07"), "gpt-5-2025-08-07")
        XCTAssertNil(ModelPricing.price(for: "GPT-5-2025-08-07"))
    }

    func testNormalisingIsIdempotent() {
        for model in ["us.anthropic.claude-opus-5-v1:0", "claude-haiku-4-5@20251001", "gpt-5"] {
            let once = ModelPricing.normalised(model)
            XCTAssertEqual(ModelPricing.normalised(once), once, model)
        }
    }

    // MARK: - Malformed and hostile ids

    func testEmptyAndBlankIdsArePriceless() {
        for model in ["", " ", "\n", "\t\t", "   \n  "] {
            XCTAssertNil(ModelPricing.price(for: model), "\(model.debugDescription)")
            XCTAssertNil(cost(model, input: million), "\(model.debugDescription)")
        }
    }

    func testTruncatedIdsArePriceless() {
        for model in ["claude", "claude-", "claude-opus", "claude-opus-", "claude-3", "opus-5"] {
            XCTAssertNil(ModelPricing.price(for: model), model)
        }
    }

    func testGarbageIdsArePricelessRatherThanCrashing() {
        let garbage = [
            "claude-opus-5-💥",
            "claude opus 5",
            "claude\u{0000}-opus-5",
            "claude-opus\n-5",
            "../../claude-opus-5",         // reached "claude" late, so this one resolves
            String(repeating: "claude-", count: 4_000),
            String(repeating: "9", count: 10_000),
        ]
        // Only the traversal-looking one names a real model once the routing
        // prefix is dropped; the rest have no answer and must say so.
        XCTAssertEqual(ModelPricing.price(for: "../../claude-opus-5")?.input, 5)
        for model in garbage where model != "../../claude-opus-5" {
            XCTAssertNil(ModelPricing.price(for: model), String(model.prefix(24)))
        }
        // Nothing above may trap, which is the real assertion; reaching here is it.
        XCTAssertEqual(garbage.count, 7)
    }

    func testAnEarlierClaudeInTheRoutingWinsAndTheIdGoesUnpriced() {
        // Documented consequence of cutting at the first "claude": a proxy named
        // after the vendor swallows the real id. Unknown is the honest outcome,
        // and it is what happens.
        XCTAssertNil(ModelPricing.price(for: "claude-proxy/anthropic/claude-opus-5"))
    }

    // MARK: - Cost

    func testEachTokenKindIsPricedAtItsOwnRate() {
        // A million of one kind costs exactly that kind's rate, which is the
        // whole arithmetic laid out one term at a time.
        assertCost(cost("claude-opus-5", input: million), 5)
        assertCost(cost("claude-opus-5", output: million), 25)
        assertCost(cost("claude-opus-5", cacheWrite5m: million), 6.25)
        assertCost(cost("claude-opus-5", cacheRead: million), 0.5)
    }

    func testCacheReadsArePricedAsCacheReadsNotAsInput() {
        // The rates are an order of magnitude apart, and cache reads are the
        // largest count in a typical Claude Code day, so charging them at the
        // input rate makes every figure in the panel wrong by roughly ten times
        // the wrong direction.
        let read = cost("claude-opus-5", cacheRead: 10 * million)
        assertCost(read, 5)
        assertCost(cost("claude-opus-5", input: 10 * million), 50)
        XCTAssertNotEqual(read, cost("claude-opus-5", input: 10 * million))

        // Same shape on the cheapest model, where the gap is 0.25 against 0.03.
        assertCost(cost("claude-3-haiku", cacheRead: million), 0.03)
        assertCost(cost("claude-3-haiku", input: million), 0.25)
    }

    func testCacheWritesArePricedAsWritesNotAsReads() {
        assertCost(cost("claude-sonnet-4-5", cacheWrite5m: million), 3.75)
        assertCost(cost("claude-sonnet-4-5", cacheRead: million), 0.3)
    }

    func testAllFourTermsAreSummed() {
        assertCost(
            cost("claude-opus-5", input: million, output: million, cacheWrite5m: million, cacheRead: million),
            5 + 25 + 6.25 + 0.5
        )
    }

    func testCostIsLinearInEveryTokenCount() {
        let single = cost(
            "claude-opus-5",
            input: 312_500, output: 41_000, cacheWrite5m: 1_500_000, cacheRead: 9_400_000
        )
        let doubled = cost(
            "claude-opus-5",
            input: 625_000, output: 82_000, cacheWrite5m: 3_000_000, cacheRead: 18_800_000
        )
        guard let single, let doubled else {
            return XCTFail("both of these are priced models")
        }
        XCTAssertEqual(doubled, single * 2, accuracy: 1e-9)
    }

    func testCostIsAdditiveAcrossBuckets() {
        // The index sums per-model costs rather than per-model tokens, so this
        // has to hold or a day's total drifts from the sum of its parts.
        let first = cost("claude-sonnet-4-5", input: 120_000, cacheRead: 3_000_000)
        let second = cost("claude-sonnet-4-5", output: 45_000, cacheWrite5m: 800_000)
        let together = cost(
            "claude-sonnet-4-5",
            input: 120_000, output: 45_000, cacheWrite5m: 800_000, cacheRead: 3_000_000
        )
        guard let first, let second, let together else {
            return XCTFail("claude-sonnet-4-5 is priced")
        }
        XCTAssertEqual(together, first + second, accuracy: 1e-9)
    }

    // MARK: - Cost edges

    func testNoTokensCostsZeroRatherThanNil() {
        // A priced model with nothing recorded is a measured zero, and must not
        // be confused with a model that has no rates.
        assertCost(cost("claude-opus-5"), 0)
    }

    func testASingleTokenIsPricedAndDoesNotRoundAway() {
        guard let one = cost("claude-opus-5", input: 1) else {
            return XCTFail("claude-opus-5 is priced")
        }
        XCTAssertGreaterThan(one, 0)
        XCTAssertEqual(one, 5.0 / 1_000_000, accuracy: 1e-15)
    }

    func testNegativeCountsContributeNothingRatherThanARefund() {
        // A negative count is a corrupt log line. Subtracting it would let one
        // bad turn eat a real day's spend.
        assertCost(cost("claude-opus-5", input: -1), 0)
        assertCost(cost("claude-opus-5", input: -10 * million, output: million), 25)
        assertCost(cost("claude-opus-5", input: .min, output: .min, cacheWrite5m: .min, cacheRead: .min), 0)
    }

    func testNegativeCacheCountsDoNotReachTheMissingRateGuard() {
        // The guard is on "there are cache tokens to price", not on the field
        // being present, so a corrupt negative behaves exactly like a zero.
        XCTAssertEqual(
            cost("claude-opus-5", input: million, cacheWrite5m: -5),
            cost("claude-opus-5", input: million)
        )
    }

    func testAnAbsurdlyLargeCountStaysFinite() {
        // Int.max tokens is nonsense, but it is nonsense a corrupt log can hold,
        // and the answer has to be a number the formatter can print.
        guard let huge = cost("claude-opus-5", input: .max, output: .max, cacheWrite5m: .max, cacheRead: .max) else {
            return XCTFail("claude-opus-5 is priced")
        }
        XCTAssertTrue(huge.isFinite)
        XCTAssertGreaterThan(huge, 0)
    }

    /// The nil-cache-rate refusal — "part of a total is not a total" — cannot be
    /// reached from outside: `cost` sources its rates from the private table,
    /// and every model in it publishes all four. What is testable is the
    /// contract that makes the refusal meaningful, so that a future model added
    /// without cache rates fails here rather than quietly halving someone's bill.
    func testAPriceMayOmitItsCacheRates() {
        let sparse = ModelPrice(input: 2, output: 8)
        XCTAssertNil(sparse.cacheWrite5m)
        XCTAssertNil(sparse.cacheRead)
        XCTAssertEqual(sparse, ModelPrice(input: 2, output: 8, cacheWrite5m: nil, cacheRead: nil))
        XCTAssertNotEqual(sparse, ModelPrice(input: 2, output: 8, cacheWrite5m: 2.5, cacheRead: 0.2))
    }

    // MARK: - Costing a bucket

    func testBucketOverloadMatchesTheLooseOne() {
        let bucket = ClaudeCodeBucket(
            turns: 3,
            inputTokens: 120_000,
            outputTokens: 45_000,
            cacheCreationTokens: 800_000,
            cacheReadTokens: 3_000_000,
            // Deliberately absurd: the function must price the tokens, never
            // echo a figure it was handed.
            estimatedUSD: 999
        )
        XCTAssertEqual(
            ModelPricing.cost(bucket, model: "claude-sonnet-4-5"),
            cost(
                "claude-sonnet-4-5",
                input: 120_000, output: 45_000, cacheWrite5m: 800_000, cacheRead: 3_000_000
            )
        )
    }

    func testBucketCacheCreationIsPricedAtTheWriteRate() {
        // The one mapping the bucket overload can get wrong silently: the log's
        // cache-creation count is a cache write, not a cache read.
        let bucket = ClaudeCodeBucket(
            turns: 1,
            inputTokens: 0,
            outputTokens: 0,
            cacheCreationTokens: million,
            cacheReadTokens: 0,
            estimatedUSD: nil
        )
        assertCost(ModelPricing.cost(bucket, model: "claude-opus-5"), 6.25)
    }

    func testEmptyBucketCostsZeroAndUnknownModelCostsNothingAtAll() {
        assertCost(ModelPricing.cost(.empty, model: "claude-opus-5"), 0)
        XCTAssertNil(ModelPricing.cost(.empty, model: "gpt-5"))
    }

    // MARK: - How old the table is

    func testAsOfIsAParseableDate() {
        let formatter = DateFormatter()
        // Fixed locale and zone: this is a machine-readable stamp, not a date
        // shown to anyone, and it must parse the same on every machine.
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "yyyy-MM-dd"
        guard let stamp = formatter.date(from: ModelPricing.asOf) else {
            return XCTFail("asOf \(ModelPricing.asOf) does not parse as yyyy-MM-dd")
        }

        // The year-month alone parses too, which is all the UI needs to say how
        // stale the list is.
        let month = DateFormatter()
        month.locale = Locale(identifier: "en_US_POSIX")
        month.timeZone = TimeZone(identifier: "GMT")
        month.dateFormat = "yyyy-MM"
        XCTAssertNotNil(month.date(from: String(ModelPricing.asOf.prefix(7))))

        // A stamp before the first Claude model, or one dated by a typo into the
        // next century, would be shown next to the totals as reassurance.
        let earliest = formatter.date(from: "2023-01-01") ?? .distantPast
        XCTAssertGreaterThan(stamp, earliest)
        XCTAssertLessThan(stamp, earliest.addingTimeInterval(60 * 60 * 24 * 365 * 20))
    }

    // MARK: - Helpers

    private func assertResolves(
        _ model: String,
        to family: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let expected = ModelPricing.price(for: family) else {
            return XCTFail("\(family) must be priced for this to mean anything", file: file, line: line)
        }
        XCTAssertEqual(ModelPricing.price(for: model), expected, model, file: file, line: line)
    }
}
