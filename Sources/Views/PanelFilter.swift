import SwiftUI

/// What a typed query does to the panel's list.
///
/// Pure, and that is the whole reason it is a file of its own: every decision the
/// filter makes — what counts as a match, which match comes first, what happens to
/// the group headers, what to say when nothing matched — is arithmetic over
/// strings, and none of it needs a view to be checked. The panel is left with the
/// part that genuinely is drawing.
///
/// It searches *what the panel would draw*, never the whole service list. Anything
/// the user's settings have taken off the panel stays off it while filtering, and
/// the one thing a query does about that is name it: see `hint(query:...)`. A
/// filter that resurrected a hidden row would be the search box overruling the
/// settings pane, silently, on a keystroke.
public enum PanelFilter {

    // MARK: - What a row offers the filter

    /// One drawn row, reduced to the strings a query may match.
    ///
    /// Every field is a string the row itself prints. That is deliberate and it is
    /// the rule the type exists to hold: a filter matching an account string the
    /// row does not show is filtering on something invisible, so `accountLabel`
    /// and `planName` are taken through the same three-step fallback and the same
    /// prettifier `ProviderRow` uses rather than off `UsageData` directly.
    public struct Candidate: Equatable {
        /// The row identity — `"claude#2"` — which is what a selection and a
        /// `scrollTo` are keyed by.
        public let id: String
        public let serviceID: String
        public let displayName: String
        public let accountLabel: String?
        public let planName: String?

        public init(
            id: String,
            serviceID: String,
            displayName: String,
            accountLabel: String? = nil,
            planName: String? = nil
        ) {
            self.id = id
            self.serviceID = serviceID
            self.displayName = displayName
            self.accountLabel = accountLabel
            self.planName = planName
        }
    }

    /// The candidate for a row, built the way the row builds its own two strings.
    @MainActor
    public static func candidate(
        for provider: AnyUsageProvider,
        snapshot: Result<UsageData, ProviderError>?
    ) -> Candidate {
        var account = AppState.customAccountName(for: provider.id)
        if account == nil, case .success(let data)? = snapshot,
           let label = data.accountLabel, !label.isEmpty {
            account = label
        }
        if account == nil, provider.accountID != nil || provider.browserOrigin != nil {
            account = provider.browserOrigin
        }

        var plan: String?
        if case .success(let data)? = snapshot, provider.isAuthenticated, let raw = data.planName {
            plan = PlanName.pretty(raw, service: provider.displayName)
        }

        return Candidate(
            id: provider.id,
            serviceID: provider.serviceID,
            displayName: provider.displayName,
            accountLabel: account,
            planName: plan
        )
    }

    // MARK: - Normalisation

