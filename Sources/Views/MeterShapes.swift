import SwiftUI

/// The meter fill's outline: arced at the leading end, arced or square at the
/// trailing one.
///
/// A square trailing end is the *shape* channel of the near-cap contract — one
/// of the four that carry "at or above the warning threshold", and the one that
/// survives greyscale, a colour-blind eye and `ColorRamp.mono` alike. It has to
/// be the fill's own geometry rather than a cap drawn over it, because the fill
/// is what animates and a separate cap would lag behind it by a frame.
///
/// Deliberately not `UnevenRoundedRectangle`: that is macOS 14 and the floor
/// here is 13. It is built from tangent arcs rather than from two shapes unioned
/// because a `Capsule` with a `Rectangle` laid over its right half is two fills,
/// and two fills at different opacities under the same gradient do not match.
public struct MeterFill: Shape {
    /// True at or above `warningThreshold`. The leading end never changes: it is
    /// pinned to the start of the track and has nothing to report.
    public let squareTrailing: Bool

    public init(squareTrailing: Bool) {
        self.squareTrailing = squareTrailing
    }

    public func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }

        // The full cap is a semicircle on the bar's own thickness, which is what
        // makes a fill sit inside a capsule track without a seam.
        let cap = rect.height / 2
        // A fill narrower than its own cap cannot draw that cap without
        // overhanging the width it was given, and a fill 2pt wide on a 6pt bar
        // is a real state — it is what 1% looks like. Both radii shrink to fit
        // instead: with a square trailing end the leading cap has the whole
        // width to itself, with two caps they share it.
        let leading = squareTrailing ? min(cap, rect.width) : min(cap, rect.width / 2)
        let trailing = squareTrailing ? 0 : leading

        // Clockwise from just past the top-leading corner. `addArc(tangent1End:)`
        // degenerates to a line at radius 0, so the square end needs no branch of
        // its own — the corner is the same call with nothing to round.
        path.move(to: CGPoint(x: rect.minX + leading, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - trailing, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.maxY),
            radius: trailing
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.maxY),
            radius: trailing
        )
        path.addLine(to: CGPoint(x: rect.minX + leading, y: rect.maxY))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
            tangent2End: CGPoint(x: rect.minX, y: rect.minY),
            radius: leading
        )
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
            radius: leading
        )
        path.closeSubpath()
        return path
    }
}

/// Where the pace notch goes, as arithmetic with no view in it.
///
/// The notch is the signature of the meter: every usage window carries two
/// quantities the user is comparing — how much is gone, and how much of the
/// window is gone — and everyone else draws only the first. Being four numbers
/// rather than a picture, it is also the part that can be asserted instead of
/// eyeballed, which is why it lives here and not inside `ProviderRow`. The panel
/// row, the Appearance pane's sample and any later header meter all read from
/// this one copy; a private copy per call site is exactly how a preview comes to
/// disagree with the thing it previews.
public enum PaceGeometry {

    /// How far through its window this metric is, 0...1, or nil when that cannot
    /// be known.
    ///
    /// Nil, never 0. A notch on a made-up duration is a made-up instrument, and
    /// 0 would draw one at the left edge of every window a provider declines to
    /// describe — which reads as "the window just started" rather than as "the
    /// window is not measured". A row with no elapsed fraction gets a uniform
    /// track and no tick.
    public static func elapsed(
        resetDate: Date?,
        windowDuration: TimeInterval?,
        now: Date
    ) -> Double? {
        guard let resetDate, let windowDuration else { return nil }
        // A zero or negative duration is not a shorter window, it is a provider
        // saying something that cannot be divided by. Same for the non-finite
        // values a JSON number can carry in.
        guard windowDuration > 0, windowDuration.isFinite else { return nil }

        let remaining = resetDate.timeIntervalSince(now)
        guard remaining.isFinite else { return nil }
        // A reset date in the past means the window has run out and nothing has
        // refreshed it yet, so it clamps to full rather than reading as overdue.
        return clamp(1 - remaining / windowDuration)
    }

    /// The x of the notch on a track `width` wide, measured from its leading
    /// edge. This is the centre line of the tick, not its leading edge — the
    /// caller owns how wide the mark is and therefore how it straddles this.
    ///
    /// Not rounded to a whole point. The tick would snap a point at a time as
    /// the window elapses, which on a five-hour window is a visible twitch every
    /// few minutes, and the fill it is being compared against is fractional too.
    public static func notchX(elapsed: Double, width: CGFloat) -> CGFloat {
        guard width > 0 else { return 0 }
        return width * CGFloat(clamp(elapsed))
    }

    /// How far the notch stands above the bar.
    ///
    /// It costs zero row height: the smallest `contentSpacing` is 3pt and this
    /// never exceeds 2, so the tick lives in the gap that already exists between
    /// the title line and the bar. `MenuBarExtra` sizes its window to content, so
    /// a meter treatment that grew every row would be paid nine times.
    public static func overhang(barHeight: CGFloat) -> CGFloat {
        guard barHeight.isFinite else { return 1 }
        return min(2, max(1, (barHeight * 0.3).rounded()))
    }

    /// Whether the fill has crossed the notch — the *position* channel of the
    /// pace contract, and the condition everything the fill then does hangs off:
    /// `MeterCut` owns whether the fill is cut for it and what ink the mark
    /// takes either way.
    ///
    /// Strict: exactly on pace has reached the notch, not passed it. The whole
    /// point of the mark is the comparison, and the honest answer at the
    /// boundary is "not yet".
    public static func fillHasPassedNotch(percent: Double, elapsed: Double) -> Bool {
        guard percent.isFinite, elapsed.isFinite else { return false }
        return clamp(percent) > clamp(elapsed)
    }

