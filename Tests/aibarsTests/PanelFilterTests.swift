import XCTest
import SwiftUI
@testable import aibarsCore

/// What the query matches, and in what order.
///
/// Pure throughout — no hosting view, no raster, no defaults domain. Every one of
/// these is a claim about strings, and the whole reason `PanelFilter` is a file of
/// its own is that a claim about strings should not need a window to check.
final class PanelFilterTests: XCTestCase {

    // MARK: - Fixtures

    private func candidate(
        _ serviceID: String,
        _ displayName: String,
        id: String? = nil,
        account: String? = nil,
        plan: String? = nil
    ) -> PanelFilter.Candidate {
        PanelFilter.Candidate(
            id: id ?? serviceID,
            serviceID: serviceID,
            displayName: displayName,
            accountLabel: account,
            planName: plan
        )
    }

    /// The services this suite reasons about, in the order `AppState` declares
    /// them, so "ties keep the incoming order" has a real incoming order to keep.
    private var services: [PanelFilter.Candidate] {
        [
            candidate("claude", "Claude"),
            candidate("claudecode", "Claude Code"),
            candidate("chatgpt", "ChatGPT"),
            candidate("codex", "Codex"),
            candidate("cursor", "Cursor"),
            candidate("copilot", "GitHub Copilot"),
            candidate("gemini", "Gemini"),
            candidate("grok", "Grok"),
            candidate("openrouter", "OpenRouter"),
            candidate("minimax", "MiniMax"),
            candidate("mistral", "Mistral"),
            candidate("zai", "Z.ai")
        ]
    }

    // MARK: - Normalisation

    /// The punctuation strip is what makes Z.ai findable without an alias for it,
    /// which is why that service has none in the table.
    func testNormalisationFoldsPunctuationAndCase() {
        XCTAssertEqual(PanelFilter.normalise("Z.ai"), "zai")
        XCTAssertEqual(PanelFilter.normalise("z.AI"), "zai")
        XCTAssertEqual(PanelFilter.normalise("zai"), "zai")
        // The two-word name folds to the one-word service id, so "claude code"
        // is a prefix of "claudecode" rather than a miss on the space.
        XCTAssertEqual(PanelFilter.normalise("Claude Code"), "claudecode")
        // Diacritics fold, so a user typing the accent finds the row that has none.
        XCTAssertEqual(PanelFilter.normalise("Café"), "cafe")
    }

    // MARK: - The bands

    func testAnAliasBeatsAPrefix() {
        let ranked = PanelFilter.rank("cc", over: services)
        XCTAssertEqual(ranked.first?.id, "claudecode")
        XCTAssertEqual(ranked.first?.score, 1000)
        // And the two services whose names begin with those letters are not
        // matches at all — "cc" is neither a prefix nor a substring of either.
        XCTAssertNil(PanelFilter.score("cc", against: candidate("claude", "Claude")))
        XCTAssertNil(PanelFilter.score("cc", against: candidate("cursor", "Cursor")))
    }

    func testInitialsFindATwoWordName() {
        // The word rule.
        XCTAssertEqual(PanelFilter.initials(of: "GitHub Copilot"), "gc")
        XCTAssertEqual(PanelFilter.initials(of: "Claude Code"), "cc")
        // The single-word capitals rule.
        XCTAssertEqual(PanelFilter.initials(of: "OpenRouter"), "or")
        XCTAssertEqual(PanelFilter.initials(of: "MiniMax"), "mm")
        XCTAssertEqual(PanelFilter.initials(of: "ChatGPT"), "cgpt")
        // A name with no interior capital has no initials worth the name: one
        // letter in band 800 would outrank every prefix in the panel.
        XCTAssertEqual(PanelFilter.initials(of: "Cursor"), "")
        XCTAssertEqual(PanelFilter.initials(of: "Gemini"), "")

        XCTAssertEqual(PanelFilter.rank("gc", over: services).first?.id, "copilot")
        XCTAssertEqual(PanelFilter.rank("or", over: services).first?.id, "openrouter")
    }

