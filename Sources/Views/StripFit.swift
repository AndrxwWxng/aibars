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
/// takes a figure as an argument — `width(segments:style:height:)` is a function
/// of the count and the style's own cell, and that is the contract rather than an
/// optimisation.
///
/// Six styles now, and the contract survived being multiplied by six because it
/// is stated in a signature: a style answers `cellWidth(height:)` and there is no
/// parameter there that could carry a reading. `worstOnly` is the case that shows
/// what that buys — it draws a *name*, which changes when one service overtakes
/// another, inside a rail reserved in mono advances that does not.
///
/// Pure, and free of the rasteriser: the whole width contract is assertable
/// without a menu bar to look at or an image to measure. That is also why a style
/// arrives here as a `StripStyleBox` rather than as an `any StripStyle` — the box
/// carries `cellWidth` as a plain closure, so nothing in this file has to know
/// that a style also draws something.
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
    //
    // Of the three, only `segmentGap` is still load-bearing in this file: it is
    // the gap `width` puts between segments, and it is the one number a style does
    // not get to choose, so that switching between two styles never moves a
    // neighbouring status item by more than their cells differ. `markGap` and
    // `figureCell` are a style's business now — `Tokens.Strip` is where the six of
    // them read them from.

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
    /// the trailing edge while the drawing had been leading for as long as there
    /// had been a drawing, and recorded beside itself that trailing had been
    /// measured and rejected. Where the figure sits inside the cell is stated
    /// once, at `StripFigure` — which is what `MenuBarStripRenderer.figure(for:)`
    /// became when the six styles landed and three of them needed the same figure.
    public static func figureCell(height: CGFloat) -> CGFloat {
        Tokens.Strip.figureCell(height: height)
    }

    /// Total width the strip will occupy for a given segment count. A function
    /// of the count and the style — never of the figures — which is the
    /// invariant.
    ///
    /// The drawn content only. The status item adds its own margins either side
    /// and those are the system's to choose, so a cap stated here is a statement
    /// about what we draw.
    ///
    /// `style` is defaulted for one reason and it is not convenience: the
    /// Appearance pane and its tests read this function and belong to the change
    /// that gives the pane a style chooser. Until they have a style to pass, the
    /// honest value is the one the strip drew before there were six — see
    /// `StripStyleBox.markAndFigure`.
    public static func width(
        segments: Int,
        style: StripStyleBox = .markAndFigure,
        height: CGFloat
    ) -> CGFloat {
        guard segments > 0 else { return 0 }
        let count = CGFloat(segments)
        return count * style.cellWidth(height) + (count - 1) * segmentGap
    }

    // MARK: - Fitting

    /// The segments that actually fit, least urgent dropped first, source order
    /// preserved. Never returns empty while it was given anything.
    ///
    /// Three things can cost a segment: the user's own count, the style's own
    /// ceiling, and the width cap. The count is applied first because it is a
    /// preference and the other two are constraints — someone who asked for one
    /// service is not owed two because there happened to be room.
    public static func fit(
        _ entries: [MenuBarEntry],
        limit: Int,
        style: StripStyleBox = .markAndFigure,
        height: CGFloat
    ) -> [MenuBarEntry] {
        let capped = Array(entries.prefix(clamped(limit)))
        let room = maxSegments(style: style, height: height)
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

    // `segmentWidth(height:)` was here, and it was the mark's box, the gap and
    // the reserved figure cell — one style's arithmetic, written in the file that
    // measures every style. It is `StripStyleBox.cellWidth` now: there are six
    // answers and the type that draws each one is the type that states it.

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

    /// How many segments fit inside `Tokens.Strip.maxWidth`, and how many the
    /// style will draw at all.
    ///
    /// Never fewer than one: a status item with nothing in it is one the user
    /// can neither find nor click, and no width budget is worth that. Solved
    /// rather than accumulated — `width` is linear in the count, so adding
    /// segments up until one overflows would only restate the same arithmetic.
    ///
    /// The ceiling is the style's own statement and the cap is the bar's; the
    /// narrower of the two wins. `figureOnly` and `worstOnly` are the two that
    /// bind on the ceiling — the first because three bare numbers name nothing,
    /// the second because it draws the one service nearest its cap by definition —
    /// and for both the room the cap allows is larger than one.
    private static func maxSegments(style: StripStyleBox, height: CGFloat) -> Int {
        // n segments measure n * pitch - segmentGap, so the cap inverts cleanly.
        let pitch = style.cellWidth(height) + segmentGap
        let room = (Tokens.Strip.maxWidth + segmentGap) / pitch
        guard room.isFinite else { return 1 }
        return max(1, min(style.segmentCeiling, Int(room)))
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
