import Foundation

/// One service's showing in the menu bar: which mark to draw, and what number
/// goes beside it.
///
/// The old strip drew four abstract bars and there was no way to tell which bar
/// was Claude — a meter with no identity is decoration. Every entry now names
/// the service it measures, so the renderer can put a brand mark against a
/// figure instead of a nameless column.
public struct MenuBarEntry: Equatable, Sendable {
    /// The service family, not the account: "claude" for both of two Claude
    /// subscriptions. The renderer keys its brand mark off this.
    public let serviceID: String
    /// What the service is called, spelled out. The strip has room for a glyph
    /// and a figure and nothing else, so this exists for VoiceOver.
    public let displayName: String
    /// 0…1, or nil when there is no figure to show. Status-only services are
    /// the ordinary way to get nil: ChatGPT reports a subscription and Copilot
    /// reports a seat, neither of which is a quota. They must never be handed a
    /// percentage — an invented 0 reads as plenty left, an invented 100 reads as
    /// capped, and both are claims the provider did not make.
    public let percent: Double?

    public init(serviceID: String, displayName: String, percent: Double?) {
        self.serviceID = serviceID
        self.displayName = displayName
        // Clamped rather than trusted, for the reason `UsageMetric.percent` is:
        // a non-finite figure survives `min`/`max` and then traps in `Int(_:)`.
        // A NaN becomes nil rather than 0 because it is not a reading of zero,
        // and a dash is the honest way to say there is no number.
        self.percent = percent.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
    }

    /// What the strip prints, three characters at most. The status item shares a
    /// 22pt bar with everyone else's, so a figure that can grow is an item that
    /// can push its neighbours off the end of the screen — and on a laptop with
    /// a notch, off is off.
    ///
    /// Three is the same three `StripFit` reserves a cell for. It sizes that cell
    /// from the widest reading this can produce and never from the string in
    /// hand, so a fourth character here would not widen the cell — it would
    /// overrun it. Widening the reading means widening the rail with it.
    public var figure: String {
        guard let percent else { return Self.noFigure }
        // Rounded to whole points, but never rounded up into the cap: 99.6% is
        // not 100%, and a strip that says a service is finished while there is
        // headroom left teaches the user to distrust the one reading they most
        // need to believe.
        let whole = Int((percent * 100).rounded())
        return String(percent >= 1 ? 100 : min(whole, 99))
    }

    /// An em dash, and deliberately not a zero or a blank. "Reports no quota" is
    /// a thing worth saying, and it is not the same statement as "0%".
    public static let noFigure = "—"
}

/// Which services the status item carries, in what order, and what it says out
/// loud. Pure on purpose: this is the whole of the decision, so it is the part
/// that has to be assertable without a menu bar to look at.
///
/// Which services, and deliberately not how wide they are. The strip's width —
/// the reserved figure cell, and dropping a segment that will not fit the width
/// budget — is `StripFit`'s, which takes the order produced here and preserves
/// it. Two files because they answer to two different things: this one to the
/// user's chosen count and to who is nearest a cap, that one to the point size
/// the figures are set at. Nothing here may start measuring, because a figure
/// measured from the string in hand is the jitter the reserved cell exists to
/// prevent.
public enum MenuBarStripContent {
    /// How many entries the strip may draw. One is a real choice for someone
    /// with one subscription; past three the item is wider than the menu bar can
    /// spare on the machines this app is for.
    ///
    /// A count and not a width: the same three services are wider at a 16pt
    /// glyph than at a 10pt one, so `StripFit` may still drop one this allowed.
    /// The count is a preference and the width is a constraint, and the
    /// preference is applied first.
    public static let range: ClosedRange<Int> = 1...3

    /// The entries to draw, closest to their cap first.
    ///
    /// Ordering by urgency rather than by declared order matches the panel's own
    /// `rankedProviders`, so the leftmost mark in the menu bar is the topmost row
    /// in the list that opens under it.
    public static func entries(from entries: [MenuBarEntry], limit: Int) -> [MenuBarEntry] {
        var seen: Set<String> = []
        let ranked = entries
            .enumerated()
            .sorted { lhs, rhs in
                let a = urgency(lhs.element), b = urgency(rhs.element)
                if a != b { return a > b }
                // Declared order is the tiebreak, because `sorted` is not stable
                // and two idle services must not swap places between refreshes.
                return lhs.offset < rhs.offset
            }
            .map(\.element)
            // Two accounts of one service would draw the same mark twice with
            // two different numbers, which reads as a rendering fault rather
            // than as two subscriptions. The strip keeps whichever is closer to
            // its cap; the panel is where accounts are told apart.
            .filter { seen.insert($0.serviceID).inserted }

        return Array(ranked.prefix(clamped(limit)))
    }

    /// What VoiceOver reads out for the status item.
    ///
    /// Give it the entries the strip is actually drawing, so it describes what
    /// is on screen rather than everything that was available to draw.
    public static func accessibilityLabel(_ entries: [MenuBarEntry]) -> String {
        guard !entries.isEmpty else { return "AI usage: nothing reported yet" }
        let parts = entries.map { entry -> String in
            // Spelled out rather than read as a dash, which VoiceOver announces
            // as either "dash" or as nothing at all depending on its verbosity.
            guard entry.percent != nil else { return "\(entry.displayName) reports no quota" }
            return "\(entry.displayName) \(entry.figure)%"
        }
        return "AI usage: " + parts.joined(separator: ", ")
    }

    /// Status-only entries sort below every measured one: they carry no urgency,
    /// so they can never displace a service that is actually near a cap.
    private static func urgency(_ entry: MenuBarEntry) -> Double {
        entry.percent ?? -1
    }

    private static func clamped(_ limit: Int) -> Int {
        min(max(limit, range.lowerBound), range.upperBound)
    }
}
