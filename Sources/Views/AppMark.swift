import SwiftUI

/// The mark's grid, as arithmetic with no view in it.
///
/// Separate from the drawing for the reason `RowGeometry` is separate from
/// `ProviderRow`: the whole of this mark's crispness is in these numbers, and a
/// number can be asserted without a renderer, a display scale or a menu bar to
/// look at. It is also what the rasteriser needs — `MenuBarStripRenderer` has to
/// build a bitmap of exactly the size the mark will draw at, and it cannot ask a
/// `View` for that without rendering it first and measuring the answer.
///
/// Every measurement here is a whole point and the box is an even number of
/// them. Whole, because the status item resamples a fractional image to fit its
/// slot and half a point of resampling is visible blur on a mark that is mostly
/// 3pt stems. Even, because every slot the app centres this mark in is even —
/// the 22pt status bar (`MenuBarIcon.barHeight`) and the panel header, whose
/// line height is the 22pt icon-button cluster standing on it
/// (`Tokens.Control.iconButton`) — and an odd box centred in an even one has a
/// half-point origin. Measured at the 13pt the strip ships with:
/// (22 − 13) / 2 = 4.5, which at 1× splits the baseline and all four bar tops
/// across two device rows each. At 2× that same 4.5 is 9 whole pixels, which is
/// why a mark that was soft on every external display looked right on the
/// laptop it was drawn on.
public struct AppMarkGeometry: Equatable, Sendable {
    /// Four. Not a parameter: it is the shape the header and the About pane
    /// already stand for, and three bars would be a different mark rather than a
    /// refined one.
    public static let count = 4

    /// The whole, even height the mark draws in. Never larger than the `size`
    /// asked for, above the 8pt floor.
    public let box: CGFloat
    /// One bar's width.
    public let stem: CGFloat
    /// Between two stems.
    public let gap: CGFloat
    /// The axis under the bars.
    public let baseline: CGFloat
    /// Between the feet of the bars and the axis.
    public let baselineGap: CGFloat
    /// The plot, which *is* the tallest bar. Nothing is reserved above the bars.
    public let plot: CGFloat
    /// The constant the descent steps down by.
    public let step: CGFloat
    /// Top corners only, and zero wherever a corner would come out under 2pt.
    public let corner: CGFloat
    /// How far the axis runs past the bars, each side. Zero under 2pt.
    public let overhang: CGFloat
    /// Bar heights, tallest first.
    public let heights: [CGFloat]

    /// Leading edge of the run to trailing edge of the run: 4 stems and the 3
    /// gaps between them.
    public var runWidth: CGFloat {
        CGFloat(Self.count) * stem + CGFloat(Self.count - 1) * gap
    }

    /// The whole mark, axis overhang included.
    public var width: CGFloat { runWidth + 2 * overhang }

    /// What the mark reports to the layout, and what a rasteriser has to size its
    /// canvas to.
    public var drawn: CGSize { CGSize(width: width, height: box) }

    /// The axis is quieter than the bars it carries, and how much quieter depends
    /// on how thick it is. A 1pt rule is one device pixel at 1×, and one pixel at
    /// 55% of a template's alpha is a line the menu bar's own vibrancy finishes
    /// off; a 3pt rule at 70% is a slab competing with the bars it is meant to sit
    /// under. Thin strokes need more alpha to hold the same presence — the same
    /// correction every hairline in the app gets.
    public var baselineOpacity: Double { baseline >= 2 ? 0.55 : 0.70 }

    /// The leading edge of bar `index`, measured from the mark's own leading
    /// edge. Whole by construction, which is the entire point of this type.
    public func stemOrigin(_ index: Int) -> CGFloat {
        overhang + CGFloat(index) * (stem + gap)
    }

