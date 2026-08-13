import XCTest
@testable import aibarsCore

/// What one mark in the strip says.
///
/// `MenuBarEntry.figure` is the only string the status item prints, and it is
/// printed at 13pt beside a brand mark with no room to explain itself — so the
/// two things worth pinning are that it never grows past three characters and
/// that it never invents a reading. Percentages arrive from provider JSON, which
/// is untrusted: a negative, an out-of-range or a non-finite value has to land
/// somewhere sensible rather than trap in `Int(_:)`.
final class MenuBarEntryFigureTests: XCTestCase {
    private func figure(_ percent: Double?) -> String {
        MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: percent).figure
    }

    // MARK: - The ordinary readings

    func testPercentIsPrintedAsWholePoints() {
        XCTAssertEqual(figure(0.924), "92")
        XCTAssertEqual(figure(0.004), "0")
        XCTAssertEqual(figure(0.5), "50")
        XCTAssertEqual(figure(0.005), "1", "rounds to nearest, not toward zero")
    }

    /// The cap is reserved for a window that is actually finished. Rounding 99.9
    /// up to 100 would tell the user they are done while there is headroom left,
    /// which is the one reading they most need to believe.
    func testOnlyAFullWindowPrintsTheCap() {
        XCTAssertEqual(figure(0.996), "99")
        XCTAssertEqual(figure(0.999), "99")
        XCTAssertEqual(figure(1), "100")
    }

    /// Zero is a reading. A missing quota is not, and the difference has to
    /// survive into the strip, because "0" reads as plenty left.
    func testZeroIsAReadingAndAMissingQuotaIsADash() {
        XCTAssertEqual(figure(0), "0")
        XCTAssertEqual(figure(nil), MenuBarEntry.noFigure)
        XCTAssertEqual(MenuBarEntry.noFigure, "—")
        XCTAssertNotEqual(figure(nil), "0")
    }

    // MARK: - Untrusted input

    func testOutOfRangePercentsAreClampedRatherThanPrinted() {
        XCTAssertEqual(figure(-0.5), "0")
        XCTAssertEqual(figure(1.5), "100")
        XCTAssertEqual(figure(-.greatestFiniteMagnitude), "0")
        XCTAssertEqual(figure(.greatestFiniteMagnitude), "100")
        XCTAssertEqual(figure(-0.0), "0")
    }

    /// A non-finite figure survives `min`/`max` untouched and then traps in
    /// `Int(_:)`, so it is dropped at the door. It becomes no reading rather
    /// than a zero or a cap: nothing about a NaN says the window is empty, and
    /// nothing about an infinity says it is full.
    func testNonFinitePercentsBecomeNoReading() {
        for value in [Double.nan, .infinity, -.infinity, .signalingNaN] {
            let entry = MenuBarEntry(serviceID: "grok", displayName: "Grok", percent: value)
            XCTAssertNil(entry.percent, "\(value) was kept as a reading")
            XCTAssertEqual(entry.figure, MenuBarEntry.noFigure)
        }
    }

    /// The status item shares a 22pt bar with everything else on the machine, so
    /// the width of this string is the width of the item.
    func testFigureNeverExceedsThreeCharacters() {
        for step in 0...1000 {
            let percent = Double(step) / 1000
            XCTAssertLessThanOrEqual(
                figure(percent).count, 3,
                "\(percent) printed \(figure(percent)), which is wider than the strip budgets for"
            )
        }
        XCTAssertLessThanOrEqual(figure(nil).count, 3)
    }

    /// Clamping happens in the initialiser, so two entries that differ only
    /// beyond the range are the same entry — which is what stops a refresh from
    /// looking like a change.
    func testClampingReachesEquality() {
        XCTAssertEqual(
            MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: 1.5),
            MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: 1)
        )
        XCTAssertEqual(
            MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: .nan),
            MenuBarEntry(serviceID: "claude", displayName: "Claude", percent: nil)
        )
    }
}

/// Which marks get the slots.
///
/// `MenuBarStripContent.entries` is the whole of the decision, and the strip
/// redraws on every refresh — so the properties that matter are that the choice
/// is by urgency, that it is deterministic when two services are level, and that
/// it never returns more than the bar can carry however odd the limit it is
/// handed. The limit comes from a settings store, which is untrusted input.
final class MenuBarStripContentTests: XCTestCase {
    private func entry(_ id: String, _ percent: Double?) -> MenuBarEntry {
        MenuBarEntry(serviceID: id, displayName: id.capitalized, percent: percent)
    }

