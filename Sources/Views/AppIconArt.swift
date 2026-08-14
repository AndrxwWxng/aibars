import SwiftUI

/// The application's icon: the app mark, in white, on a graphite tile.
///
/// This is the artifact the app did not have. `AppMark` is the *menu bar* mark —
/// a template glyph 12 to 14 points tall, hinted onto a whole-point grid, drawn
/// in whatever ink the surface under it calls for — and it was doing duty for a
/// logo in the header and the About pane. An app icon is a different thing with
/// different rules: it is 1024 points square, it is never a template, it is
/// composited over the Finder's own background rather than over the panel's, and
/// it is the one drawing of this app most users see first and most often. With
/// no `AppIcon` set in the bundle, macOS drew the generic blank application tile
/// in Finder, in System Settings → Login Items — which for a menu bar app is the
/// one place it *must* be identifiable, because it is where a user goes to
/// remove it — and on every notification banner.
///
/// **It is the same mark and not a second one.** The bar profile, the descent,
/// the axis and its overhang all come from `AppMarkGeometry`, read at a
/// thousand-point reference box and scaled, so a change to the mark's
/// proportions reaches the icon without anyone remembering to redraw it. What is
/// *not* shared is the hinting: `AppMarkGeometry` rounds every measurement to a
/// whole point because at 13pt a half-lit pixel is a visible softness, and at
/// icon sizes that same rounding would quantise the mark to 1/374th of the tile
/// for no benefit at all. So the ratios are shared and the rounding is not,
/// which is the only honest way to use one grid at two orders of magnitude.
///
/// **Rendered once at 1024 and downsampled**, rather than drawn per size. The
/// mark is wider than it is tall (1.23:1) and `AppMarkGeometry` floors its box
/// at 8pt, so at a 16pt canvas the hinted grid would demand a mark wider than
/// the tile it stands on. Downsampling a master is also what makes the ten
/// images in the set unmistakably one icon.
public struct AppIconArt: View {
    /// The side of the square canvas. The tile inside it is smaller — see
    /// `tileFraction`.
    public let side: CGFloat

    public init(side: CGFloat = 1024) {
        self.side = side
    }

    /// The rounded tile inside the canvas, as a fraction of it: 824 of 1024,
    /// which is the macOS grid every system icon is cut on. The margin is not
    /// padding — it is the room the shadow the system draws under the tile needs,
    /// and an icon that fills its canvas sits visibly larger than its neighbours
    /// in a Dock or a Finder column.
    public static let tileFraction: CGFloat = 824.0 / 1024.0

    /// The tile's corner, as a fraction of the tile: 185.4 of 824. Continuous
    /// rather than circular, which at this radius is the difference between the
    /// system's silhouette and a rounded rectangle that reads as almost-right.
    public static let cornerFraction: CGFloat = 185.4 / 824.0

    /// The mark's box, as a fraction of the tile. Set by width rather than by
    /// height — the mark is 1.23 times wider than it is tall, so it is the width
    /// that decides whether it looks crowded — and 0.455 puts the run at 56% of
    /// the tile, which is where the four bars stop reading as a pattern filling a
    /// square and start reading as a mark standing in one.
    public static let markFraction: CGFloat = 0.455

    /// The reference box the proportions are read at. A thousand rather than the
    /// tile's own size so that the shared grid is sampled once, at a size where
    /// its whole-point rounding is under a tenth of a percent, instead of being
    /// re-rounded at every canvas.
    private static let reference: CGFloat = 1000

    public var body: some View {
        let tile = side * Self.tileFraction
        let grid = AppMarkGeometry(size: Self.reference)
        let scale = (tile * Self.markFraction) / Self.reference

        ZStack {
            RoundedRectangle(cornerRadius: tile * Self.cornerFraction, style: .continuous)
                .fill(
                    LinearGradient(
                        // The panel's own ground at the foot, one step of the
                        // grey ladder above it at the head. A gradient and not a
                        // flat fill because a flat near-black tile at 1024 reads
                        // as a hole rather than as an object; two stops 15 L*
                        // apart is the least that gives it a top and a bottom.
                        colors: [Color(hex: 0x272A32), Color(hex: 0x0C0D11)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay(
                    // The lit edge. Every physical object in a UI has one, and
                    // without it the tile's own corner is the only thing
                    // separating it from a dark wallpaper. Drawn inside the
                    // silhouette so it cannot widen it.
                    RoundedRectangle(cornerRadius: tile * Self.cornerFraction, style: .continuous)
                        .inset(by: side * 0.0015)
                        .strokeBorder(
                            LinearGradient(
                                colors: [Color.white.opacity(0.16), Color.white.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            ),
                            lineWidth: side * 0.003
                        )
                )
                .frame(width: tile, height: tile)

            mark(grid, scale: scale)
        }
        .frame(width: side, height: side)
    }

    /// The mark itself, at the same proportions `AppMark` draws and none of its
    /// rounding.
    ///
    /// Built out of `Path` rather than out of `AppMark`, because `AppMark` asks
    /// `AppMarkGeometry` for a hinted grid at whatever size it is handed and
    /// there is no way to hand it the scaled ratios instead. The shapes are the
    /// same shapes: square-footed bars with rounded tops, on an axis that
    /// overhangs them and carries the same weight `baselineOpacity` gives it
    /// everywhere else.
    private func mark(_ grid: AppMarkGeometry, scale: CGFloat) -> some View {
        let stem = grid.stem * scale
        let gap = grid.gap * scale
        let corner = grid.corner * scale
        let baseline = grid.baseline * scale
        let baselineGap = grid.baselineGap * scale
        let width = grid.width * scale
        let box = grid.box * scale
        let ink = Color(hex: 0xF6F7FA)

        return ZStack(alignment: .bottomLeading) {
            ForEach(Array(grid.heights.enumerated()), id: \.offset) { index, height in
                MarkBar(corner: corner)
                    .fill(ink)
                    .frame(width: stem, height: height * scale)
                    .offset(x: grid.stemOrigin(index) * scale, y: -(baseline + baselineGap))
            }

            Rectangle()
                .fill(ink.opacity(grid.baselineOpacity))
                .frame(width: width, height: baseline)
        }
        .frame(width: width, height: box, alignment: .bottomLeading)
    }
}
