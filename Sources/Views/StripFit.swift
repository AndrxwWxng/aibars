import CoreGraphics

/// The strip's width discipline.
///
/// The status item drew each figure at its natural width, so one service
/// crossing 99 into 100 widened the item by a whole cell and shoved every icon
/// to its left sideways. That is the jitter tabular figures were adopted to
/// prevent, an order of magnitude larger: a digit that holds its width is worth
/// little if the box around it does not.
///
/// So every figure gets a reserved cell, sized once from the widest reading the
/// strip can produce and never from the string in hand. Measuring the current
/// string is exactly what reintroduces the jitter, which is why nothing here
/// takes a figure as an argument — `width(segments:height:)` is a function of
/// the count alone, and that is the contract rather than an optimisation.
///
/// Pure, and free of the rasteriser: the whole width contract is assertable
/// without a menu bar to look at or an image to measure.
public enum StripFit {

    // MARK: - The strip's rhythm

    /// A brand mark to the figure beside it.
    ///
    /// This and `segmentGap` are the two gaps that decide whether the strip
    /// reads as "mark, number, mark, number" or as one run of debris, and the
    /// answer is a legibility judgement at 12–14pt rather than a proportion of
    /// anything. They are deliberately not on `Tokens.Space`: that scale is
    /// calibrated for a 300pt panel, this is a 22pt bar.
    ///
    /// They are public because the view that draws the strip and the function
    /// that measures it have to be adding up the same strip. A private copy on
    /// either side is a width contract that can quietly stop being true, which
    /// is the class of bug this file exists to close.
    public static let markGap: CGFloat = 3

    /// One service's pair to the next service's. Wider than `markGap`, so a mark
    /// binds to its own number before it binds to the neighbour.
    public static let segmentGap: CGFloat = 5

    // MARK: - Measuring

    /// The reserved cell for one figure. Derived from the widest reading, not
    /// from the current one.
    ///
    /// `height` is the mark's height — `AppearanceSettings.menuBarGlyphHeight` —
    /// and the figure is set one point under it, because SF Mono's digits sit
    /// inside their line box and otherwise out-measure the logo beside them.
    /// Three cells wide whatever is in it, so "7", "100" and the em dash a
    /// status-only service shows all end on the same trailing edge.
    public static func figureCell(height: CGFloat) -> CGFloat {
        Tokens.figureWidth(figureSize(height), digits: figureDigits)
    }

    /// Total width the strip will occupy for a given segment count. A function
    /// of the count alone — never of the figures — which is the invariant.
    ///
    /// The drawn content only. The status item adds its own margins either side
    /// and those are the system's to choose, so a cap stated here is a statement
    /// about what we draw.
    public static func width(segments: Int, height: CGFloat) -> CGFloat {
        guard segments > 0 else { return 0 }
        let count = CGFloat(segments)
        return count * segmentWidth(height: height) + (count - 1) * segmentGap
    }

    // MARK: - Fitting

    /// The segments that actually fit, least urgent dropped first, source order
    /// preserved. Never returns empty while it was given anything.
    ///
    /// Two things can cost a segment: the user's own count and the width cap.
    /// The count is applied first because it is a preference and the cap is a
    /// constraint — someone who asked for one service is not owed two because
    /// there happened to be room.
    public static func fit(
        _ entries: [MenuBarEntry],
        limit: Int,
        height: CGFloat
    ) -> [MenuBarEntry] {
        let capped = Array(entries.prefix(clamped(limit)))
        let room = maxSegments(height: height)
        guard capped.count > room else { return capped }

        // Which segments survive is a ranking question; what order they draw in
        // is not. The survivors go back into the order they arrived in, because
        // a strip that reshuffled itself as one reading crossed a neighbour's
        // would be its own kind of jitter — and the caller has already ranked
        // them, so arrival order is the order of the panel underneath.
        return capped
            .enumerated()
            .sorted { lhs, rhs in
                let a = urgency(lhs.element), b = urgency(rhs.element)
                if a != b { return a > b }
                // `sorted` is not stable, and two idle services must not swap
                // places between refreshes.
                return lhs.offset < rhs.offset
            }
            .prefix(room)
            .sorted { $0.offset < $1.offset }
            .map(\.element)
    }

    // MARK: - Geometry

    /// One service's showing: the mark's box, the gap, and the reserved figure
    /// cell.
    private static func segmentWidth(height: CGFloat) -> CGFloat {
        markBox(height) + markGap + figureCell(height: height)
    }

    /// The mark is drawn in a box as wide as it is tall, so a wide logo and a
    /// narrow one take the same column and the figures stay in step across the
    /// strip.
    private static func markBox(_ height: CGFloat) -> CGFloat {
        guard height.isFinite else { return minimumSize }
        return max(minimumSize, height)
    }

    /// The figure's point size: one under the mark, and guarded for the reason
    /// `MenuBarEntry` guards its percentage — a non-finite argument survives
    /// every `max` here and then traps in the rounding inside `figureWidth`. The
    /// setting is clamped to 10…16, but this is public and pure and does not get
    /// to assume the settings object is its only caller.
    private static func figureSize(_ height: CGFloat) -> CGFloat {
        guard height.isFinite else { return minimumSize }
        return max(minimumSize, height - 1)
    }

    /// How many segments fit inside `Tokens.Strip.maxWidth`.
    ///
    /// Never fewer than one: a status item with nothing in it is one the user
    /// can neither find nor click, and no width budget is worth that. Solved
    /// rather than accumulated — `width` is linear in the count, so adding
    /// segments up until one overflows would only restate the same arithmetic.
    private static func maxSegments(height: CGFloat) -> Int {
        // n segments measure n * pitch - segmentGap, so the cap inverts cleanly.
        let pitch = segmentWidth(height: height) + segmentGap
        let room = (Tokens.Strip.maxWidth + segmentGap) / pitch
        guard room.isFinite else { return 1 }
        return max(1, Int(room))
    }

    // MARK: - Ranking

    /// Least urgent out first. Status-only services sort below every measured
    /// one: they carry no reading, so dropping one never costs the user a
    /// number. The rule `MenuBarStripContent` ranks by, restated here because
    /// that copy is private to the ordering it does there.
    private static func urgency(_ entry: MenuBarEntry) -> Double {
        entry.percent ?? -1
    }

    /// The same 1…3 the strip model applies, applied again rather than assumed.
    /// This is the last thing between a count and the status item, and a caller
    /// passing 0 must not produce an item with nothing in it.
    private static func clamped(_ limit: Int) -> Int {
        min(
            max(limit, MenuBarStripContent.range.lowerBound),
            MenuBarStripContent.range.upperBound
        )
    }

    /// Three, because "100" is the widest reading `MenuBarEntry.figure` can
    /// produce. The cell is sized from that once, not from whatever is being
    /// shown now.
    private static let figureDigits = 3

    /// A floor with no meaning beyond keeping the arithmetic sane on an argument
    /// the settings could never produce.
    private static let minimumSize: CGFloat = 1
}
