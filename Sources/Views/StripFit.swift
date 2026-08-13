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

    // This file used to *own* the strip's rhythm and geometry: `markGap`,
    // `segmentGap`, `figureDigits`, `markBox` and `figureSize` were all declared
    // here, and `Tokens.Strip` declared every one of them again. The view drew
    // from the Tokens copies and this file measured from its own, so the width
    // contract had two authors who agreed by luck — which is precisely the bug
    // the paragraph at the top of this file says the file exists to close, in the
    // file itself.
    //
    // Two of the five had already drifted. `Tokens.Strip.figureSize` was an
    // unguarded `height - 1` while the copy here was `max(1, height - 1)` behind
    // a non-finite guard, so at a height of 0.5 the renderer set a font from one
    // definition and reserved a cell from the other. And `markBox` here returned
    // `height` unrounded while the tuner offers half points, so at 13.5 the
    // figure cell began at x = 16.5 and every boundary after it landed between
    // pixels.
    //
    // So there is one author now, `Tokens.Strip`, and what is left below are
    // forwards. They are kept rather than deleted because the strip's callers and
    // its tests name them, and because a forward is where the reader of *this*
    // file finds out that the arithmetic is not here.

    /// `Tokens.Strip.markGap`. A brand mark to the figure beside it.
    public static let markGap: CGFloat = Tokens.Strip.markGap

    /// `Tokens.Strip.segmentGap`. One service's pair to the next service's, and
    /// wider than `markGap`, so a mark binds to its own number before it binds to
    /// the neighbour.
    public static let segmentGap: CGFloat = Tokens.Strip.segmentGap

    // MARK: - Measuring

    /// The reserved cell for one figure. Derived from the widest reading, not
    /// from the current one.
    ///
    /// `height` is the mark's height — `AppearanceSettings.menuBarGlyphHeight` —
    /// and the figure is set one point under it, because SF Mono's digits sit
    /// inside their line box and otherwise out-measure the logo beside them.
    /// Three cells wide whatever is in it, so "7", "100" and the em dash a
    /// status-only service shows all reserve the same column — *leading*-aligned,
    /// not trailing: this doc and `Tokens.Strip.figureCell`'s both used to claim
    /// the trailing edge while `MenuBarStripRenderer.figure(for:)` drew leading
    /// and recorded, beside the drawing, that trailing had been measured and
    /// rejected. Where the figure sits inside the cell is stated once, there.
    public static func figureCell(height: CGFloat) -> CGFloat {
        Tokens.Strip.figureCell(height: height)
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
        Tokens.Strip.markBox(height: height) + markGap + figureCell(height: height)
    }

    // `markBox(_:)` and `figureSize(_:)` were here. `Tokens.Strip.markBox` and
    // `Tokens.Strip.figureSize` are the definitions now, and they are not the
    // same functions these were: both round to a whole point, which this file's
    // copies did not, so a strip measured at the tuner's 13.5 no longer reserves
    // half-point cells. The non-finite guard came from here and survives there —
    // once, rather than as two guards with two different floors.
    //
    // `figureDigits` (3) and `minimumSize` (1) went with them: the first is
    // `Tokens.Strip.figureDigits` and the second was only ever the floor inside
    // those two guards.

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
}
