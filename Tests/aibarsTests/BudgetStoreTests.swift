import XCTest
import Combine
@testable import aibarsCore

/// The budgets the user set, and the one blob on disk they live in.
///
/// Two halves, tested apart. `Budget` is a value that cleans itself, so its
/// rules can be asserted without a store at all; `BudgetStore` is the only thing
/// that writes them down, so its rules are about what survives a relaunch and
/// what a corrupted blob is allowed to do to a launch.
///
/// Everything persisted is untrusted input. A budget is a number the user typed
/// once and then stopped thinking about, so a store that quietly loses one, or
/// quietly turns one into a limit of nothing, is worse than a store that shows
/// none at all — and both of those are what the cases below are looking for.
final class BudgetStoreTests: XCTestCase {

    // MARK: - Harness

    /// A mirror of `BudgetStore.Key.budgets`, which is private. Corrupting the
    /// blob and asserting a write never happened both mean naming the key, and
    /// there is no way in from outside the class.
    private let key = "aibars.spend.budgets"

    /// A scratch domain per test, torn down afterwards, so one test's budgets
    /// are never another test's launch state and nothing here can reach the
    /// user's own settings.
    private func scratchDefaults(_ label: String = #function) throws -> UserDefaults {
        // Stable, not a UUID. `TestDomain` in `TestIsolation.swift` has the
        // measurement: `removePersistentDomain` empties a domain and does not
        // delete its file, so a fresh name per run left a plist behind every time.
        let suite = TestDomain.stable("\(TestDomain.prefix).budget-store.\(label)")
        let store = try XCTUnwrap(UserDefaults(suiteName: suite), "could not open a scratch suite")
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return store
    }

    /// Levels are compared with a tolerance rather than exactly. The cleaning
    /// pass multiplies and divides by ten thousand, and asserting on the exact
    /// bits that come back would be testing the platform's division rather than
    /// the rule.
    private func assertLevels(
        _ actual: [Double],
        _ expected: [Double],
        _ message: String = "",
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard actual.count == expected.count else {
            return XCTFail("expected \(expected), got \(actual). \(message)", file: file, line: line)
        }
        for (index, pair) in zip(actual, expected).enumerated() {
            XCTAssertEqual(
                pair.0, pair.1, accuracy: 1e-9,
                "level \(index) of \(actual), expected \(expected). \(message)",
                file: file, line: line
            )
        }
    }

    /// Writes a blob under the store's own key, for the cases that are about
    /// what a launch does with something it did not write itself.
    private func plant(_ json: String, in defaults: UserDefaults) {
        defaults.set(Data(json.utf8), forKey: key)
    }

    // MARK: - Budget: the amount

    /// A budget of nothing and a budget that was never set are different states
    /// — `BudgetPolicy.status` refuses the first and reports nothing for the
    /// second — so zero is stored as zero rather than being taken as unset.
    func testAnAmountOfZeroIsKeptAndANegativeOneIsFloored() {
        XCTAssertEqual(Budget(amountMinor: 0).amountMinor, 0)
        XCTAssertEqual(Budget(amountMinor: 1).amountMinor, 1)
        XCTAssertEqual(Budget(amountMinor: -1).amountMinor, 0, "one minor unit under zero is still under zero")
        XCTAssertEqual(Budget(amountMinor: .min).amountMinor, 0)
        XCTAssertEqual(Budget(amountMinor: .max).amountMinor, .max, "nothing up there needs clamping")
    }

    // MARK: - Budget: the currency

    func testTheCurrencyIsTrimmedAndUpperCased() {
        XCTAssertEqual(Budget(amountMinor: 1, currency: "usd").currency, "USD")
        XCTAssertEqual(Budget(amountMinor: 1, currency: "  eur\n").currency, "EUR")
        XCTAssertEqual(Budget(amountMinor: 1, currency: "CnY").currency, "CNY")
    }

    /// A code this app has never heard of is the user's to fix, not the store's
    /// to refuse: a provider that starts billing in one should still get a
    /// budget rather than silently get a dollar sign.
    func testAnUnknownCodeIsKeptAndOnlyAnEmptyOneFallsBack() {
        XCTAssertEqual(Budget(amountMinor: 1, currency: "XTS").currency, "XTS")
        XCTAssertEqual(Budget(amountMinor: 1, currency: "not a code").currency, "NOT A CODE")
        XCTAssertEqual(Budget(amountMinor: 1, currency: "").currency, Budget.defaultCurrency)
        XCTAssertEqual(Budget(amountMinor: 1, currency: "   ").currency, Budget.defaultCurrency)
        XCTAssertEqual(Budget(amountMinor: 1, currency: "\n\t").currency, Budget.defaultCurrency)
        XCTAssertEqual(Budget.defaultCurrency, "USD")
    }