    /// 0...1, with a NaN answering 0 rather than surviving the comparison.
    /// `min`/`max` both lose to a NaN, so it would otherwise reach a frame width
    /// and take the layout with it.
    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }
}

/// The cut: where the fill is punched back to ground so the mark at the pace
/// boundary survives being overtaken.
///
/// The third channel of the same instrument. The two-tone track says how much of
/// the window is gone, the mark stands at the boundary, and the cut is what
/// happens when the fill goes past it — a band of `Surface.onFill` driven clean
/// through the fill, with the mark left standing in the middle of it. The length
/// of fill beyond the band is then the overspend, read straight off the bar with
/// no number attached to it. Nobody else's meter can say that, which is the
/// point of drawing both quantities in one instrument instead of two.
///
/// The band runs the bar's own thickness and no further: above the bar the mark
/// already stands on the panel's ground, where there is nothing to cut.
///
/// Pure, and beside `PaceGeometry` for the reason that type is pure — whether a
/// row is cut, how wide the gap is and where it lands are numbers, and numbers
/// can be asserted rather than eyeballed. `MeterTrack` and `UsageRing` both read
/// from this one copy, the dial drawing the same band radially across its stroke,
/// so a bar and a dial on the same reading cannot disagree about whether it is
/// overspending.
///
/// One naming note, because the design and the code use different words for the
/// same 1pt mark: what the design calls the *riser* is what `PaceGeometry` and
/// `Tokens` call the *notch*.
public enum MeterCut {

    /// Whether the fill is cut at all.
    ///
    /// `elapsed` is optional because an undescribed window has no boundary to
    /// overtake, and that refusal belongs here rather than at both call sites —
    /// it is the same nil `PaceGeometry.elapsed` hands back, carried one step
    /// further.
    ///
    /// The thickness floor is not a detail. A 3pt bar interrupted by a band
    /// wider than it is thick reads as a bar snapped in two rather than as a
    /// fill overtaking a mark, and at that thickness there is no room for the
    /// mark to survive inside the gap it just made — which is the entire purpose
    /// of the gap. Below the floor the mark goes back to being drawn in
    /// `Surface.onFill` where the fill covers it, which is the reading a thin bar
    /// can still carry.
    public static func isCut(percent: Double, elapsed: Double?, barHeight: CGFloat) -> Bool {
        guard let elapsed else { return false }
        // A non-finite height survives `>=` as false, but only because the test
        // is written this way round rather than as `!(barHeight < floor)`.
        guard barHeight.isFinite, barHeight >= Tokens.Meter.cutMinBarHeight else { return false }
        return PaceGeometry.fillHasPassedNotch(percent: percent, elapsed: elapsed)
    }

    /// How wide the gap is: the mark, plus a clearance either side of it.
    ///
    /// Both halves come off `Tokens` rather than being written down here, because
    /// both answer to increased contrast — the mark widens with `notchWidth` and
    /// the clearance is what keeps it separable from the saturated fill it is
    /// standing in. Measured in points rather than in degrees so the dial can use
    /// it too: a band this narrow across a ring's stroke is a rotated rectangle,
    /// exactly as the dial already draws the mark itself.
    public static func width(increasedContrast: Bool) -> CGFloat {
        Tokens.notchWidth(increased: increasedContrast) + 2 * Tokens.Meter.cutClearance
    }

    /// The centre line of the gap on a track `trackWidth` wide.
    ///
    /// The mark's own x, deliberately: the cut is not an event of its own, it is
    /// the mark's clearance. A gap centred anywhere else would read as a second
    /// thing having happened on the bar.
    public static func centreX(elapsed: Double, trackWidth: CGFloat) -> CGFloat {
        PaceGeometry.notchX(elapsed: elapsed, width: trackWidth)
    }

    /// The gap's leading edge, which is what a caller offsets a rectangle by.
    ///
    /// It can land at a negative x, and that is correct: early in a window the
    /// mark sits near the leading edge and half the clearance falls outside the
    /// track. The caller clips the band to the fill it is punching through, so
    /// that half has nothing to land on — and clipping is required either way,
    /// because ground laid over the *empty* part of the track would read as a
    /// break in the track rather than as a break in the fill. Clamping the x
    /// here instead would walk the gap off centre and leave the mark standing
    /// against the fill on one side.
    public static func leadingX(
        elapsed: Double,
        trackWidth: CGFloat,
        increasedContrast: Bool
    ) -> CGFloat {
        centreX(elapsed: elapsed, trackWidth: trackWidth)
            - width(increasedContrast: increasedContrast) / 2
    }

    /// The ink the mark takes for the half of it that crosses the bar. The half
    /// standing above the bar never changes and is always the notch colour: the
    /// fill cannot reach it.
    ///
    /// One function, because these are two halves of one decision and getting it
    /// backwards is invisible in code and glaring on screen. Inside a cut the
    /// mark stands on ground and keeps its own colour — drawing it in
    /// `Surface.onFill` there would be a ground-coloured mark on a
    /// ground-coloured gap, which is nothing at all. Uncut and covered by the
    /// fill it is the other way round: the mark is what the fill is missing.
    public static func markInk(
        isCut: Bool,
        coveredByFill: Bool,
        increasedContrast: Bool
    ) -> Color {
        coveredByFill && !isCut
            ? Tokens.Surface.onFill
            : Tokens.notchColour(increased: increasedContrast)
    }
}
