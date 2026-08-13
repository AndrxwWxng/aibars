import SwiftUI

/// "Marks only" — silhouettes, tinted by how close each service is to its cap.
///
/// 13pt a service and 49pt for three, which is a third of what `markAndFigure`
/// costs. The pitch is 18 and the width cap allows eight, so the cap never binds
/// at any height the settings can produce; `MenuBarStripContent.range` caps it at
/// three first.
///
/// **The one rule this style changes.** Everywhere else the mark takes brand ink
/// under `.perBar`, because a figure or a column beside it is carrying the
/// reading. Here there is nothing else, so the mark is the only thing that can
/// carry it and brand ink would spend the strip's one channel on identity twice.
/// Under this style the mark therefore takes the usage band, resolved exactly as
/// a figure's is — `StripInk.band`, which is that decision's single home.
///
/// A `nil` percent is neutral in every colour mode: a status-only service has no
/// band and must not be given one.
public enum MarkOnlyStyle: StripStyle {
    public static var kind: AppearanceSettings.MenuBarStyle { .markOnly }
    public static var segmentCeiling: Int { 3 }
    /// `.bands`, and the band word is why. The tint *is* the reading here, and a
    /// tint is invisible to VoiceOver — so the sentence says "near limit" where
    /// the drawing says amber. The three words are the panel's own, from
    /// `AppearanceSettings.grouped(_:snapshots:)`, so the strip and the list under
    /// it say the same thing.
    public static var sentence: MenuBarStripContent.Sentence { .bands }

    /// The mark's box and nothing else: 13 at the shipped height.
    ///
    /// `SVGShape` fills whatever rect it is given, so path geometry cannot escape
    /// the box and a wide logo and a narrow one take the same column. No reading
    /// is drawn at all, so there is nothing here that could change width.
    public static func cellWidth(height: CGFloat) -> CGFloat {
        Tokens.Strip.markBox(height: height)
    }

    @MainActor @ViewBuilder
    public static func cell(_ segment: StripSegment, height: CGFloat, ink: StripInk) -> some View {
        StripMark(segment: segment, height: height, ink: ink.band(segment.percent))
    }
}