    private func ids(_ entries: [MenuBarEntry]) -> [String] {
        entries.map(\.serviceID)
    }

    // MARK: - Order

    func testEntriesComeBackClosestToCapFirst() {
        let chosen = MenuBarStripContent.entries(
            from: [entry("gemini", 0.12), entry("claude", 0.92), entry("grok", 0.55)],
            limit: 3
        )
        XCTAssertEqual(ids(chosen), ["claude", "grok", "gemini"])
    }

    /// An em dash tells you nothing about how close you are to a cap, so it can
    /// never take a slot from something that does — including from a service
    /// sitting at zero, which at least is a measurement.
    func testStatusOnlyEntriesSortAfterEveryMeteredOne() {
        let metered = [entry("claude", 0.9), entry("gemini", 0)]
        let statusOnly = [entry("chatgpt", nil), entry("copilot", nil)]
        let orders = [
            metered + statusOnly,
            statusOnly + metered,
            [statusOnly[0], metered[0], statusOnly[1], metered[1]]
        ]

        for candidates in orders {
            let chosen = MenuBarStripContent.entries(from: candidates, limit: 3)
            XCTAssertEqual(
                Array(ids(chosen).prefix(2)), ["claude", "gemini"],
                "a status-only service displaced a metered one from \(ids(candidates))"
            )
        }
    }

    /// Two services level with each other must not swap places between refreshes:
    /// `sorted` is not stable, so the declared order has to be the tiebreak, and
    /// repeating the call is how that becomes visible.
    func testLevelServicesKeepTheirDeclaredOrder() {
        let candidates = [entry("copilot", nil), entry("gemini", 0.4), entry("claude", 0.4), entry("grok", 0.4)]
        let first = ids(MenuBarStripContent.entries(from: candidates, limit: 3))
        XCTAssertEqual(first, ["gemini", "claude", "grok"])
        for _ in 0..<50 {
            XCTAssertEqual(
                ids(MenuBarStripContent.entries(from: candidates, limit: 3)), first,
                "the strip reshuffled between two identical refreshes"
            )
        }
    }

    func testStatusOnlyServicesAlsoKeepTheirDeclaredOrder() {
        let candidates = [entry("copilot", nil), entry("chatgpt", nil)]
        XCTAssertEqual(ids(MenuBarStripContent.entries(from: candidates, limit: 3)), ["copilot", "chatgpt"])
    }

    /// The standard library documents `sorted(by:)` as not stable, so declared
    /// order is only guaranteed where the comparator says so — and a comparator
    /// that leaves the tiebreak out can still look right on a four-service list
    /// on today's standard library. Stating it at sixty-four is what makes it a
    /// property of this code rather than of the sort we happen to be linked
    /// against and of how many subscriptions the author happens to have.
    func testTheDeclaredOrderSurvivesAListLargeEnoughForTheSortToReorderIt() {
        let level = (0..<64).map { entry("service\($0)", 0.5) }
        XCTAssertEqual(
            ids(MenuBarStripContent.entries(from: level, limit: 3)),
            ["service0", "service1", "service2"]
        )
        let statusOnly = (0..<64).map { entry("service\($0)", nil) }
        XCTAssertEqual(
            ids(MenuBarStripContent.entries(from: statusOnly, limit: 3)),
            ["service0", "service1", "service2"],
            "the sentinel that sorts unmeasured services last stopped being a tiebreak too"
        )
    }

    /// Urgency still outranks declared order at that size, and the two rules
    /// compose: one service ahead of the pack takes the first slot from wherever
    /// it was declared, and the level ones behind it fill the rest in the order
    /// they arrived.
    func testUrgencyLeadsAndDeclaredOrderFollowsAtScale() {
        var candidates = (0..<40).map { entry("service\($0)", 0.2) }
        candidates.insert(entry("copilot", nil), at: 0)
        candidates.append(entry("claude", 0.9))

        let first = ids(MenuBarStripContent.entries(from: candidates, limit: 3))
        XCTAssertEqual(first, ["claude", "service0", "service1"])
        // A refresh re-runs this against the same list, so it has to answer the
        // same thing every time: a strip that reshuffles is a strip whose marks
        // cannot be found by position.
        for _ in 0..<50 {
            XCTAssertEqual(
                ids(MenuBarStripContent.entries(from: candidates, limit: 3)), first,
                "the strip reshuffled between two identical refreshes"
            )
        }
    }