    /// The two length gates. Without them a one-character query reorders the list
    /// without narrowing it, which is the worst thing a filter can do — the row the
    /// eye had already found moves.
    func testAOneCharacterQueryNeverMatchesBySubsequenceOrInitials() {
        for match in PanelFilter.rank("c", over: services) {
            XCTAssertNotEqual(match.score, 800, "\(match.id) matched a one-character query by initials")
            XCTAssertNotEqual(match.score, 200, "\(match.id) matched a one-character query by subsequence")
        }
        // "m" would be MiniMax's and Mistral's initials by the same gate.
        for match in PanelFilter.rank("m", over: services) {
            XCTAssertNotEqual(match.score, 800, "\(match.id) matched \"m\" by initials")
        }
        // And a service with no c in its name or id is simply absent, rather than
        // present at the bottom on a subsequence.
        let ids = PanelFilter.rank("c", over: services).map(\.id)
        XCTAssertFalse(ids.contains("gemini"))
        XCTAssertFalse(ids.contains("grok"))
        // Two characters is where initials start counting.
        XCTAssertEqual(PanelFilter.score("mm", against: candidate("minimax", "MiniMax")), 1000)
        XCTAssertEqual(PanelFilter.score("gc", against: candidate("copilot", "GitHub Copilot")), 800)
    }

    func testAnAccountLabelIsSearchable() {
        let personal = candidate("claude", "Claude", id: "claude", account: "ada@home.test")
        let work = candidate("claude", "Claude", id: "claude#2", account: "ada@example.com")
        let ranked = PanelFilter.rank("example", over: [personal, work])
        XCTAssertEqual(ranked.map(\.id), ["claude#2"])
        XCTAssertEqual(ranked.first?.score, 400)
        // And a prefix of the label outranks a substring of it.
        XCTAssertEqual(PanelFilter.score("ada", against: work), 450)
    }

    func testAPlanNameIsSearchable() {
        let claude = candidate("claude", "Claude", plan: "Max 20×")
        XCTAssertEqual(PanelFilter.score("max", against: claude), 300)
        // And it scores below a name match, so "max" puts MiniMax — whose *name*
        // carries those letters — above the row whose plan does.
        let ranked = PanelFilter.rank("max", over: [claude, candidate("minimax", "MiniMax")])
        XCTAssertEqual(ranked.map(\.id), ["minimax", "claude"])
        XCTAssertEqual(ranked.first?.score, 600)
    }

    /// The one that catches `sorted` being unstable. `AppearanceSettings.ordered`
    /// carries its incoming index for the same reason and says so.
    func testTiesKeepTheIncomingOrder() {
        let a = candidate("claude", "Claude", id: "claude")
        let b = candidate("claudecode", "Claude Code", id: "claudecode")
        XCTAssertEqual(PanelFilter.score("clau", against: a), 900)
        XCTAssertEqual(PanelFilter.score("clau", against: b), 900)
        XCTAssertEqual(PanelFilter.rank("clau", over: [a, b]).map(\.id), ["claude", "claudecode"])
        XCTAssertEqual(PanelFilter.rank("clau", over: [b, a]).map(\.id), ["claudecode", "claude"])
    }

    // MARK: - Sections

    @MainActor
    func testAnEmptyQueryIsNotAFilter() throws {
        let state = AppState()
        let sections = Self.sections(state, count: 3)
        let outcome = PanelFilter.apply(
            query: "",
            to: sections,
            all: state.providers,
            snapshots: state.snapshots
        )
        XCTAssertFalse(outcome.isFiltered)
        XCTAssertEqual(outcome.sections.map(\.id), sections.map(\.id))
        XCTAssertEqual(
            outcome.rows.map(\.id),
            sections.flatMap { $0.providers.map(\.id) },
            "the keyboard needs the drawn order at rest as well as while filtering"
        )
        XCTAssertNil(outcome.hint)
        // Whitespace is not a query either: it normalises away, so ⌘F followed by
        // a stray space must not restructure the panel.
        XCTAssertFalse(PanelFilter.apply(
            query: "   ",
            to: sections,
            all: state.providers,
            snapshots: state.snapshots
        ).isFiltered)
    }

    @MainActor
    func testAQueryFlattensEverySectionAndOpensTheCollapsedBlock() throws {
        let state = AppState()
        let claude = try XCTUnwrap(state.providers.first { $0.serviceID == "claude" })
        let copilot = try XCTUnwrap(state.providers.first { $0.serviceID == "copilot" })
        let cursor = try XCTUnwrap(state.providers.first { $0.serviceID == "cursor" })

        let sections = [
            AppearanceSettings.PanelSection(id: "main", title: nil, providers: [claude]),
            AppearanceSettings.PanelSection(id: "band.idle", title: "Idle", providers: [cursor]),
            AppearanceSettings.PanelSection(
                id: "disconnected", title: "Not connected",
                providers: [copilot], isCollapsible: true
            )
        ]

        let outcome = PanelFilter.apply(
            query: "copilot",
            to: sections,
            all: state.providers,
            snapshots: state.snapshots
        )
        XCTAssertTrue(outcome.isFiltered)
        XCTAssertTrue(
            outcome.sections.isEmpty,
            "the filtered outcome still carries sections — `adoptExpansion` could then be fed them"
        )
        XCTAssertEqual(
            outcome.rows.map(\.id), [copilot.id],
            "a matching row inside the collapsed block was not drawn"
        )
    }