    public init(size: CGFloat) {
        // Guarded for the reason `Tokens.Strip.markBox` is guarded: this is public
        // and pure, and the size reaches it from `menuBarGlyphHeight`, which is a
        // `Double` in a defaults domain that can hold anything. A non-finite size
        // survives every `max` below — `max(8, .nan)` is 8, but `max(8, .infinity)`
        // is infinity — and arrives at `NSImage(size:)` as an infinite frame.
        let asked = size.isFinite ? size : 0

        // Down to the even point, and never up: `size` is the room the caller has,
        // and a mark that rounded 13 up to 14 would be a point taller than the slot
        // it was handed. Eight is not a size the app asks for — the smallest is
        // `menuBarGlyphHeight`'s 10 — it is the point below which the plot cannot
        // hold four descending bars at all.
        let box = max(8, (asked / 2).rounded(.down) * 2)
        self.box = box

        // 0.22 of the box: 3pt in the menu bar, 10pt in About. Two is the floor
        // because a 1pt stem is a hairline, and a hairline drawn as a template is
        // one device pixel that the menu bar's vibrancy takes half of.
        let stem = max(2, (box * 0.22).rounded())
        self.stem = stem

        // At most 40% of the stem, and rounded *down* to stay under it. The gap is
        // the mark's negative space and a whole-point grid should spend its
        // rounding on ink: rounded up, the 4pt stem at box 16 takes a 2pt gap —
        // half the stem, the width at which four bars stop reading as one series
        // and start reading as four ticks. One is the floor, and at a 2pt stem it
        // is the floor doing the work, because there is no gap under 40% of 2pt
        // that is still a gap.
        self.gap = max(1, (stem * 0.4).rounded(.down))

        // The axis, and the mark's only horizontal. A third of the stem's weight
        // on purpose — 0.075 of the box against the stem's 0.22 — because a
        // horizontal reads heavier than a vertical of the same weight, which is
        // why a type designer cuts horizontals under stems.
        let baseline = max(1, (box * 0.075).rounded())
        self.baseline = baseline

        // Bars to axis. Its own measurement rather than a share of the gap between
        // bars: it is what makes the axis read as an axis instead of as a fifth bar
        // lying on its side. It is never thinner than the baseline itself, and that
        // is arithmetic rather than a clamp — 0.09 of the box exceeds 0.075 of it
        // and rounding is monotone.
        let baselineGap = max(1, (box * 0.09).rounded())
        self.baselineGap = baselineGap

        // What is left is the plot, and the plot *is* the tallest bar. The old
        // profile topped out at 0.9 of its plot, which left a point of dead air at
        // 13pt and three at 44: the mark drew 12pt of ink inside a 13pt image and
        // hung half a point low in a bar that had already centred it on a half
        // point. Ink height is now the box, exactly, at every size.
        let plot = box - baseline - baselineGap
        self.plot = plot

        // One constant step, so the four tops fall on a single straight line — and
        // that line is what makes four rectangles read as a chart rather than as a
        // comb. The old profile's steps were 3, 3, 2 at 13pt and 9, 9, 7 at 44,
        // which is a descent that gives up before it lands. Rounded down, so
        // `plot % 4` lands in the shortest bar: that is where a whole-point grid
        // should put its slack, because the shortest bar is the one with the least
        // to say.
        let step = max(1, (plot / 4).rounded(.down))
        self.step = step

        // Tallest first, floored at the stem, because a rectangle shorter than it
        // is wide has stopped being a bar. The floor does not fire at any size the
        // app draws: at boxes 10, 14 and 44 the shortest bar lands exactly on the
        // stem and the run ends on a square, and at 12, 16 and 22 it lands above it
        // (4 > 3, 5 > 4, 6 > 5). It is a guard for a caller asking for a size
        // nothing here anticipated, which is also why the tops can be relied on to
        // be collinear everywhere the app actually draws.
        self.heights = (0..<Self.count).map { index in
            max(stem, plot - CGFloat(index) * step)
        }

        // A corner is only drawn once it is 2pt. One point of radius on a 3pt stem
        // is not a corner, it is a half-lit pixel on each shoulder — which is
        // exactly what the old `barWidth * 0.4` did: 1.2pt at a 3pt stem, leaving
        // 3 − 2(1.2) = 0.6pt of flat top edge, a top device row at 79% coverage and
        // corner pixels at 69%. A grey lid on all four bars, and the lid the
        // integral arithmetic was written to prevent. The threshold is on the
        // resolved radius rather than on the size, so it is a measurement and not a
        // size test; in practice it resolves to square everywhere the app draws the
        // mark except About, where the stem is 10pt and the radius is 2 — 6pt of
        // flat top, 60% of the stem, which is also why the rounded top needs no
        // overshoot to hold its line.
        let corner = (stem * 0.2).rounded()
        self.corner = corner >= 2 ? corner : 0

        // An axis runs past the data it carries. Under 2pt it cannot say so — one
        // point at each end is a stray pixel rather than an overhang — so the axis
        // stays flush with the run at every size except About. It is also the
        // mark's answer to a descending run's own imbalance: at box 44 the bar
        // areas are 10 × {37, 28, 19, 10} at centres 5, 19, 33 and 47, which puts
        // the ink centroid 19.30pt from the leading edge against a run centre of
        // 26. Deliberately a counterweight and not a translation: the header aligns
        // this mark's leading edge with every logo in the list below it, so a nudge
        // inside the mark would fix About's problem by breaking the panel's column.
        let overhang = (box * 0.045).rounded()
        self.overhang = overhang >= 2 ? overhang : 0
    }
}

