import SwiftUI
import AppKit

public extension Color {
    /// 0xRRGGBB literal.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red:   Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >>  8) & 0xFF) / 255,
            blue:  Double( hex        & 0xFF) / 255,
            opacity: opacity
        )
    }
}

public extension BrandMark {
    /// WCAG relative luminance, used to keep near-black marks (OpenAI,
    /// Cursor, Copilot) visible against a dark menu.
    ///
    /// The formula lives in `Tokens`, not here. The app now weighs three
    /// different colours by luminance — a brand mark, the text on an
    /// accent-filled chip, and a meter's own tint — and three copies of the
    /// same channel maths is three chances for the marks and the chips to
    /// disagree about what "too dark to read" means. The colour is built in
    /// sRGB from the literal rather than round-tripped through `Color`,
    /// because `NSColor(_: Color)` does not promise a component space and the
    /// WCAG coefficients assume one.
    var luminance: Double {
        Tokens.relativeLuminance(NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green:   CGFloat((hex >>  8) & 0xFF) / 255,
            blue:    CGFloat( hex        & 0xFF) / 255,
            alpha:   1
        ))
    }

    /// The colour to draw the glyph in for a given appearance.
    ///
    /// A provider's brand colour appears in its own mark — this glyph and the
    /// tile it sits on — and nowhere else in the panel body. Not the meter, not
    /// the figure, not the row's background, not a chip, unless the user picks
    /// `ColorRamp.provider`, which is them asking for it. That was given up
    /// deliberately and it costs something real: you cannot scan the list by
    /// brand colour. What it buys is that colour in the panel never means "this
    /// is Anthropic", so colour arriving anywhere means "this one needs you".
    func foreground(dark: Bool) -> Color {
        if dark && luminance < 0.22 { return Color(hex: 0xF2F2F2) }
        if !dark && luminance > 0.78 { return Color(hex: hex).opacity(0.85) }
        return Color(hex: hex)
    }

    /// The colour to draw the glyph in on the menu bar itself, when the strip
    /// is drawn in colour rather than as a template.
    ///
    /// Same two bands as `foreground(dark:)`, because the legibility problem is
    /// the same one: the four essentially black marks (Grok, OpenAI, Copilot,
    /// Cursor, all under 0.011) disappear on a dark bar. The bands are not
    /// widened for the strip's smaller glyph — the next mark up is Mistral's
    /// saturated orange at 0.26, which reads perfectly well on a dark bar, so a
    /// wider band would catch nothing and cost identity.
    ///
    /// What differs is the fix on the pale side. A panel row sits on an opaque
    /// known surface, so a too-pale mark can be damped to 0.85 there and still
    /// read. The menu bar is translucent with the user's desktop behind it, so
    /// any alpha under 1 shows the wallpaper through the glyph; the mark is
    /// substituted outright instead. Nothing currently ships above 0.78 — this
    /// is the branch that keeps a future near-white brand from arriving as a
    /// bug report.
    func menuBarInk(dark: Bool) -> Color {
        if dark && luminance < 0.22 { return Color(hex: 0xF2F2F2) }
        if !dark && luminance > 0.78 { return Color(hex: 0x1A1A1A) }
        return Color(hex: hex)
    }

    /// The colour of the rounded tile behind the glyph. Brands that are
    /// essentially black would tint to nothing, so those fall back to a
    /// neutral wash.
    func tile(dark: Bool) -> Color {
        guard luminance >= Self.tintFloor else { return Self.neutralTile(dark: dark) }
        return Color(hex: hex, opacity: dark ? Self.tileTint.dark : Self.tileTint.light)
    }

    /// The tile behind a glyph this file has no vector for, tinted with the
    /// colour the provider itself supplies.
    ///
    /// Same two answers as `tile(dark:)`, at the same two weights, so a service
    /// that arrives before its artwork does gets a plate of the same strength as
    /// the marks either side of it: a fallback drawn at an opacity of its own is
    /// how one row in a panel of eleven comes to look like a different app.
    ///
    /// The luminance is measured off the `Color`, because a caller with no mark
    /// has no hex to measure. `relativeLuminance` converts to sRGB itself, and
    /// answers 0 for a colour it cannot convert at all — which lands on the
    /// neutral wash, the safe way round for a tint nothing can measure.
    static func tile(accent: Color, dark: Bool) -> Color {
        guard Tokens.relativeLuminance(NSColor(accent)) >= tintFloor else {
            return neutralTile(dark: dark)
        }
        return accent.opacity(dark ? tileTint.dark : tileTint.light)
    }

    /// A tint of the brand's own colour, as an opacity on it. Dark carries more
    /// because the same alpha over graphite lands closer to the ground than it
    /// does over paper.
    private static let tileTint: (light: Double, dark: Double) = (0.15, 0.22)

    /// The plate for a mark whose colour cannot tint anything: `Color.primary`
    /// opacities, so it stays a plane above whatever ground it is dropped on.
    private static func neutralTile(dark: Bool) -> Color {
        Tokens.quiet(dark ? 0.10 : 0.07)
    }

    /// Below this luminance a tint of the brand's colour is indistinguishable
    /// from no tile at all — seven of the entries in `BrandMark.all` fall under
    /// it and six of those under 0.011 — so they take the neutral wash instead.
    /// Deliberately well below the 0.22 the ink bands use: this asks "can this
    /// colour tint a plate", and Z.ai's near-black blue at 0.026 cannot while
    /// still needing its glyph lifted off a dark menu.
    private static let tintFloor: Double = 0.06
}

