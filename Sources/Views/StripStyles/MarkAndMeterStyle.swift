import SwiftUI

/// "Mark + meter" — a brand mark and a small column beside it.
///
/// The middle of the range, and it earns its slot by being the only compact
/// style that says both things. `microBars` has exactly the fault the
/// per-service marks were introduced to fix — a meter with no identity is
/// decoration — and `markAndFigure` is 39pt a service. This is 21: identity and a
/// magnitude, 73pt for three against 127. It is the style for someone with a
/// notch and three subscriptions.
///
/// The mark takes brand ink, as in `markAndFigure` and for the same reason: the
/// column beside it is carrying the reading, so the mark is free to carry
/// identity.
public enum MarkAndMeterStyle: StripStyle {
    public static var kind: AppearanceSettings.MenuBarStyle { .markAndMeter }
    public static var segmentCeiling: Int { 3 }
    /// `.bands`. The column's height is the reading and a height is no more
    /// audible than a tint.
    public static var sentence: MenuBarStripContent.Sentence { .bands }

    /// 13 + 3 + 5 = 21 at the shipped height. Pitch 26, room 5 at every height the
    /// settings allow, so `MenuBarStripContent.range` caps it at three first and
    /// the width cap never binds.
    public static func cellWidth(height: CGFloat) -> CGFloat {
        Tokens.Strip.markBox(height: height)
            + Tokens.Strip.markGap
            + Tokens.Strip.meterColumn(height: height)
    }

    @MainActor @ViewBuilder
    public static func cell(_ segment: StripSegment, height: CGFloat, ink: StripInk) -> some View {
        let box = Tokens.Strip.markBox(height: height)
        HStack(spacing: Tokens.Strip.markGap) {
            StripMark(
                segment: segment,
                height: height,
                ink: segment.brand.map(ink.brand) ?? ink.neutral
            )
            // No baseline, and vertically centred rather than sitting on one. A
            // baseline binds a *run* of columns into a chart, which is what
            // `microBars` wants and what this must not have: here each column
            // belongs to the mark on its left, and a rule spanning the run would
            // bind them all back into one reading.
            //
            // `barePlot` is the box less two, so the centring is 1pt of air above
            // and below at every height — whole on both sides, which a channel
            // sized to the full box could not be.
            StripColumn(
                percent: segment.percent,
                height: height,
                plot: Tokens.Strip.barePlot(height: height),
                ink: ink
            )
            .frame(height: box)
        }
    }
}
