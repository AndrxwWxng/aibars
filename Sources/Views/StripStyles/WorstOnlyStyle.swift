import SwiftUI

/// "Closest to its cap" — one service, spelled out.
///
/// No mark: the name is the identity, and saying it twice in a 22pt bar is not a
/// use of 16pt. 116pt at the shipped height, 87 at 10 and 143 at 16 — inside the
/// 148pt cap at every height the settings allow, which is what fixed
/// `Tokens.Strip.nameDigits` at twelve.
///
/// This is the one style where the width invariant is threatened by something
/// other than a digit. The *content* of the name rail moves when one service
/// overtakes another — "Claude" is 41.113pt of it, "DeepSeek" 59.636, "GitHub
/// Copilot" 86.829 — and the frame does not. A name longer than its rail
/// truncates with an ellipsis; the rail never grows. The reservation is the same
/// answer it is for the figure.
public enum WorstOnlyStyle: StripStyle {
    public static var kind: AppearanceSettings.MenuBarStyle { .worstOnly }
    /// One, and `max(1, …)` in `StripFit.maxSegments` guarantees the single
    /// segment is never dropped by the width cap either.
    public static var segmentCeiling: Int { 1 }
    /// `.worst`. It names the one service and says it is the one nearest its cap;
    /// it does not say how many were considered, because that is a number the
    /// strip does not draw.
    public static var sentence: MenuBarStripContent.Sentence { .worst }

    /// 90 + 3 + 23 = 116 at the shipped height. Both rails are functions of the
    /// figure's point size and neither is a function of the name in hand.
    public static func cellWidth(height: CGFloat) -> CGFloat {
        Tokens.Strip.nameCell(height: height)
            + Tokens.Strip.markGap
            + Tokens.Strip.figureCell(height: height)
    }

    @MainActor @ViewBuilder
    public static func cell(_ segment: StripSegment, height: CGFloat, ink: StripInk) -> some View {
        HStack(spacing: Tokens.Strip.markGap) {
            Text(segment.displayName)
                // SF Pro, not mono, because it is a word — the rule at
                // `Tokens.Ramp.figureDesign`: a run containing a word is SF Pro,
                // and full mono on a name is the terminal pastiche the direction
                // rules out.
                .font(.system(size: Tokens.Strip.figureSize(height: height), weight: .semibold))
                // Identity is drawn in ink, so the name stays neutral even when
                // the figure beside it is red. The reading is the figure's to
                // carry, exactly as it is under `markAndFigure`.
                .foregroundStyle(ink.neutral)
                .lineLimit(1)
                .truncationMode(.tail)
                // Trailing, and that is the mirror of the figure's leading rather
                // than an inconsistency with it. The rail is 90pt at the shipped
                // height and "Claude" is 41.113 of it, so 49pt of slack has to go
                // somewhere. Leading-aligned it falls *between* the name and its
                // own number and the pair stops reading as a pair — the exact
                // fault `StripFigure` records for the figure cell. Trailing, the
                // slack collects at the item's leading edge, where it is
                // indistinguishable from the gap to the neighbouring status item:
                // "Claude 92" is always adjacent, the item's width never moves,
                // and the only thing that varies is how much air sits in front.
                .frame(width: Tokens.Strip.nameCell(height: height), alignment: .trailing)
            StripFigure(segment: segment, height: height, ink: ink)
        }
    }
}