/// The fractions a logo is laid out by, and the one stated exception to the
/// token rule in this file.
///
/// Everything else in the app measures itself against `Tokens.Space` and
/// `Tokens.Radius`, because the panel has one rhythm and a view that invents its
/// own spacing stops lining up with its neighbours. A logo is not in that
/// rhythm. Its box is whatever the caller sets — 18pt on a dense row, 26pt in
/// Settings, 34pt in the connect dialog, 40pt at the top of the slider's range —
/// and its tile radius, its glyph inset and the size of a lettermark are all
/// functions of that box rather than of the window it sits in. A radius pinned
/// to `Radius.chip` would be nearly a squircle at 18pt and a barely rounded
/// plate at 40. So these stay ratios, and they are named here rather than left
/// loose in the body so there is one place to read what a logo's proportions
/// are.
private enum Ratio {
    /// The tile's corner against its side. Just over 2/7: enough that the plate
    /// reads as an icon tile at the small end without rounding towards a circle
    /// at the large one.
    static let tileRadius: CGFloat = 0.29

    /// The glyph inside the box, leaving the tile a margin to be a tile in.
    ///
    /// Unchanged when the tile is switched off. "Plain mark" removes the plate
    /// and nothing else: a mark that also grew would make one setting do two
    /// things, and it would change the optical weight of every row in the panel
    /// while the layout stayed put, since `RowGeometry` measures the box and not
    /// what is drawn in it.
    static let glyphBox: CGFloat = 0.56

    /// A lettermark standing in for artwork that does not exist yet, set against
    /// the whole box rather than the glyph inset above: a letter is drawn from
    /// its baseline and its cap height is well under its point size, so at
    /// `glyphBox` it would sit visibly smaller than the vector marks beside it.
    static let letter: CGFloat = 0.42

    /// The same letter with no tile around it and no inset to respect, where the
    /// frame it is given *is* the glyph box — `ProviderMark`'s case.
    static let soloLetter: CGFloat = 0.8
}