    /// Case- and diacritic-folded, then stripped to a-z0-9.
    ///
    /// Stripping the punctuation is what makes "zai" find "Z.ai" without an alias
    /// for it, and what makes the two-word "claude code" a prefix of the
    /// single-token "claudecode". Folded rather than `lowercased()` because
    /// `lowercased()` is locale-sensitive and a Turkish locale turns a query for
    /// "MInimax" into something that matches nothing — the dotless ı it produces
    /// for the capital I is a different scalar from the i in the name.
    public static func normalise(_ text: String) -> String {
        let folded = text.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: nil
        )
        var kept = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where CharacterSet.alphanumerics.contains(scalar) {
            // ASCII-lowered rather than through `lowercased()`, for the locale
            // reason above. The case fold has already flattened every letter that
            // has a case, so this is belt to that brace and costs one comparison.
            if scalar.value >= 65, scalar.value <= 90, let lower = Unicode.Scalar(scalar.value + 32) {
                kept.append(lower)
            } else {
                kept.append(scalar)
            }
        }
        return String(kept)
    }

    /// The first letter of each whitespace-separated word, and for a single-word
    /// name the capitals in order. "Claude Code" -> "cc", "GitHub Copilot" -> "gc",
    /// "OpenRouter" -> "or", "MiniMax" -> "mm", "DeepSeek" -> "ds",
    /// "ChatGPT" -> "cgpt". Computed rather than tabled, so a service added to
    /// `AppState.services` gets its initials without anyone remembering to.
    public static func initials(of displayName: String) -> String {
        let words = displayName.split(whereSeparator: { $0.isWhitespace })
        if words.count > 1 {
            return normalise(String(words.compactMap(\.first)))
        }
        guard let word = words.first else { return "" }
        let capitals = word.filter(\.isUppercase)
        // A name with no interior capital — "Cursor", "Codex" — has no initials
        // worth the name, and returning its first letter would put a one-letter
        // exact match in band 800 above every prefix.
        guard capitals.count > 1 else { return "" }
        return normalise(String(capitals))
    }

    /// Alternative names, keyed by `serviceID`.
    ///
    /// Kept short and collision-free rather than tuned: an alias that is also a
    /// prefix of another service's name — `"mi"` for Mistral, which prefixes
    /// MiniMax — makes the ordering unexplainable, because the reader sees two
    /// rows and no way to tell why one is above the other. Those are absent
    /// rather than ranked.
    ///
    /// The two empty entries are deliberate and are not dead weight: they are the
    /// record that Cursor and Mistral were considered and have nothing safe to
    /// add, so the next person to read this list does not re-derive the collision.
    static let aliasTable: [String: [String]] = [
        "claude":     ["anthropic"],
        "claudecode": ["cc", "code"],
        "chatgpt":    ["gpt", "openai", "oai"],
        "codex":      ["cx"],
        "gemini":     ["google", "bard"],
        "grok":       ["xai"],
        "perplexity": ["pplx"],
        "deepseek":   ["ds"],
        "cursor":     [],
        "copilot":    ["github", "gh", "ghc"],
        "openrouter": ["or"],
        "mistral":    [],
        "minimax":    ["mm"],
        "zai":        ["glm", "zhipu"],
        "opencode":   ["oc"]
    ]

    // MARK: - Scoring

    /// nil means "this row is not a match". Higher is better.
    ///
    /// Banded, first hit wins, and deliberately **not** a sum of bonuses. A score
    /// that adds a name bonus to a plan bonus to a recency bonus cannot be
    /// explained to the user looking at the list and cannot be asserted in a test
    /// either — the number that comes out is only ever checked against itself. A
    /// band can be stated in one line, and the line is the table below.
    ///
    /// The two length gates are the difference between a filter and a shuffler. A
    /// one-character subsequence match hits nearly every row and a one-character
    /// initials match hits four, so at those lengths the list would reorder
    /// without narrowing — which is the worst thing a filter can do, because the
    /// row the eye had already found moves.
    public static func score(_ query: String, against candidate: Candidate) -> Int? {
        let needle = normalise(query)
        guard !needle.isEmpty else { return nil }

        let name = normalise(candidate.displayName)
        let service = normalise(candidate.serviceID)
        let aliases = (aliasTable[candidate.serviceID] ?? []).map(normalise)

        if needle == name || needle == service || aliases.contains(needle) { return 1000 }
        if name.hasPrefix(needle) { return 900 }
        if aliases.contains(where: { $0.hasPrefix(needle) }) { return 850 }
        if needle.count >= 2, needle == initials(of: candidate.displayName) { return 800 }
        if service.hasPrefix(needle) { return 700 }
        if name.contains(needle) { return 600 }
        if service.contains(needle) { return 500 }

        let account = candidate.accountLabel.map(normalise) ?? ""
        if !account.isEmpty {
            if account.hasPrefix(needle) { return 450 }
            if account.contains(needle) { return 400 }
        }

        let plan = candidate.planName.map(normalise) ?? ""
        if !plan.isEmpty, plan.contains(needle) { return 300 }

        if needle.count >= 3, isSubsequence(needle, of: name) { return 200 }
        return nil
    }

    /// Every character of `needle` appearing in `haystack` in order, gaps allowed.
    /// The band it serves is the one that finds "Claude Code" from "clcd".
    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        var remaining = Substring(needle)
        for character in haystack where character == remaining.first {
            remaining = remaining.dropFirst()
            if remaining.isEmpty { return true }
        }
        return remaining.isEmpty
    }

    /// One row that matched, and how well.
    public struct Match: Equatable {
        public let id: String
        public let score: Int

        public init(id: String, score: Int) {
            self.id = id
            self.score = score
        }
    }

    /// Score-major, incoming-order-minor.
    ///
    /// **Ties keep the panel's own order**, which is whatever `sortOrder` and
    /// `grouping` already produced: a user on `.urgency` gets the busiest matching
    /// service first and a user on `.manual` gets their own arrangement back. The
    /// index is carried explicitly rather than left to the sort, because
    /// `sorted(by:)` is not stable and `AppearanceSettings.ordered(_:)` says so in
    /// its own comment — two equally-good matches swapping places between
    /// keystrokes is the same defect as rows swapping between refreshes.
    public static func rank(_ query: String, over candidates: [Candidate]) -> [Match] {
        var scored: [(index: Int, match: Match)] = []
        for (index, candidate) in candidates.enumerated() {
            guard let score = score(query, against: candidate) else { continue }
            scored.append((index, Match(id: candidate.id, score: score)))
        }
        scored.sort { lhs, rhs in
            lhs.match.score == rhs.match.score
                ? lhs.index < rhs.index
                : lhs.match.score > rhs.match.score
        }
        return scored.map(\.match)
    }

    // MARK: - Applying it to the panel

    /// What the panel draws for a query.
    public struct Outcome {
        /// What to draw when nothing is being filtered. Empty while filtering.
        public let sections: [AppearanceSettings.PanelSection]
        /// The rows to draw, flat and in drawn order. Also populated when *not*
        /// filtering, because the keyboard needs the drawn order in both states —
        /// an arrow key on a resting panel has to know what row one is.
        public let rows: [AnyUsageProvider]
        public let isFiltered: Bool
        /// A matching row the panel is not allowed to show, named.
        public let hint: String?

        public init(
            sections: [AppearanceSettings.PanelSection],
            rows: [AnyUsageProvider],
            isFiltered: Bool,
            hint: String?
        ) {
            self.sections = sections
            self.rows = rows
            self.isFiltered = isFiltered
            self.hint = hint
        }
    }

    /// The query applied to the sections the panel was about to draw.
    ///
    /// Two structural rules, both of which have a failure mode worth naming:
    ///
    /// **Every group header is dropped while filtering, including the collapsed
    /// block's, and the collapsed block is opened.** A filter has already answered
    /// "which rows", so a header reading `Not connected 9` over one matching row is
    /// furniture; and a chevron that hides a match makes the filter lie about what
    /// it found.
    ///
    /// **The filtered sections are never fed back to the panel's expansion
    /// bookkeeping.** `sections` comes back empty while filtering precisely so that
    /// a caller cannot accidentally hand this to `adoptExpansion`: filtering down to
    /// one connected row would make the disconnected block "the only block", which
    /// marks it uncollapsible, and clearing the filter would then force-expand nine
    /// rows the user had folded away.
    @MainActor
    public static func apply(
        query: String,
        to sections: [AppearanceSettings.PanelSection],
        all providers: [AnyUsageProvider],
        snapshots: [String: Result<UsageData, ProviderError>]
    ) -> Outcome {
        let drawn = sections.flatMap(\.providers)
        guard !normalise(query).isEmpty else {
            return Outcome(sections: sections, rows: drawn, isFiltered: false, hint: nil)
        }

        let candidates = drawn.map { candidate(for: $0, snapshot: snapshots[$0.id]) }
        let ranked = rank(query, over: candidates)
        var byID: [String: AnyUsageProvider] = [:]
        for provider in drawn { byID[provider.id] = provider }
        let rows = ranked.compactMap { byID[$0.id] }

        guard rows.isEmpty else {
            return Outcome(sections: [], rows: rows, isFiltered: true, hint: nil)
        }

        // Only worth building the two pools when there is nothing to show: they
        // are a sentence under an empty list and nothing else.
        let shown = Set(drawn.map(\.id))
        let disabled = providers.filter { !$0.isEnabled }
            .map { candidate(for: $0, snapshot: snapshots[$0.id]) }
        let hidden = providers.filter { $0.isEnabled && !shown.contains($0.id) }
            .map { candidate(for: $0, snapshot: snapshots[$0.id]) }

        return Outcome(
            sections: [],
            rows: [],
            isFiltered: true,
            hint: hint(query: query, enabledButHidden: hidden, disabled: disabled)
        )
    }

    /// The best match among the rows the panel is not allowed to draw, as a
    /// sentence naming where it went.
    ///
    /// Without it, a user with `hidesQuotalessServices` on types "copilot", gets
    /// nothing back, and concludes the filter is broken rather than that a setting
    /// is doing exactly what they asked it to. Switched off outranks hidden because
    /// it is the further of the two from being on screen, and because the two
    /// destinations are different panes.
    public static func hint(
        query: String,
        enabledButHidden: [Candidate],
        disabled: [Candidate]
    ) -> String? {
        if let best = best(query, among: disabled) {
            return "\(best.displayName) is switched off in Settings → Services."
        }
        if let best = best(query, among: enabledButHidden) {
            return "\(best.displayName) is hidden by your Appearance settings."
        }
        return nil
    }

    private static func best(_ query: String, among candidates: [Candidate]) -> Candidate? {
        guard let top = rank(query, over: candidates).first else { return nil }
        return candidates.first { $0.id == top.id }
    }
}