    // MARK: - The hint

    @MainActor
    func testAMatchTheAppearanceSettingsAreHidingIsNamed() throws {
        let state = AppState()
        let claude = try XCTUnwrap(state.providers.first { $0.serviceID == "claude" })
        // Exactly what `hidesQuotalessServices` leaves behind: Copilot is enabled
        // and simply absent from the sections the panel was handed.
        let sections = [AppearanceSettings.PanelSection(id: "main", title: nil, providers: [claude])]

        let outcome = PanelFilter.apply(
            query: "copilot",
            to: sections,
            all: state.providers,
            snapshots: state.snapshots
        )
        XCTAssertTrue(outcome.rows.isEmpty)
        XCTAssertEqual(outcome.hint, "GitHub Copilot is hidden by your Appearance settings.")
    }

    @MainActor
    func testAMatchThatIsSwitchedOffIsNamed() throws {
        let state = AppState()
        let claude = try XCTUnwrap(state.providers.first { $0.serviceID == "claude" })
        let copilot = try XCTUnwrap(state.providers.first { $0.serviceID == "copilot" })
        copilot.isEnabled = false
        let sections = [AppearanceSettings.PanelSection(id: "main", title: nil, providers: [claude])]

        let outcome = PanelFilter.apply(
            query: "copilot",
            to: sections,
            all: state.providers,
            snapshots: state.snapshots
        )
        XCTAssertTrue(outcome.rows.isEmpty)
        XCTAssertEqual(
            outcome.hint, "GitHub Copilot is switched off in Settings → Services.",
            "switched off outranks hidden: it is the further of the two from being on screen, "
            + "and the two destinations are different panes"
        )
    }

    @MainActor
    func testAQueryThatMatchesNothingAnywhereHasNoHint() throws {
        let state = AppState()
        let claude = try XCTUnwrap(state.providers.first { $0.serviceID == "claude" })
        let sections = [AppearanceSettings.PanelSection(id: "main", title: nil, providers: [claude])]
        let outcome = PanelFilter.apply(
            query: "qqqq",
            to: sections,
            all: state.providers,
            snapshots: state.snapshots
        )
        XCTAssertTrue(outcome.isFiltered)
        XCTAssertTrue(outcome.rows.isEmpty)
        XCTAssertNil(outcome.hint, "the panel falls back to \"Escape clears the filter.\" on nil")
    }

    // MARK: - Candidates come off the row's own strings

    /// A filter matching an account string the row does not print would be
    /// filtering on something invisible, so the candidate is built through the
    /// same fallback and the same prettifier `ProviderRow` uses.
    @MainActor
    func testTheCandidateCarriesTheStringsTheRowPrints() throws {
        let state = AppState()
        let claude = try XCTUnwrap(state.providers.first { $0.serviceID == "claude" })
        let snapshot: Result<UsageData, ProviderError> = .success(UsageData(
            providerID: claude.id,
            planName: "Default_Claude_Max_20X",
            primary: UsageMetric(label: "5h session", used: 40, limit: 100, unit: "%"),
            accountLabel: "ada@example.com"
        ))
        claude.isAuthenticated = true

        let candidate = PanelFilter.candidate(for: claude, snapshot: snapshot)
        XCTAssertEqual(candidate.id, claude.id)
        XCTAssertEqual(candidate.serviceID, "claude")
        XCTAssertEqual(candidate.displayName, "Claude")
        XCTAssertEqual(candidate.accountLabel, "ada@example.com")
        XCTAssertEqual(
            candidate.planName, PlanName.pretty("Default_Claude_Max_20X", service: "Claude"),
            "the plan is matched raw rather than as the row prints it"
        )
    }

    // MARK: - Helper

    @MainActor
    private static func sections(_ state: AppState, count: Int) -> [AppearanceSettings.PanelSection] {
        let providers = Array(state.providers.prefix(count))
        return [AppearanceSettings.PanelSection(id: "main", title: nil, providers: providers)]
    }
}