    // MARK: - Budget: the alert levels

    func testLevelsAreSortedAndDeduplicated() {
        assertLevels(Budget(amountMinor: 1, alertsAt: [1.0, 0.5, 0.9]).alertsAt, [0.5, 0.9, 1.0])
        assertLevels(
            Budget(amountMinor: 1, alertsAt: [0.8, 0.8, 0.8]).alertsAt, [0.8],
            "the same level twice would alert twice"
        )
    }

    /// Two spellings of eighty percent — one typed, one arrived at by
    /// arithmetic — are one level, because they are rounded to a basis point
    /// before they are compared.
    func testLevelsAreDeduplicatedAtABasisPoint() {
        assertLevels(Budget(amountMinor: 1, alertsAt: [0.8, 0.80001, 0.799996]).alertsAt, [0.8])
        assertLevels(
            Budget(amountMinor: 1, alertsAt: [0.8, 0.8002]).alertsAt, [0.8, 0.8002],
            "two basis points apart is two levels"
        )
    }

    /// Not clamped into the range: a level outside it is dropped. Clamping would
    /// invent a level the user never asked for, and a stray 1.5 turning into a
    /// second alert at the budget itself is exactly the duplicate the basis
    /// point rounding exists to prevent.
    func testLevelsOutsideTheRangeAreDroppedRatherThanClamped() {
        assertLevels(Budget(amountMinor: 1, alertsAt: [1.5, 0.5]).alertsAt, [0.5])
        assertLevels(Budget(amountMinor: 1, alertsAt: [-0.5, 0.5]).alertsAt, [0.5])
        assertLevels(Budget(amountMinor: 1, alertsAt: [0, -0.0, 0.5]).alertsAt, [0.5])
        assertLevels(
            Budget(amountMinor: 1, alertsAt: [.nan, .infinity, -.infinity, 0.5]).alertsAt, [0.5],
            "a non-finite level would also refuse to encode, taking every other budget with it"
        )
    }

    /// Either side of both ends of the range, stated once so nobody has to work
    /// out whether the bounds are open.
    func testTheEdgesOfTheLevelRange() {
        assertLevels(Budget(amountMinor: 1, alertsAt: [1.0]).alertsAt, [1.0], "the budget itself is a level")
        assertLevels(Budget(amountMinor: 1, alertsAt: [1.0001]).alertsAt, [])
        assertLevels(Budget(amountMinor: 1, alertsAt: [0.0001]).alertsAt, [0.0001], "one basis point is a level")
        assertLevels(Budget(amountMinor: 1, alertsAt: [0]).alertsAt, [])
    }

    /// A level smaller than the basis point it is rounded to lands on zero and
    /// stays in the list, because the range is checked before the rounding. It
    /// is inert rather than wrong: `BudgetPolicy.crossings` drops levels at or
    /// below zero, so nothing can ever alert at it. Asserted so a change to
    /// either half is noticed by the other.
    func testALevelBelowABasisPointRoundsToZeroAndAlertsAtNothing() {
        let levels = Budget(amountMinor: 1, alertsAt: [0.00001]).alertsAt
        assertLevels(levels, [0])
        XCTAssertEqual(BudgetPolicy.crossings(previous: 0, current: 1, levels: levels), [])
    }

    /// Four is the cap, and when a list has to be cut it is the level nearest
    /// the budget the user least wanted to lose.
    func testAtMostFourLevelsSurviveAndItIsTheHighestThatDo() {
        assertLevels(
            Budget(amountMinor: 1, alertsAt: [0.2, 0.4, 0.6, 0.8]).alertsAt,
            [0.2, 0.4, 0.6, 0.8],
            "four is not over the cap"
        )
        assertLevels(
            Budget(amountMinor: 1, alertsAt: [0.5, 0.1, 0.9, 0.3, 0.7]).alertsAt,
            [0.3, 0.5, 0.7, 0.9],
            "the cut should happen after the sort, not in arrival order"
        )
    }