/// One bar: square where it stands, rounded only where a corner is large enough
/// to be one.
///
/// A `Shape` and not `RoundedRectangle` because the bottom corners must stay
/// square at every size — the bars stand on an axis, and a bar with a rounded
/// foot floats off it — and not `UnevenRoundedRectangle` because that is
/// macOS 14 and the floor here is 13, the same reason `MeterFill` is hand-built.
/// The arcs are circular rather than `Tokens.Radius.style`'s continuous curve: at
/// the one size that draws a corner at all the radius is 2pt on a 10pt stem,
/// where the two curves differ by less than a tenth of a point.
struct MarkBar: Shape {
    /// Zero for a square-topped bar, which is every size but About.
    let corner: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        guard rect.width > 0, rect.height > 0 else { return path }

        // Clamped, so a bar can never be handed a radius that eats more than half
        // of it. `AppMarkGeometry` will not produce one, but this shape is also
        // proposed rects by SwiftUI during layout.
        let radius = min(max(corner, 0), min(rect.width, rect.height) / 2)

        // Up the leading edge, across the top, down the trailing edge, and the foot
        // closes it. `addArc(tangent1End:)` degenerates to a line at radius zero,
        // so the square-topped case needs no branch of its own — the same six calls
        // draw both bars.
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(
            tangent1End: CGPoint(x: rect.minX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.minY),
            radius: radius
        )
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(
            tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
            tangent2End: CGPoint(x: rect.maxX, y: rect.maxY),
            radius: radius
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The app's own mark: four bars descending onto an axis.
///
/// It reports nothing, and that is the change. The mark used to be the meter —
/// the bar heights were live usage levels — but the menu bar strip now carries
/// one brand glyph and one figure per service, so a mark that also carried data
/// would be two instruments in the same window answering the same question
/// differently. What is left is identity: the header, the About pane, and the
/// status item's "nothing to report yet" fallback. The file was
/// `UsageMeterGlyph.swift` until this change and had held no type of that name
/// since the reskin; `UsageTint` below is the other thing that lives here, and it
/// stays because the ramp is the meter's colour and this is the one place it is
/// written down.
///
/// It is hinted rather than scaled, and the difference is the point. Every
/// measurement resolves to a whole point through `AppMarkGeometry`, so the mark
/// grows in steps: 15×12 in the menu bar, 15×14 in the header — the same stems at
/// the same pitch, differing only in bar heights, which matters because the panel
/// hangs directly under the status item and the two are on screen together — and
/// 56×44 in About, where it is not the small mark enlarged but the same grid with
/// three things the small one has no room for: rounded tops, an axis that
/// overhangs its bars, and a rule instead of a hairline.
public struct AppMark: View {
    /// The height the caller has room for. The mark takes the largest even whole
    /// point that fits, so ask `AppMarkGeometry` rather than assuming this is what
    /// gets drawn.
    public let size: CGFloat
    /// The mark's colour.
    ///
    /// `Tokens.Ink.body` by default, and the default moved because the token it
    /// used to name is gone. `Tokens.Ink.arc` was the app's own indigo — this
    /// mark in the header, this mark in About, a text link, the sign-in word on a
    /// disconnected row, and the connect dialog's buttons. Indigo is not grey,
    /// amber or red, and the palette now spends chroma on alarm alone, so the
    /// token is deleted rather than re-cut. Arc's job — "this is the app" — is
    /// carried by the silhouette below, which is what a mark is for.
    ///
    /// `body` rather than `mark` because in both of the places this default is
    /// taken — the panel header and the About pane — the drawing *is* the
    /// subject rather than a label beside one, and that is the rung `body` names:
    /// 15.20:1 light and 17.49:1 dark on `Surface.base`, against `mark`'s 10.58
    /// and 11.94. Nothing in this file reaches for a hue any more, which is the
    /// same rule stated from the other side: a mark drawn in a meter's colour
    /// would say "this is how full you are" where it has to say "this is aibars".
    ///
    /// A caller rasterising the mark into a template image passes a flat colour
    /// instead, because a template is drawn from its alpha and AppKit supplies
    /// the rest — so the strip's fallback glyph is not a third call site.
    public let tint: Color

    public init(size: CGFloat, tint: Color = Tokens.Ink.body) {
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        let grid = AppMarkGeometry(size: size)
        return VStack(spacing: grid.baselineGap) {
            HStack(alignment: .bottom, spacing: grid.gap) {
                ForEach(Array(grid.heights.enumerated()), id: \.offset) { _, height in
                    MarkBar(corner: grid.corner)
                        .fill(tint)
                        .frame(width: grid.stem, height: height)
                }
            }
            // The tallest bar is the plot, so this frame never introduces slack and
            // the bottom alignment never has anything to align. It is stated
            // anyway: it is the line that would catch a profile change that
            // reintroduced dead air above the bars.
            .frame(height: grid.plot, alignment: .bottom)

            // Square ends, always. A rule with rounded ends is a pill, and a pill
            // under four bars is the fifth bar lying on its side that the gap above
            // it exists to prevent — the old capsule was working against its own
            // comment.
            Rectangle()
                .fill(tint.opacity(grid.baselineOpacity))
                .frame(width: grid.width, height: grid.baseline)
        }
        // The axis is the widest thing in the stack, so centring the run inside
        // this width is what puts the overhang symmetrically at both ends —
        // (width − runWidth) / 2 is the overhang exactly, and it is whole.
        .frame(width: grid.width, height: grid.box, alignment: .bottom)
    }
}

/// The usage ramp: three stops, shared by every meter, every percentage and the
/// menu bar strip.
///
/// Each stop is a light/dark pair rather than one value, because the ramp is
/// also the text colour of a readout and a single value cannot serve both
/// appearances — measured, the dark stops sit at 1.75:1–2.45:1 on a light panel
/// and the light stops at 1.84:1–2.65:1 on a dark one, all well under the 4.5:1
/// body text needs.
///
/// No pair is written out here any more. All three stops are `Tokens.Ink`
/// tokens, so each pair lives once, in the palette, and the ramp stops being a
/// second file's opinion about a colour the first file also holds. That is the
/// lesson amber taught twice: `0xB45309` and then `0xF5A623` were both "the
/// ramp's amber" written out beside `Ink.attention`, and both times one of the
/// two got re-cut for contrast and the other did not. Every stop clears 4.5:1 on
/// the worst plane in the panel — the pressed row card over the hardest
/// wallpaper — at 4.80/4.81 resting, 4.90/4.53 amber, 6.92/6.34 red.
///
/// The boundaries are settings (`cautionThreshold`, `warningThreshold`); only
/// the palette lives here, so there is one place to read the ramp off. The
/// sampled boundaries below are the shipped defaults of those two settings, and
/// they are what a caller asking for "the caution colour" has to pass — they are
/// not a second, private opinion about where caution starts. Anything drawing a
/// live reading goes through `AppearanceSettings.tint(for:providerAccent:)`,
/// which reads the user's thresholds and the chosen ramp.
///
/// There is deliberately no menu bar variant here. Whether the strip takes a
/// tint at all depends on `menuBarColour`, which is a setting, so that decision
/// belongs to `AppearanceSettings.menuBarTint(for:)` and living in two places is
/// how the strip came to ignore `.monochrome` while the panel honoured it.
public enum UsageTint {
    public static func color(for percent: Double) -> Color {
        switch percent {
        // The resting stop is not a colour at all, and that is the point. It
        // used to be teal, and a panel of nine healthy rows was nine teal bars —
        // colour spent on the least informative state there is. Grey means a
        // healthy row carries no hue, so any hue anywhere in the panel means
        // something wants looking at. It is also strictly better than
        // teal→amber→red for deuteranomaly and protanopia, which collapse hues
        // towards each other but never towards grey.
        //
        // `Ink.muted` itself, not a private grey beside it. It was
        // 0x5F636B / 0x8A8F98, which sat within 3 L* of the token in both
        // appearances — a duplicate rather than a decision, and the dark half of
        // it measured 4.48:1 on the pressed row card, under the text floor. The
        // consequence is worth saying out loud: below caution, `ColorRamp.usage`
        // and `ColorRamp.mono` now resolve identically. They still differ above
        // it, which is the only band where that setting was ever saying anything.
        case ..<0.80: return Tokens.Ink.muted                                  // resting grey
        // One amber, and it is `Ink.attention` itself rather than a second copy
        // of its pair. The light stop used to be 0xB45309, which is a different
        // amber from the one "this needs you" is drawn in — two ambers a user has
        // to learn — and it measured 3.87:1 on a hovered `.always` card, which is
        // the worst ground in the panel and is shipped by three of the five
        // presets. A figure below the 4.5:1 floor is not a reading.
        //
        // Referenced, not repeated. Written out here as 0x8A5A00 / 0xF5A623 it
        // was byte-identical to the token by hand, in a second file, which is the
        // arrangement that produced the two ambers in the first place: one of the
        // two gets re-cut for contrast and the other does not.
        case ..<0.95: return Tokens.Ink.attention                              // amber
        // The same move for red, and for the same reason: it was
        // 0xB92126 / 0xFF6B6E here and nowhere else, so the top of the ramp was
        // the one stop with no owner in the palette. It is `Ink.alarm` now.
        //
        // The new pair is also the fix for a defect the old one had. Amber and
        // red have to be told apart in a greyscale screenshot and by a
        // deuteranope, and 0xB92126 sat 1.8 L* from the light amber and
        // 0xFF6B6E 2.9 L* from the dark one — the same weight in two hues.
        // `Ink.alarm` is always the stop *further* from the ground: L* 26.53
        // against amber's 36.02 in light, 76.65 against 65.73 in dark, so the
        // gaps are 9.49 and 10.92 and "worse than amber" survives the hue going.
        default:      return Tokens.Ink.alarm                                  // red
        }
    }

}
