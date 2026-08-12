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
/// This and `MeterGeometry` are the whole of the meter's geometry now. The pace
/// riser, the cut it was punched into and the two-tone elapsed track were an
/// instrument invented for this panel, and an instrument nobody arrives already
/// knowing has to be documented before it can be read. Pace still has a sentence
/// in `ForecastLine`, which is where a quiet UI puts it — so what went was a
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
        // overhanging the width it was given. `MeterGeometry.fillWidth` floors a
        // resting fill at two thicknesses so that is no longer a state a reading
        // lands in, but it is still a width the shape is proposed: the fill
        // animates from its old width to its new one, and a preview or a sample
        // can be handed any track at all. Both radii shrink to fit instead: with
        // a square trailing end the leading cap has the whole width to itself,
        // with two caps they share it.
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

/// Where a reading becomes a length.
///
/// The bar and the dial draw the same number, so they have to round it, floor it
/// and clamp it the same way. A private copy of this arithmetic in each view is
/// exactly how a dial and a bar on the same 7% come to disagree — and disagreeing
/// with itself is the one thing a measuring instrument may not do.
///
/// Both floors exist because a meter that cannot show a small value is not
/// measuring. Neither of them exaggerates the reading: the figure on the title
/// line is what reports the number, and the meter beside it reports magnitude, so
/// the floor is the smallest mark that still reads as a mark rather than as an
/// empty track.
public enum MeterGeometry {
    /// The shortest fill the bar may draw, as a multiple of the bar's own
    /// thickness.
    ///
    /// Two, because one drew a circle. A round-capped fill exactly as wide as it
    /// is tall is two half-caps meeting in the middle — a dot, which on a track
    /// reads as a bullet or a piece of dirt rather than as a small quantity, and
    /// which is identical at 0.5% and at 1%. At two thicknesses the shortest fill
    /// is a stub with a direction, and it still measures: 10pt of a 278pt track
    /// is under 4%, so nothing that would round to a larger figure is inflated.
    public static let minimumFillThicknesses: CGFloat = 2

    /// The width of the bar's fill inside a track of `track` points.
    ///
    /// Clamped to the track above, because a budget's fraction can exceed 1 and a
    /// fill wider than its track is not a reading. The floor yields to the track
    /// as well — on a track shorter than the floor the fill is the whole track,
    /// which is honest at that size and cannot overhang.
    ///
    /// A zero, negative, NaN or infinite reading draws nothing at all, rather
    /// than the stub a floor applied blindly would leave behind: 0% is a state the
    /// panel states with an empty track, and a NaN is what a percentage over a
    /// zero limit turns into further up.
    public static func fillWidth(percent: Double, track: CGFloat, thickness: CGFloat) -> CGFloat {
        guard percent > 0, percent.isFinite,
              track > 0, track.isFinite,
              thickness > 0, thickness.isFinite
        else { return 0 }
        let measured = track * CGFloat(min(percent, 1))
        return min(track, max(minimumFillThicknesses * thickness, measured))
    }

    /// The share of the dial that one stroke width of arc takes up.
    ///
    /// The dial's arc is trimmed from a circle inset by half the stroke, so the
    /// length it is measured against is `π × (diameter − stroke)` — 53.4pt at the
    /// shipped 22pt dial and 5pt bar, against the bar's 278pt track. One stroke is
    /// 9.4% of it, which is why the dial is the meter where a cap is not a
    /// rounding error but a reading of its own.
    public static func ringCapFraction(diameter: CGFloat, stroke: CGFloat) -> Double {
        guard diameter > 0, diameter.isFinite, stroke > 0, stroke.isFinite else { return 0 }
        let sweep = Double.pi * Double(diameter - stroke)
        guard sweep > 0 else { return 0 }
        return min(1, Double(stroke) / sweep)
    }

    /// How far round the dial the arc is *painted*, floored at the smallest mark
    /// that still reads as a mark.
    ///
    /// Painted, not trimmed, and that is the whole of it. A round cap adds half a
    /// stroke of paint past each end of a trim, so a dial that trimmed to the
    /// reading painted the reading plus a full stroke: at the shipped size 44%
    /// drew as 53% and 12% drew as 21%, every reading over-reported by 9.4 points
    /// while the figure two columns away printed the truth. A meter may not
    /// disagree with the number beside it. `UsageRing` insets the trim by half a
    /// cap at each end, so what this returns is what the eye measures.
    ///
    /// The floor is two strokes, the same floor the bar keeps and for the same
    /// reason: one stroke of painted arc is two half-caps meeting, which is a dot.
    /// It is also exactly the mark the dial drew before — a one-stroke trim
    /// between two caps — so the smallest reading looks as it did and only the
    /// readings above the floor stop being inflated.
    ///
    /// Returns 0 for a reading of zero, and the caller draws no arc: the track
    /// alone says nothing has been used.
    public static func ringTrim(percent: Double, diameter: CGFloat, stroke: CGFloat) -> Double {
        guard percent > 0, percent.isFinite,
              diameter > 0, diameter.isFinite,
              stroke > 0, stroke.isFinite
        else { return 0 }
        let reading = min(percent, 1)
        // A stroke as wide as its dial is a disc, already fully drawn by the
        // track behind it; there is no arc length left to floor.
        let cap = ringCapFraction(diameter: diameter, stroke: stroke)
        guard cap > 0 else { return reading }
        return min(1, max(Double(minimumFillThicknesses) * cap, reading))
    }
}