/// A provider's logo in a rounded tile.
///
/// Prefers a bundled asset named `logo-<providerID>` when one exists, so a
/// brand's official artwork can be dropped in without a code change; falls
/// back to the vector mark, then to a lettermark for unknown providers.
///
/// What state the subject is in is the caller's to say and not this view's: a
/// service switched off in Settings draws at `Tokens.Dim.disabled`, one that is
/// merely not connected at `Tokens.Dim.disconnected`. Two values because they
/// are two different statements about the subject, and opacities on the finished
/// mark so that a tile dims with the glyph it is behind.
public struct ProviderLogo: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    public let providerID: String
    public let fallbackName: String
    public let fallbackColor: Color
    public let size: CGFloat
    public let showsTile: Bool

    public init(
        providerID: String,
        fallbackName: String,
        fallbackColor: Color = .accentColor,
        size: CGFloat = 30,
        showsTile: Bool = true
    ) {
        self.providerID = providerID
        self.fallbackName = fallbackName
        self.fallbackColor = fallbackColor
        self.size = size
        self.showsTile = showsTile
    }

    private var mark: BrandMark? { BrandMark.mark(for: providerID) }
    private var isDark: Bool { colorScheme == .dark }

    public var body: some View {
        ZStack {
            if showsTile { tile }
            glyph
                .frame(width: size * Ratio.glyphBox, height: size * Ratio.glyphBox)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(fallbackName)
    }

    /// The tinted plate. One ground and one stroke, like every other edge in the
    /// app — no shadow and no inner highlight — and the stroke reads its weight
    /// through `borderOpacity(increased:)` rather than off a pair of literals,
    /// because a tinted tile at 15% on a similar ground is exactly the edge an
    /// increased-contrast display needs stepped up.
    private var tile: some View {
        let shape = Tokens.surface(size * Ratio.tileRadius)
        return shape
            .fill(mark?.tile(dark: isDark) ?? BrandMark.tile(accent: fallbackColor, dark: isDark))
            .overlay(
                shape.strokeBorder(
                    Tokens.quiet(Tokens.borderOpacity(increased: contrast == .increased)),
                    lineWidth: Tokens.Control.hairline
                )
            )
    }

    @ViewBuilder
    private var glyph: some View {
        if let custom = NSImage(named: "logo-\(providerID)") {
            Image(nsImage: custom)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else if let mark {
            SVGShape(pathData: mark.pathData, viewBox: mark.viewBox)
                .fill(mark.foreground(dark: isDark))
        } else {
            // The lettermark draws in the foreground colour rather than the
            // provider's accent: an accent dark enough to look right on a light
            // tile disappears on a dark one, and there's no vector here whose
            // luminance we could reason about. Damped off `.primary` so a letter
            // does not out-shout the real marks above and below it — it is
            // standing in for artwork, not announcing itself.
            //
            // SF Pro, at the same weight `ProviderMark` sets its own fallback:
            // the app has two faces, and a rounded display face used for one
            // letter in one state was a third.
            Text(String(fallbackName.prefix(1)).uppercased())
                .font(.system(size: size * Ratio.letter, weight: .semibold))
                .foregroundStyle(.primary.opacity(0.8))
        }
    }
}

/// A provider's mark on its own: no tile, no environment, one resolved ink.
///
/// The menu bar strip cannot use `ProviderLogo`, for three separate reasons
/// that all want the same answer. It is one menu bar tall, so there is no room
/// for a tile and no room for the inset the tile implies. It is rasterised
/// through `ImageRenderer`, which draws in the light appearance whatever the
/// menu bar is actually doing, so a view reading `@Environment(\.colorScheme)`
/// would resolve against the wrong one. And the image it becomes is usually a
/// template, whose colours collapse to alpha for AppKit to recolour with the
/// menu bar's own vibrancy — so there is exactly one useful colour to draw in,
/// and the caller is the only thing that knows what it is.
///
/// Deliberately no `logo-<serviceID>` asset override, unlike `ProviderLogo`: a
/// bundled bitmap cannot be filled with `ink`, and in a template it would
/// contribute its own alpha instead of the shape's. The override belongs to the
/// tiled logo, where the artwork is drawn as published.
public struct ProviderMark: View {
    /// The service family, not the account — "claude", never "claude#2" — so
    /// two subscriptions to one service resolve to the one mark with no
    /// unpicking at the call site.
    public let serviceID: String
    public let size: CGFloat
    /// The single colour the mark is drawn in. Resolved by the caller, because
    /// the answer differs per destination: the brand's own colour in a coloured
    /// strip, the menu bar's neutral in a monochrome one, black in a template.
    public let ink: Color

    public init(serviceID: String, size: CGFloat, ink: Color) {
        self.serviceID = serviceID
        self.size = size
        self.ink = ink
    }

    public var body: some View {
        Group {
            if let mark = BrandMark.mark(for: serviceID) {
                SVGShape(pathData: mark.pathData, viewBox: mark.viewBox)
                    .fill(ink)
            } else {
                // A service with no vector still has to occupy its slot: a mark
                // that draws nothing reads as a service that is missing rather
                // than one that is unillustrated. The initial comes from the id
                // because the id is all this view is given, and the ids are the
                // service names.
                Text(initial)
                    .font(.system(size: size * Ratio.soloLetter, weight: .semibold))
                    .foregroundStyle(ink)
            }
        }
        .frame(width: size, height: size)
        // Decorative in both branches, and uniformly so. A `Shape` is not an
        // accessibility element but a `Text` is, so without this the fallback
        // would announce a stray letter that the vector marks never announce.
        // What the strip says out loud is one sentence on the finished image.
        .accessibilityHidden(true)
    }

    private var initial: String {
        let letter = serviceID.prefix(1).uppercased()
        return letter.isEmpty ? "?" : letter
    }
}
