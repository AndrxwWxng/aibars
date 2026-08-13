import SwiftUI

/// "Mark + figure" — a brand mark and its own reading, per service.
///
/// The style the strip has drawn since it stopped being four abstract bars, and
/// the only one where the width cap actually bites inside the settings' own
/// ranges: at a 16pt mark a segment is 52pt of pitch and 153 / 52 leaves room
/// for two, so the third service is dropped.
///
/// The mark takes brand ink under `.perBar` because the figure beside it is
/// already carrying the reading. That is the rule `markOnly` inverts, and the
/// two are worth reading together: a strip has one colour channel per segment,
/// and it goes to identity only when something else can spend it on usage.
public enum MarkAndFigureStyle: StripStyle {
    public static var kind: AppearanceSettings.MenuBarStyle { .markAndFigure }
    public static var segmentCeiling: Int { 3 }
    public static var sentence: MenuBarStripContent.Sentence { .figures }

    /// 13 + 3 + 23 = 39 at the shipped 13pt mark, so `w(1) = 39`, `w(2) = 83`,
    /// `w(3) = 127` — three inside the 148pt cap with 21 to spare. At 16 the same
    /// arithmetic is 16 + 3 + 28 = 47 and three would want 151.
    public static func cellWidth(height: CGFloat) -> CGFloat {
        Tokens.Strip.markBox(height: height)
            + Tokens.Strip.markGap
            + Tokens.Strip.figureCell(height: height)
    }

    @MainActor @ViewBuilder
    public static func cell(_ segment: StripSegment, height: CGFloat, ink: StripInk) -> some View {
        HStack(spacing: Tokens.Strip.markGap) {
            StripMark(
                segment: segment,
                height: height,
                // Identity, not the reading: the figure to the right of it is the
                // reading, and a mark tinted amber beside a number tinted amber
                // says one thing twice while saying nothing about which service
                // it is.
                ink: segment.brand.map(ink.brand) ?? ink.neutral
            )
            StripFigure(segment: segment, height: height, ink: ink)
        }
    }
}