    /// The fold is the other place order decides something. Two accounts level
    /// with each other are indistinguishable by reading, so the one declared
    /// first survives — otherwise the mark stays put while the account behind it
    /// swaps, which is worse than a visible change.
    func testTwoLevelAccountsOfOneServiceFoldToTheFirstDeclared() {
        let candidates = [
            MenuBarEntry(serviceID: "claude", displayName: "Personal", percent: 0.4),
            MenuBarEntry(serviceID: "claude", displayName: "Work", percent: 0.4)
        ]
        let chosen = MenuBarStripContent.entries(from: candidates, limit: 3)
        XCTAssertEqual(chosen.count, 1)
        XCTAssertEqual(chosen.first?.displayName, "Personal")
        XCTAssertEqual(
            MenuBarStripContent.entries(from: candidates.reversed(), limit: 3).first?.displayName,
            "Work",
            "the fold ignored declared order rather than following it"
        )
    }

    // MARK: - How many

    func testLimitIsClampedToWhatTheBarCanCarry() {
        let candidates = [entry("claude", 0.9), entry("gemini", 0.8), entry("grok", 0.7), entry("mistral", 0.6)]
        XCTAssertEqual(MenuBarStripContent.entries(from: candidates, limit: 0).count, 1)
        XCTAssertEqual(MenuBarStripContent.entries(from: candidates, limit: 1).count, 1)
        XCTAssertEqual(MenuBarStripContent.entries(from: candidates, limit: 2).count, 2)
        XCTAssertEqual(MenuBarStripContent.entries(from: candidates, limit: 3).count, 3)
        XCTAssertEqual(MenuBarStripContent.entries(from: candidates, limit: 9).count, 3)
    }

    /// A corrupt or hand-edited settings store can hand this anything an `Int`
    /// can hold, and the two ends are where a clamp written with the wrong
    /// comparison would overflow instead of clamping.
    func testAbsurdLimitsFromAStoreStillClamp() {
        let candidates = [entry("claude", 0.9), entry("gemini", 0.8), entry("grok", 0.7)]
        for limit in [Int.min, -1, Int.max] {
            let count = MenuBarStripContent.entries(from: candidates, limit: limit).count
            XCTAssertTrue(
                MenuBarStripContent.range.contains(count),
                "limit \(limit) produced \(count) entries"
            )
        }
    }

    func testTheRangeIsOneToThree() {
        XCTAssertEqual(MenuBarStripContent.range, 1...3)
    }

    func testFewerCandidatesThanTheLimitReturnsAllOfThemAndPadsNothing() {
        let chosen = MenuBarStripContent.entries(from: [entry("claude", 0.9)], limit: 3)
        XCTAssertEqual(ids(chosen), ["claude"])
    }

    /// An empty list is the state on first launch, before anything has answered.
    /// A placeholder entry here would draw a mark for a service that is not
    /// there; the strip's own empty treatment is the renderer's business.
    func testNoCandidatesReturnsNothing() {
        XCTAssertTrue(MenuBarStripContent.entries(from: [], limit: 3).isEmpty)
        XCTAssertTrue(MenuBarStripContent.entries(from: [], limit: 0).isEmpty)
    }

    // MARK: - One mark per service

    /// Two accounts of one service would draw the same brand mark twice with two
    /// different numbers, which reads as a rendering fault. The closer one to its
    /// cap survives, whichever order the accounts arrived in.
    func testOneServiceDrawsOnceAndKeepsItsWorstAccount() {
        let orders = [
            [entry("claude", 0.4), entry("claude", 0.91)],
            [entry("claude", 0.91), entry("claude", 0.4)]
        ]
        for candidates in orders {
            let chosen = MenuBarStripContent.entries(from: candidates + [entry("grok", 0.2)], limit: 3)
            XCTAssertEqual(ids(chosen), ["claude", "grok"])
            XCTAssertEqual(chosen.first?.figure, "91")
        }
    }