    /// An empty list is a legitimate state: a budget the user wants to see in
    /// the pane and not be told about. It must not be read as "nothing was set,
    /// use the defaults".
    func testAnEmptyLevelListStaysEmpty() {
        assertLevels(Budget(amountMinor: 1, alertsAt: []).alertsAt, [])
        assertLevels(Budget(amountMinor: 1, alertsAt: [0, -1, .nan]).alertsAt, [], "cleaned down to nothing")
    }

    /// The shipped defaults have to survive the pass they are handed to, or a
    /// new budget would be cleaned into something other than what it advertises.
    func testTheDefaultLevelsSurviveTheirOwnCleaning() {
        assertLevels(Budget.defaultAlerts, [0.80, 1.0])
        assertLevels(Budget(amountMinor: 1).alertsAt, Budget.defaultAlerts)
    }

    // MARK: - Budget: decoding

    /// Decoded field by field, so a budget written by a version that had one
    /// fewer field still comes back with the amount the user set.
    func testAStoredBudgetMissingAFieldDecodesWithThatFieldsDefault() throws {
        let missingCurrency = try decodeBudget(#"{"amountMinor":2500,"alertsAt":[0.5]}"#)
        XCTAssertEqual(missingCurrency.amountMinor, 2500)
        XCTAssertEqual(missingCurrency.currency, Budget.defaultCurrency)
        assertLevels(missingCurrency.alertsAt, [0.5])

        let missingLevels = try decodeBudget(#"{"amountMinor":2500,"currency":"EUR"}"#)
        XCTAssertEqual(missingLevels.amountMinor, 2500)
        XCTAssertEqual(missingLevels.currency, "EUR")
        assertLevels(missingLevels.alertsAt, Budget.defaultAlerts, "an absent list is not an empty one")

        let missingAmount = try decodeBudget(#"{"currency":"EUR"}"#)
        XCTAssertEqual(missingAmount.amountMinor, 0)

        let empty = try decodeBudget("{}")
        XCTAssertEqual(empty, Budget(amountMinor: 0))
    }

    /// A field written as null is a field that is not there.
    func testNullFieldsFallBackTheSameWayAbsentOnesDo() throws {
        let budget = try decodeBudget(#"{"amountMinor":100,"currency":null,"alertsAt":null}"#)
        XCTAssertEqual(budget.currency, Budget.defaultCurrency)
        assertLevels(budget.alertsAt, Budget.defaultAlerts)
    }

    /// An empty stored list is kept, unlike an absent one. This is the pair that
    /// proves "the user wants no alerts" and "this budget predates alerts" are
    /// told apart.
    func testAnEmptyStoredLevelListIsNotReplacedByTheDefaults() throws {
        assertLevels(try decodeBudget(#"{"amountMinor":100,"alertsAt":[]}"#).alertsAt, [])
    }

    /// The cleaning is on the decode path too, because a blob on disk outlives
    /// the version that wrote it and may have been edited by hand.
    func testAStoredBudgetIsCleanedOnTheWayBackIn() throws {
        let budget = try decodeBudget(
            #"{"amountMinor":-4000,"currency":" gbp ","alertsAt":[1.0,0.5,1.0,7,-3]}"#
        )
        XCTAssertEqual(budget.amountMinor, 0)
        XCTAssertEqual(budget.currency, "GBP")
        assertLevels(budget.alertsAt, [0.5, 1.0])
    }

    /// A field of the wrong type is not a missing field: it is a blob nobody
    /// should be guessing about, and the store discards the whole thing rather
    /// than half remembering it.
    func testAFieldOfTheWrongTypeFailsTheDecodeRatherThanFallingBack() {
        XCTAssertThrowsError(try decodeBudget(#"{"amountMinor":"lots"}"#))
        XCTAssertThrowsError(try decodeBudget(#"{"alertsAt":0.8}"#))
        XCTAssertThrowsError(try decodeBudget(#"{"currency":42}"#))
    }

    func testAnUnknownFieldIsIgnored() throws {
        let budget = try decodeBudget(#"{"amountMinor":100,"period":"month"}"#)
        XCTAssertEqual(budget.amountMinor, 100, "a field from a later version should not cost the amount")
    }

    /// Round trip through the coder the store actually uses, including the
    /// awkward values: the largest amount there is and a list cleaned to empty.
    func testABudgetSurvivesItsOwnEncoding() throws {
        for budget in [
            Budget(amountMinor: 0),
            Budget(amountMinor: 3284, currency: "usd", alertsAt: [1.0, 0.5]),
            Budget(amountMinor: .max, currency: "JPY", alertsAt: []),
            Budget(amountMinor: 1, currency: "CNY", alertsAt: [0.0001, 1.0])
        ] {
            let data = try JSONEncoder().encode(budget)
            XCTAssertEqual(try JSONDecoder().decode(Budget.self, from: data), budget)
        }
    }

    // MARK: - The store: round trip

    @MainActor
    func testABudgetRoundTripsThroughAScratchDomain() throws {
        let defaults = try scratchDefaults()
        let budget = Budget(amountMinor: 3284, currency: "EUR", alertsAt: [0.5, 0.9])

        let first = BudgetStore(store: defaults)
        XCTAssertTrue(first.budgets.isEmpty, "a domain nobody has written should start with no budgets")
        XCTAssertNil(first.budget(for: "claude"))

        first.setBudget(budget, for: "claude")

        XCTAssertEqual(first.budget(for: "claude"), budget)
        XCTAssertEqual(BudgetStore(store: defaults).budget(for: "claude"), budget)
    }

    /// Keyed by service rather than by account: two Claude accounts are one
    /// subscription to the person paying.
    @MainActor
    func testSeveralServicesCoexist() throws {
        let defaults = try scratchDefaults()
        let store = BudgetStore(store: defaults)

        store.setBudget(Budget(amountMinor: 2000), for: "claude")
        store.setBudget(Budget(amountMinor: 5000, currency: "CNY"), for: "deepseek")

        let reloaded = BudgetStore(store: defaults)
        XCTAssertEqual(reloaded.budget(for: "claude")?.amountMinor, 2000)
        XCTAssertEqual(reloaded.budget(for: "deepseek")?.currency, "CNY")
        XCTAssertEqual(reloaded.budgets.count, 2)
    }

    @MainActor
    func testTheOverallBudgetAndAServiceBudgetDoNotCollide() throws {
        let defaults = try scratchDefaults()
        let store = BudgetStore(store: defaults)

        XCTAssertTrue(BudgetStore.overallKey.isEmpty, "the overall key has to be one no service id can be")

        store.setBudget(Budget(amountMinor: 10_000), for: BudgetStore.overallKey)
        store.setBudget(Budget(amountMinor: 2_000), for: "claude")

        XCTAssertEqual(store.budget(for: BudgetStore.overallKey)?.amountMinor, 10_000)
        XCTAssertEqual(store.budget(for: "claude")?.amountMinor, 2_000)

        // Through JSON as well: the overall budget is an object key of "", and a
        // coder that dropped it would lose the one budget covering everything.
        let reloaded = BudgetStore(store: defaults)
        XCTAssertEqual(reloaded.budget(for: BudgetStore.overallKey)?.amountMinor, 10_000)
        XCTAssertEqual(reloaded.budget(for: "claude")?.amountMinor, 2_000)

        store.setBudget(nil, for: BudgetStore.overallKey)
        XCTAssertNil(store.budget(for: BudgetStore.overallKey))
        XCTAssertEqual(store.budget(for: "claude")?.amountMinor, 2_000, "clearing the overall one took a service with it")
    }

    // MARK: - The store: removal

    /// Setting nothing and having nothing are the same state, so there is no
    /// separate delete — and what is left behind has to be an absent key rather
    /// than a budget of zero, which every spend is already over.
    @MainActor
    func testSettingNilRemovesTheBudgetRatherThanStoringAZero() throws {
        let defaults = try scratchDefaults()
        let store = BudgetStore(store: defaults)

        store.setBudget(Budget(amountMinor: 2000), for: "claude")
        store.setBudget(nil, for: "claude")

        XCTAssertNil(store.budget(for: "claude"))
        XCTAssertTrue(store.budgets.isEmpty, "the key should have gone, not been zeroed")
        XCTAssertNil(BudgetStore(store: defaults).budget(for: "claude"))
    }

    /// The distinction the whole nil case exists to protect.
    @MainActor
    func testABudgetOfZeroIsStoredAndIsNotTheSameAsNoBudget() throws {
        let defaults = try scratchDefaults()
        let store = BudgetStore(store: defaults)

        store.setBudget(Budget(amountMinor: 0), for: "claude")

        XCTAssertEqual(store.budget(for: "claude")?.amountMinor, 0)
        XCTAssertEqual(BudgetStore(store: defaults).budget(for: "claude")?.amountMinor, 0)
        XCTAssertNil(
            BudgetPolicy.status(
                spend: SpendReport(amountMinor: 1, currency: "USD", period: .month, confidence: .measured),
                budget: store.budget(for: "claude")
            ),
            "a budget of zero is a cleared field, and nothing is a fraction of it"
        )
    }

    @MainActor
    func testRemovingSomethingThatWasNeverThereChangesNothing() throws {
        let defaults = try scratchDefaults()
        let store = BudgetStore(store: defaults)

        store.setBudget(nil, for: "grok")

        XCTAssertTrue(store.budgets.isEmpty)
        XCTAssertNil(defaults.object(forKey: key), "an empty removal should not have written a blob")
    }

    @MainActor
    func testClearingEveryBudgetPersists() throws {
        let defaults = try scratchDefaults()
        let store = BudgetStore(store: defaults)

        store.setBudget(Budget(amountMinor: 2000), for: "claude")
        store.budgets = [:]

        XCTAssertTrue(BudgetStore(store: defaults).budgets.isEmpty, "the cleared state has to outlive the launch too")
    }

    // MARK: - The store: cleaning on the way to disk

    /// `Budget`'s fields are `var`s, so a value can be mutated past what the
    /// initialiser would have accepted. The store cleans on every write, which
    /// is what keeps a `-1` off disk.
    @MainActor
    func testAMutatedBudgetIsCleanedBeforeItIsStored() throws {
        let defaults = try scratchDefaults()
        let store = BudgetStore(store: defaults)

        var budget = Budget(amountMinor: 2000)
        budget.amountMinor = -5
        budget.currency = "  gbp "
        budget.alertsAt = [1.0, 0.5, 1.0, 4]
        store.setBudget(budget, for: "claude")

        let stored = try XCTUnwrap(store.budget(for: "claude"))
        XCTAssertEqual(stored.amountMinor, 0)
        XCTAssertEqual(stored.currency, "GBP")
        assertLevels(stored.alertsAt, [0.5, 1.0])
        XCTAssertEqual(BudgetStore(store: defaults).budget(for: "claude"), stored)
    }

    /// Assigning the dictionary wholesale is how the pane binds to it, so that
    /// path is cleaned as well and not just `setBudget`.
    @MainActor
    func testABulkAssignmentIsCleanedToo() throws {
        let defaults = try scratchDefaults()
        let store = BudgetStore(store: defaults)

        var dirty = Budget(amountMinor: 1)
        dirty.amountMinor = -100
        dirty.currency = ""
        store.budgets = ["claude": dirty, "grok": Budget(amountMinor: 500)]

        XCTAssertEqual(store.budget(for: "claude")?.amountMinor, 0)
        XCTAssertEqual(store.budget(for: "claude")?.currency, Budget.defaultCurrency)
        XCTAssertEqual(store.budget(for: "grok")?.amountMinor, 500)
        XCTAssertEqual(BudgetStore(store: defaults).budgets, store.budgets)
    }

    /// The one value that cannot be encoded at all. JSON has no NaN, so a level
    /// that reached the encoder would throw, `persist` would return, and every
    /// other budget in the blob would stop being written — silently. The
    /// cleaning is what stands between that and the disk.
    @MainActor
    func testANonFiniteLevelCannotStopTheWholeBlobBeingWritten() throws {
        let defaults = try scratchDefaults()
        let store = BudgetStore(store: defaults)

        store.setBudget(Budget(amountMinor: 2000), for: "grok")
        var poisoned = Budget(amountMinor: 500)
        poisoned.alertsAt = [.nan, .infinity]
        store.setBudget(poisoned, for: "claude")

        let reloaded = BudgetStore(store: defaults)
        XCTAssertEqual(reloaded.budget(for: "grok")?.amountMinor, 2000, "an unencodable budget took the blob down")
        assertLevels(try XCTUnwrap(reloaded.budget(for: "claude")).alertsAt, [])
    }

    /// The common case is a pane redrawing with nothing changed, and the store
    /// should not be touched to say so. Asserted by taking the blob away and
    /// checking the no-op write does not put one back.
    @MainActor
    func testWritingAnUnchangedValueDoesNotTouchTheStore() throws {
        let defaults = try scratchDefaults()
        let store = BudgetStore(store: defaults)
        let budget = Budget(amountMinor: 2000)

        store.setBudget(budget, for: "claude")
        XCTAssertNotNil(defaults.object(forKey: key))
        defaults.removeObject(forKey: key)

        store.setBudget(budget, for: "claude")
        XCTAssertNil(defaults.object(forKey: key), "an unchanged assignment rewrote the blob")

        // And a real change still gets through.
        store.setBudget(Budget(amountMinor: 2001), for: "claude")
        XCTAssertNotNil(defaults.object(forKey: key))
    }

    /// The one case the guard above does not cover, asserted so it is a known
    /// shape rather than a surprise.
    ///
    /// A value that only differs *before* cleaning still reaches disk, because
    /// `budgets` is `@Published`: the wrapper makes it a computed property, so
    /// assigning the cleaned value inside `didSet` runs `didSet` again — unlike
    /// a plain stored property, where it would not. That second pass sees the
    /// dirty value as its `oldValue`, finds a difference, and writes.
    ///
    /// Harmless, and asserted as harmless: what lands on disk is the cleaned
    /// value either way, and the cost is one redundant write on a keystroke.
    @MainActor
    func testAValueThatOnlyDiffersBeforeCleaningIsStillWritten() throws {
        let defaults = try scratchDefaults()
        let store = BudgetStore(store: defaults)
        let budget = Budget(amountMinor: 2000, currency: "USD")

        store.setBudget(budget, for: "claude")
        defaults.removeObject(forKey: key)

        var dirty = budget
        dirty.currency = "usd"
        store.setBudget(dirty, for: "claude")

        XCTAssertNotNil(defaults.object(forKey: key))
        XCTAssertEqual(store.budget(for: "claude"), budget, "the value itself must not have moved")
        XCTAssertEqual(BudgetStore(store: defaults).budget(for: "claude"), budget)
    }

    // MARK: - The store: publishing

    /// The pane writes budgets while the refresh loop reads them to decide what
    /// to alert on, so both have to be looking at the same value.
    @MainActor
    func testBudgetsIsPublished() throws {
        let store = BudgetStore(store: try scratchDefaults())

        var published: [[String: Budget]] = []
        let subscription = store.$budgets.sink { published.append($0) }
        defer { subscription.cancel() }

        XCTAssertEqual(published.count, 1, "only the subscription's own first value should have arrived")
        XCTAssertEqual(published.last, [String: Budget]())

        let budget = Budget(amountMinor: 2000)
        store.setBudget(budget, for: "claude")

        XCTAssertEqual(published.count, 2)
        XCTAssertEqual(published.last, ["claude": budget])
        XCTAssertEqual(published.last, store.budgets)

        store.setBudget(nil, for: "claude")
        XCTAssertEqual(published.last, [String: Budget](), "a removal is a change subscribers have to see")
    }

    /// A dirty write settles on the cleaned value. Only the last one is
    /// asserted: the intermediate is an implementation detail of assigning
    /// inside the observer, and what matters is that nobody is left holding a
    /// value the store does not have.
    @MainActor
    func testTheLastPublishedValueIsAlwaysTheCleanedOne() throws {
        let store = BudgetStore(store: try scratchDefaults())

        var published: [[String: Budget]] = []
        let subscription = store.$budgets.sink { published.append($0) }
        defer { subscription.cancel() }

        var dirty = Budget(amountMinor: 1)
        dirty.amountMinor = -900
        store.setBudget(dirty, for: "claude")

        XCTAssertEqual(published.last, store.budgets)
        XCTAssertEqual(published.last?["claude"]?.amountMinor, 0)
    }

    // MARK: - The store: what a bad blob does to a launch

    /// A blob that no longer decodes is discarded rather than repaired. The
    /// user is shown no budgets and can set them again, which is better than a
    /// store that half remembers.
    @MainActor
    func testUnreadableBlobsLeaveAnEmptyStoreRatherThanCrashing() throws {
        let blobs: [String: Any] = [
            "not json at all": Data("{ not json".utf8),
            "empty data": Data(),
            "an array": Data("[]".utf8),
            "a bare null": Data("null".utf8),
            "a number for a budget": Data(#"{"claude":5}"#.utf8),
            "a string for a budget": Data(#"{"claude":"2000"}"#.utf8),
            "a budget field of the wrong type": Data(#"{"claude":{"amountMinor":"lots"}}"#.utf8),
            // Not data at all: something else wrote under our key.
            "a string where the blob should be": "aibars.spend.budgets"
        ]

        for (what, blob) in blobs {
            let defaults = try scratchDefaults()
            defaults.set(blob, forKey: key)

            let store = BudgetStore(store: defaults)
            XCTAssertTrue(store.budgets.isEmpty, "\(what) came back as a budget")

            // And the store still works afterwards, over the same domain.
            store.setBudget(Budget(amountMinor: 2000), for: "claude")
            XCTAssertEqual(
                BudgetStore(store: defaults).budget(for: "claude")?.amountMinor, 2000,
                "\(what) left the store unable to write"
            )
        }
    }

    /// Every field is optional on the way in, so a JSON object with none of the
    /// names this app knows is not a failure — it decodes to a budget of zero.
    /// That is the safe direction: `BudgetPolicy.status` refuses a budget of
    /// zero, so a blob written by something else can produce a row in the pane
    /// but can never produce an alert or a fraction.
    @MainActor
    func testAnObjectWithNoRecognisedFieldsDecodesToAZeroBudget() throws {
        let defaults = try scratchDefaults()
        plant(#"{"claude":{"budget":{"amountMinor":1}}}"#, in: defaults)

        let store = BudgetStore(store: defaults)
        XCTAssertEqual(store.budget(for: "claude"), Budget(amountMinor: 0))
        XCTAssertNil(
            BudgetPolicy.status(
                spend: SpendReport(amountMinor: 1, currency: "USD", period: .month, confidence: .measured),
                budget: store.budget(for: "claude")
            )
        )
    }

    @MainActor
    func testAnEmptyObjectIsAnEmptyStoreAndNotAFailure() throws {
        let defaults = try scratchDefaults()
        plant("{}", in: defaults)

        XCTAssertTrue(BudgetStore(store: defaults).budgets.isEmpty)
    }

    /// One unreadable budget among several is still an unreadable blob. The
    /// dictionary is decoded whole, so the good entries go with the bad one —
    /// asserted here because it is a real cost and someone reading the store
    /// should know it is the deliberate choice and not an oversight.
    @MainActor
    func testOneBadEntrySpoilsTheWholeBlob() throws {
        let defaults = try scratchDefaults()
        plant(#"{"claude":{"amountMinor":2000},"grok":{"amountMinor":true}}"#, in: defaults)

        XCTAssertTrue(BudgetStore(store: defaults).budgets.isEmpty)
    }

    /// Everything that comes off disk goes through the same cleaning as
    /// everything that goes on to it, because a blob can be edited by hand or
    /// left behind by a version with looser rules.
    @MainActor
    func testABlobFullOfBadValuesIsCleanedAtLaunch() throws {
        let defaults = try scratchDefaults()
        plant(
            """
            {"claude":{"amountMinor":-2000,"currency":" eur ","alertsAt":[1.0,0.5,1.0,9,-1]},\
            "":{"amountMinor":10000,"currency":"","alertsAt":[0.1,0.2,0.3,0.4,0.5]}}
            """,
            in: defaults
        )

        let store = BudgetStore(store: defaults)

        let claude = try XCTUnwrap(store.budget(for: "claude"))
        XCTAssertEqual(claude.amountMinor, 0)
        XCTAssertEqual(claude.currency, "EUR")
        assertLevels(claude.alertsAt, [0.5, 1.0])

        let overall = try XCTUnwrap(store.budget(for: BudgetStore.overallKey))
        XCTAssertEqual(overall.currency, Budget.defaultCurrency)
        assertLevels(overall.alertsAt, [0.2, 0.3, 0.4, 0.5])
    }

    /// Two stores over one domain do not see each other's writes as they
    /// happen — the app has exactly one, and this only asserts that a launch
    /// reads what the last launch left.
    @MainActor
    func testALaterStoreReadsWhatTheEarlierOneLeft() throws {
        let defaults = try scratchDefaults()

        let first = BudgetStore(store: defaults)
        first.setBudget(Budget(amountMinor: 2000, currency: "EUR", alertsAt: [0.25, 0.5, 0.75, 1.0]), for: "claude")
        first.setBudget(Budget(amountMinor: 9900), for: BudgetStore.overallKey)

        XCTAssertEqual(BudgetStore(store: defaults).budgets, first.budgets)
    }

    // MARK: - Helpers

    private func decodeBudget(_ json: String) throws -> Budget {
        try JSONDecoder().decode(Budget.self, from: Data(json.utf8))
    }
}
