import SwiftUI

/// "Figures only" — one number, no mark.
///
/// 23pt at the shipped height, which is the narrowest anything that still reads
/// as a measurement can be. The room the width cap allows is five segments; the
/// ceiling of one is what actually binds, and the reason is already written down
/// in this codebase at `AppearanceSettings.MenuBarStyle.summary`: three bare
/// figures in a row have nothing to say which service each belongs to, which is
/// the fault the per-service marks were added to fix.
///
/// The Minimal preset had already set the count to 1 by hand. The ceiling makes
/// it a property of the style instead of a thing each preset has to remember,
/// and the stored count is left untouched, so switching back restores it.
public enum FigureOnlyStyle: StripStyle {
    public static var kind: AppearanceSettings.MenuBarStyle { .figureOnly }
    public static var segmentCeiling: Int { 1 }
    /// `.figures`, and the name is spoken although it is not drawn. VoiceOver's
    /// job is to say what the item means, not to transcribe its pixels, and a
    /// status item that reads "92%" names nothing.
    public static var sentence: MenuBarStripContent.Sentence { .figures }

    /// The same reserved cell `markAndFigure` uses, minus the mark box and the
    /// gap: 23 at the shipped 13pt height.
    public static func cellWidth(height: CGFloat) -> CGFloat {
        Tokens.Strip.figureCell(height: height)
    }

    @MainActor @ViewBuilder
    public static func cell(_ segment: StripSegment, height: CGFloat, ink: StripInk) -> some View {
        StripFigure(segment: segment, height: height, ink: ink)
    }
}