    /// A service with one metered account and one that reports no quota is a
    /// metered service. The dash must not be the copy that survives.
    func testAMeteredAccountBeatsAStatusOnlyOneOfTheSameService() {
        let chosen = MenuBarStripContent.entries(
            from: [entry("claude", nil), entry("claude", 0.8)],
            limit: 3
        )
        XCTAssertEqual(chosen.count, 1)
        XCTAssertEqual(chosen.first?.figure, "80")
    }

    /// Deduplication runs before the limit is applied, so nine accounts of one
    /// service must not spend all three slots.
    func testDuplicatesDoNotConsumeSlots() {
        let claudes = (0..<9).map { entry("claude", Double($0) / 10) }
        let chosen = MenuBarStripContent.entries(from: claudes + [entry("grok", 0.1), entry("gemini", 0.05)], limit: 3)
        XCTAssertEqual(ids(chosen), ["claude", "grok", "gemini"])
    }

    // MARK: - Never an invented reading

    /// Selection ranks, folds and truncates. It never edits, and the cheapest
    /// way to state that is that every entry handed back is one that went in: no
    /// figure is adjusted in transit and none is manufactured, for any service.
    func testSelectionOnlyEverReturnsEntriesItWasGiven() {
        let candidates = [
            entry("chatgpt", nil), entry("claude", 1), entry("claude", 0.4),
            entry("gemini", 0), entry("copilot", nil), entry("grok", 0.55)
        ]
        for limit in [Int.min, 0, 1, 2, 3, 9, Int.max] {
            for chosen in MenuBarStripContent.entries(from: candidates, limit: limit) {
                XCTAssertTrue(
                    candidates.contains(chosen),
                    "\(chosen.serviceID) came back with a reading it did not arrive with"
                )
            }
        }
    }

    /// The sentinel that sorts an unmeasured service below every measured one is
    /// -1, and -1 clamps to 0 the moment it is treated as a reading. So the
    /// ranking has to be the only thing that ever sees it: whichever path an
    /// entry takes through here — alone, beside a measured service, ahead of one,
    /// folded against a second seat of its own — it comes back with no figure.
    func testAStatusOnlyServiceNeverAcquiresAFigureOnAnyPath() {
        let lists: [[MenuBarEntry]] = [
            [entry("chatgpt", nil)],
            [entry("chatgpt", nil), entry("copilot", nil)],
            [entry("chatgpt", nil), entry("claude", 0.92)],
            [entry("claude", 0.92), entry("chatgpt", nil)],
            [entry("chatgpt", nil), entry("chatgpt", nil)],
            [entry("claude", 1), entry("gemini", 0), entry("grok", 0.5), entry("chatgpt", nil)]
        ]

        var drawn = 0
        for candidates in lists {
            for limit in [Int.min, 0, 1, 2, 3, Int.max] {
                let chosen = MenuBarStripContent.entries(from: candidates, limit: limit)
                for unmeasured in chosen where unmeasured.serviceID == "chatgpt" {
                    drawn += 1
                    XCTAssertNil(
                        unmeasured.percent,
                        "gained a reading from \(ids(candidates)) at limit \(limit)"
                    )
                    XCTAssertEqual(unmeasured.figure, MenuBarEntry.noFigure)
                }
            }
        }
        // Counted, because a status-only service only reaches the strip when the
        // measured ones leave it a slot: if the ranking ever stopped letting one
        // through at all, every assertion above would pass by not running.
        XCTAssertGreaterThan(drawn, 0, "no case in this test actually drew the unmeasured service")
    }

    /// Alone is the case worth its own test. One status-only subscription and
    /// nothing else is where a fallback figure is most tempting and least
    /// honest — and the service still has to be drawn, because dropping it would
    /// leave a status item that reports nothing while it is connected to
    /// something.
    func testAStatusOnlyServiceIsStillDrawnWhenItIsTheOnlyOne() {
        let chosen = MenuBarStripContent.entries(from: [entry("chatgpt", nil)], limit: 3)
        XCTAssertEqual(ids(chosen), ["chatgpt"], "the only connected service was dropped for having no quota")
        XCTAssertNil(chosen.first?.percent)
        XCTAssertEqual(chosen.first?.figure, MenuBarEntry.noFigure)
        XCTAssertNotEqual(chosen.first?.figure, "0", "no quota was reported as an empty window")
        XCTAssertNotEqual(chosen.first?.figure, "100", "no quota was reported as a full one")
    }
}

