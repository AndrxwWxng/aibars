import SwiftUI

/// "Micro bars" — one column per service, standing on a shared baseline.
///
/// This is `AppMark`'s own drawing with its levels given back. The app's mark
/// *is* four bars on a baseline; it used to carry live usage and stopped, and
/// this is that drawing with one column per *named* service in the panel's own
/// urgency order.
///
/// It is the one style that keeps a reading under `.monochrome`, because a bar
/// height survives being flattened to alpha. Its cost is stated as plainly in the
/// Appearance pane as it is here: five identical 5pt columns say how full, and
/// nothing at all says which.
///
/// The cell is the mark's box, so this and `markOnly` measure identically at
/// every height and switching between them moves no neighbouring status item. An
/// earlier draft gave the run a tighter gap; it would have made the two disagree
/// by 4pt at three services for no reason a user could see.
public enum MicroBarsStyle: StripStyle {
    public static var kind: AppearanceSettings.MenuBarStyle { .microBars }
    public static var segmentCeiling: Int { 3 }
    /// `.bands`, as `markOnly`, and the name matters more here than anywhere: the
    /// drawing contains no identity at all.
    public static var sentence: MenuBarStripContent.Sentence { .bands }

    /// The mark's box, identical to `markOnly` by construction: 13 at the shipped
    /// height, 49 for three. The reading changes `fillHeight`, which is a
    /// *vertical* quantity inside a fixed channel — no horizontal quantity in this
    /// style reads a percent, so 0 and 100 both measure 13pt a segment.
    public static func cellWidth(height: CGFloat) -> CGFloat {
        Tokens.Strip.markBox(height: height)
    }

    /// The rule the columns stand on, spanning the whole run.
    ///
    /// It is the baseline that binds n columns into one chart rather than n
    /// unrelated bars — which is the whole reason this style has an underlay and
    /// the other five do not. `B` is 1pt at every height the settings allow, so
    /// the corner radius of `B / 2` is a half point of curvature on a 1pt rule:
    /// invisible, and correct at 3pt if `AppMark`'s proportions are ever re-cut.
    @MainActor @ViewBuilder
    public static func underlay(width: CGFloat, height: CGFloat, ink: StripInk) -> some View {
        let plot = Tokens.Strip.meterPlot(height: height)
        RoundedRectangle(cornerRadius: plot.baseline / 2, style: Tokens.Radius.style)
            .fill(ink.baseline)
            .frame(width: width, height: plot.baseline)
            // Bottom-aligned in the run's own box rather than left to the
            // `.background` to centre: the baseline is the floor of the chart, and
            // the columns above it are placed from the same box.
            .frame(width: width, height: Tokens.Strip.markBox(height: height), alignment: .bottom)
    }

    @MainActor @ViewBuilder
    public static func cell(_ segment: StripSegment, height: CGFloat, ink: StripInk) -> some View {
        let box = Tokens.Strip.markBox(height: height)
        let plot = Tokens.Strip.meterPlot(height: height)
        StripColumn(percent: segment.percent, height: height, plot: plot.plot, ink: ink)
            // `baseline + gap + plot == box` exactly — all three are whole and the
            // plot is what is left after the other two — so bottom-padding the
            // column by the first two lands its floor on the gap above the rule
            // and its top on the box's own top edge.
            .padding(.bottom, plot.baseline + plot.gap)
            .frame(width: box, height: box, alignment: .bottom)
    }
}
