import SwiftUI

/// The meter fill's outline: arced at the leading end, arced or square at the
/// trailing one.
///
/// A square trailing end is the *shape* channel of the near-cap contract — one
/// of the three that carry "at or above the warning threshold", alongside the
/// figure's weight stepping up and the fill occupying all but a sliver of its
/// track. It is the one that survives greyscale, a colour-blind eye and
/// `ColorRamp.mono` alike, which is what the contrast rule needs: near-cap is
/// never signalled by colour on its own. It has to be the fill's own geometry
/// rather than a cap drawn over it, because the fill is what animates and a
/// separate cap would lag behind it by a frame.
///
/// Deliberately not `UnevenRoundedRectangle`: that is macOS 14 and the floor
/// here is 13. It is built from tangent arcs rather than from two shapes unioned
/// because a `Capsule` with a `Rectangle` laid over its right half is two fills,
/// and two fills at different opacities under the same gradient do not match.
///
/// This is the whole of the meter's geometry now. The pace riser, the cut it
/// was punched into and the two-tone elapsed track were an instrument invented
/// for this panel, and an instrument nobody arrives already knowing has to be
/// documented before it can be read. Pace still has a sentence in
/// `ForecastLine`, which is where a quiet UI puts it — so what went was a
/// drawing, not a reading.
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
        // overhanging the width it was given, and a fill 1pt wide on a 4pt bar
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