/// What the status item says out loud.
///
/// The strip is a glyph and two digits; everything that makes it comprehensible
/// lives in this string, so it has to name each service and each number, and it
/// has to say the missing ones are missing rather than leave VoiceOver to
/// announce an em dash as "dash" or as nothing at all.
///
/// Three sentence shapes since the styles landed, and the reason is the same one:
/// `markOnly` draws its reading as a *tint* and `microBars` as a *bar height*,
/// neither of which VoiceOver can hear, so those two say the band in words. Every
/// call below names the shape it is asserting, because the shape is the style's
/// answer rather than a default anyone may take.
final class MenuBarStripAccessibilityTests: XCTestCase {
    private func entry(_ id: String, _ name: String, _ percent: Double?) -> MenuBarEntry {
        MenuBarEntry(serviceID: id, displayName: name, percent: percent)
    }

    /// The shipped warning, so the band words below are measured against the line
    /// the app actually draws.
    private let warning = 0.85

    func testLabelNamesEveryServiceAndItsNumber() {
        let label = MenuBarStripContent.accessibilityLabel(
            [entry("claude", "Claude", 0.924), entry("gemini", "Gemini", 0.12)],
            sentence: .figures, warningThreshold: warning
        )
        XCTAssertEqual(label, "AI usage: Claude 92%, Gemini 12%")
    }

    func testAStatusOnlyServiceIsSaidToHaveNoQuota() {
        let label = MenuBarStripContent.accessibilityLabel(
            [entry("claude", "Claude", 0.5), entry("chatgpt", "ChatGPT", nil)],
            sentence: .figures, warningThreshold: warning
        )
        XCTAssertEqual(label, "AI usage: Claude 50%, ChatGPT reports no quota")
        XCTAssertFalse(label.contains(MenuBarEntry.noFigure), "VoiceOver was handed a dash to read")
        XCTAssertFalse(label.contains("ChatGPT 0"), "a service with no quota was given a number")
    }

    func testNothingReportedIsSaidRatherThanLeftSilent() {
        // Every shape, because there is nothing to band and nothing to call
        // closest to its cap: an empty strip says one thing however it is drawn.
        for sentence in [MenuBarStripContent.Sentence.figures, .bands, .worst] {
            XCTAssertEqual(
                MenuBarStripContent.accessibilityLabel([], sentence: sentence, warningThreshold: warning),
                "AI usage: nothing reported yet"
            )
        }
    }

    // MARK: - The band shape

    /// The tint is the reading under `markOnly` and the bar height is under
    /// `microBars`, and VoiceOver can hear neither — so the word is the drawing,
    /// said out loud.
    func testTheBandShapeSaysWhatTheTintMeans() {
        let label = MenuBarStripContent.accessibilityLabel(
            [
                entry("claude", "Claude", 0.92),
                entry("gemini", "Gemini", 0.64),
                entry("chatgpt", "ChatGPT", nil)
            ],
            sentence: .bands, warningThreshold: warning
        )
        XCTAssertEqual(
            label,
            "AI usage: Claude 92%, near limit, Gemini 64%, in use, ChatGPT reports no quota"
        )
        // A service with no quota has no band, and inventing one for it would be
        // the same lie as inventing a percentage.
        XCTAssertFalse(label.contains("ChatGPT reports no quota, "), "a status-only service was banded")
    }

    /// The three words are the panel's own — `AppearanceSettings.grouped`'s
    /// section titles — so the strip and the list under it call one state one
    /// thing. Boundaries at the configured warning, not at the ramp's own stops.
    func testTheBandWordsAreThePanelsAndTheLineIsTheUsers() {
        func word(_ percent: Double, warning: Double) -> String {
            MenuBarStripContent.accessibilityLabel(
                [entry("claude", "Claude", percent)], sentence: .bands, warningThreshold: warning
            )
        }
        XCTAssertTrue(word(0.85, warning: 0.85).hasSuffix("near limit"), "the boundary is exclusive")
        XCTAssertTrue(word(0.8499, warning: 0.85).hasSuffix("in use"))
        XCTAssertTrue(word(0, warning: 0.85).hasSuffix("idle"), "a genuine zero is not 'in use'")
        // Moving the line moves the word. The failure this catches is a sentence
        // that says "in use" about a service the strip has drawn red.
        XCTAssertTrue(word(0.75, warning: 0.70).hasSuffix("near limit"))
        XCTAssertTrue(word(0.75, warning: 0.95).hasSuffix("in use"))
    }

    // MARK: - The worst shape

    /// One service, and why it is the one. It does not say how many were
    /// considered — that is a number the strip does not draw.
    func testTheWorstShapeNamesOneServiceAndSaysWhy() {
        let label = MenuBarStripContent.accessibilityLabel(
            [entry("claude", "Claude", 0.92)], sentence: .worst, warningThreshold: warning
        )
        XCTAssertEqual(label, "AI usage: Claude 92%, closest to its cap")
        XCTAssertFalse(label.contains("1 of"), "the sentence counted the services it did not draw")
    }

    /// Nothing measured is connected, so there is no cap to be closest to. The
    /// clause is dropped rather than attached to a service that has no reading.
    func testTheWorstShapeDropsItsClauseWhenThereIsNoReading() {
        XCTAssertEqual(
            MenuBarStripContent.accessibilityLabel(
                [entry("chatgpt", "ChatGPT", nil)], sentence: .worst, warningThreshold: warning
            ),
            "AI usage: ChatGPT reports no quota"
        )
    }

    /// The strip's entire content can be status-only: a ChatGPT subscription, a
    /// Copilot seat, and no quota anywhere. Nothing in that sentence may become a
    /// number, and it must not collapse into the empty-state wording either —
    /// two services are connected and the label says so.
    func testAStripOfNothingButStatusOnlyServicesInventsNoNumbers() {
        let chosen = MenuBarStripContent.entries(
            from: [entry("chatgpt", "ChatGPT", nil), entry("copilot", "Copilot", nil)],
            limit: 3
        )
        let label = MenuBarStripContent.accessibilityLabel(
            chosen, sentence: .figures, warningThreshold: warning
        )
        XCTAssertEqual(label, "AI usage: ChatGPT reports no quota, Copilot reports no quota")
        XCTAssertFalse(label.contains("%"), "a service with no quota was given a percentage")
        XCTAssertFalse(label.contains("0"), "a service with no quota was given a number")
        XCTAssertNotEqual(
            label, "AI usage: nothing reported yet",
            "two connected services were described as nothing at all"
        )
    }

    /// Down to one, which is the reading a single-subscription user hears every
    /// time they focus the status item.
    func testTheOnlyServiceDrawnCanBeAStatusOnlyOne() {
        let chosen = MenuBarStripContent.entries(from: [entry("chatgpt", "ChatGPT", nil)], limit: 1)
        XCTAssertEqual(
            MenuBarStripContent.accessibilityLabel(
                chosen, sentence: .figures, warningThreshold: warning
            ),
            "AI usage: ChatGPT reports no quota"
        )
    }

    /// It describes what is drawn, not what was available to draw — so feeding it
    /// the chosen entries and the full candidate list must differ.
    func testTheLabelFollowsWhatTheStripActuallyDrew() {
        let candidates = [
            entry("claude", "Claude", 0.9),
            entry("gemini", "Gemini", 0.8),
            entry("grok", "Grok", 0.7),
            entry("mistral", "Mistral", 0.6)
        ]
        let chosen = MenuBarStripContent.entries(from: candidates, limit: 2)
        let label = MenuBarStripContent.accessibilityLabel(
            chosen, sentence: .figures, warningThreshold: warning
        )
        XCTAssertEqual(label, "AI usage: Claude 90%, Gemini 80%")
        XCTAssertFalse(label.contains("Mistral"), "described a service the strip is not drawing")
    }

    /// A display name restored from a corrupt store can be empty. The label is
    /// then oddly worded, but it still has to carry the reading and it still has
    /// to be a string, not a crash.
    func testAnEmptyDisplayNameStillCarriesItsReading() {
        let label = MenuBarStripContent.accessibilityLabel(
            [entry("claude", "", 0.92)], sentence: .figures, warningThreshold: warning
        )
        XCTAssertTrue(label.contains("92%"), "lost the reading with the name")
    }
}
