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

// `BrandMark` used to be coloured from here, by five patches around one fact —
// that fifteen unrelated brand colours cannot be a palette. `luminance` measured
// each literal; `foreground(dark:)` and `menuBarInk(dark:)` lifted the near-black
// marks off a dark menu and damped the pale ones; `tile(dark:)`, `tintFloor`,
// `tileTint` and `neutralTile` decided whether a brand could tint its own plate
// and washed it grey when it could not.
//
// All of it is deleted. Nothing in this file reads a brand hex or decides what to
// do about one: the plate is one neutral for every brand, and the glyph is
// whatever single colour the caller hands down. Brand hue survives only in the two
// pre-banded pairs on `BrandMark` — `brandInk` for a meter fill or a percentage
// under `ColorRamp.provider`, `liveInk` for the mark of a service that is actually
// reporting — and `AppearanceSettings.markInk(for:isLive:)` is what picks between
// them and the two neutrals before anything reaches here. Deleted outright rather
// than left forwarding, so a call site that still wants a mark tinted by its own
// raw brand colour fails to build instead of quietly reintroducing the look.

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
    /// at the large one. Never a circle — a mark in a circle is an avatar, and
    /// none of these services is a person.
    static let tileRadius: CGFloat = 0.29

    /// The glyph inside the box when there is a tile, leaving the plate a margin
    /// to be a plate in.
    static let glyphBox: CGFloat = 0.56

    /// The glyph inside the box when there is not — the default, `logoStyle
    /// .plain`.
    ///
    /// It used to be `glyphBox`, on the argument that "plain mark" should remove
    /// the plate and nothing else. That kept the margin a tile needs after
    /// deleting the tile: 36% of the leading column was empty air around a mark
    /// that read visibly weaker than the 13pt name beside it. At the default 18pt
    /// box this draws 13.68pt before optical scaling, and the box — which is what
    /// `RowGeometry` measures — does not move, so no row changes height and no
    /// text changes x.
    static let plainGlyph: CGFloat = 0.76

    /// A lettermark standing in for artwork that does not exist yet, set against
    /// the whole box rather than the glyph inset above: a letter is drawn from
    /// its baseline and its cap height is well under its point size, so at
    /// `glyphBox` it would sit visibly smaller than the vector marks beside it.
    static let letter: CGFloat = 0.42

    /// SF Pro's cap height against its point size, measured: 9.1597pt at 13pt,
    /// and the same at regular, medium, semibold and bold. A letter's point size
    /// says nothing about how tall it draws, so a lettermark sized off the box
    /// directly always lands short.
    static let capHeight: CGFloat = 0.705

    /// The same letter with the plate switched off, sized so its cap height
    /// fills two thirds of the box the vector marks fill — 12.9pt at the default
    /// 18pt box, a 9.1pt cap. Rendered against the set, this is where a letter
    /// stops reading as a caption that wandered into the leading column and
    /// starts carrying the mass of the glyph it stands in for; the tiled ratio
    /// above can afford to be smaller because the plate carries some of it.
    static let plainLetter: CGFloat = plainGlyph * (2.0 / 3.0) / capHeight

    /// The same letter with no tile around it and no inset to respect, where the
    /// frame it is given *is* the glyph box — `ProviderMark`'s case.
    static let soloLetter: CGFloat = 0.8
}

/// A provider's logo, optionally on a neutral plate.
///
/// Prefers a bundled asset named `logo-<providerID>` when one exists, so a
/// brand's official artwork can be dropped in without a code change; falls back
/// to the vector mark, then to a lettermark for unknown providers.
///
/// Every branch draws in one ink, and that is the whole colour policy of this
/// view: identity is a silhouette, and the most a hue is ever allowed to do to it
/// is say which state the service is in. Which ink is the caller's to say,
/// because the caller is the only thing that knows that state. There are three
/// answers and `AppearanceSettings.markInk(for:isLive:)` holds all of them —
/// `Tokens.Ink.muted` at full opacity for a service that is loading, failed,
/// locked, expired, switched off or not connected; `Tokens.Ink.mark` for one that
/// is reporting with its hue suppressed, by the user's switch or by
/// `ColorRamp.provider` having already spent the brand on the meter; and
/// `BrandMark.liveInk`, the brand's own hue at `Ink.mark`'s lightness, for one
/// that is reporting with nothing suppressing it. Three inks and still one
/// decision, made in one place.
///
/// Ink rather than opacity: the old `Dim.disconnected` fade put
/// Gemini's mark at 1.92:1 on a light panel, under the 3:1 a meaningful graphic
/// needs, across an entire first-run window. A list outside the panel that shows
/// a service switched off in Settings still dims — `Tokens.Dim.disabled`, on the
/// finished mark, so a plate fades with the glyph it is behind.
public struct ProviderLogo: View {
    public let providerID: String
    public let fallbackName: String
    public let size: CGFloat
    public let showsTile: Bool
    /// The single colour the mark is drawn in.
    ///
    /// Required, and that is the fix rather than a tidy-up. It used to be
    /// `Color?` defaulting to nil, and nil meant "the reporting ink" — so a
    /// caller that simply forgot the argument was indistinguishable from one
    /// asserting that its subject was live, and four of the five callers had
    /// forgotten. The Settings list, the Budget pane, the connect dialog and the
    /// Appearance sample all drew every mark at the reporting ink; a Claude whose
    /// session had expired was inked identically to a healthy one in the one list
    /// whose job is to say which services need you. There is no default that is
    /// safe here: the caller is the only thing that knows the state, so the caller
    /// has to say, and a missing argument has to be a build failure rather than an
    /// assertion nobody made.
    ///
    /// Resolve it through `AppearanceSettings.markInk(for:isLive:)`, which is
    /// where the three-way answer lives. A caller with no state to report — the
    /// Budget pane's rows — passes `Tokens.Ink.mark` and says why.
    public let ink: Color

    public init(
        providerID: String,
        fallbackName: String,
        size: CGFloat = 30,
        showsTile: Bool = true,
        ink: Color
    ) {
        self.providerID = providerID
        self.fallbackName = fallbackName
        self.size = size
        self.showsTile = showsTile
        self.ink = ink
    }

    // `fallbackColor` was here — the provider's raw brand `Color`, defaulted to
    // `.accentColor` — and it had been read by nothing in this view since the
    // plate became one neutral and the glyph one ink. It survived that pass only
    // because five call sites passed it; this pass edits all five anyway, so the
    // reason to keep it went with them. A brand `Color` sitting on the
    // initialiser of the view that draws the plate is an invitation to re-tint the
    // plate, which is the exact look `BrandMark` was banded to stop.
    //
    // `markInk(isLive:)` was here too, and its own comment said it existed so the
    // row, the Appearance preview and a Settings list would answer the ink
    // question the same way. They did not: only the row ever called it. The
    // decision has moved to `AppearanceSettings.markInk(for:isLive:)`, which can
    // see the two settings inputs this file cannot — the brand-colour switch and
    // the colour ramp — and `ink` above being required is what makes every caller
    // go through it. Deleted rather than forwarded, for the reason stated at the
    // top of this file: a call site that still wants the old two-way answer must
    // fail to build.

    private var mark: BrandMark? { BrandMark.mark(for: providerID) }

    /// The glyph's frame inside the box.
    ///
    /// Two fractions and one per-mark correction. The fractions are the style's;
    /// the correction is the mark's, because ink coverage across the fifteen
    /// glyphs varies 2.7× — OpenCode fills 58% of its box, Gemini 21% — and at
    /// one shared size that reads as fifteen marks drawn at fifteen weights,
    /// which is half of the "row of stickers" the panel used to be. `BrandMark`
    /// carries a scale that lands each glyph on the same optical mass, clamped
    /// so nothing distorts. It multiplies the glyph and never the box, so the
    /// leading column, the row height and `RowGeometry` are all untouched.
    private var glyphSide: CGFloat {
        size * (showsTile ? Ratio.glyphBox : Ratio.plainGlyph) * (mark?.opticalScale ?? 1)
    }

    public var body: some View {
        ZStack {
            if showsTile { tile }
            glyph
                .frame(width: glyphSide, height: glyphSide)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(fallbackName)
    }

    /// The plate: one fill, no stroke.
    ///
    /// `Fill.logoTile` is 7% ink over whatever ground the logo is dropped on: one
    /// plane above it, and the same plane for every brand. The step was recorded
    /// here as 1.165:1 in light and 1.186:1 in dark, and that pair was an artefact
    /// rather than a design — `quiet(_:)` was multiplying by `Color.primary`'s
    /// hidden 0.8471 alpha, which moves the two appearances by different amounts
    /// because L\* is compressive near black. Pure ink at the stated alpha lands
    /// both halves on one step. The corrected figures are not restated here: they
    /// live on `Fill.logoTile` itself, and one measurement quoted in two files is
    /// how the pair above came to be wrong in only one of them.
    ///
    /// What this view is answerable for is the mark on top of the plate rather
    /// than the plate against the panel. On it, `Ink.mark` measures 9.06:1 light
    /// and 10.25:1 dark, against 10.58 and 11.94 on the bare `Surface.base` beside
    /// it; `Ink.muted`, the quietest ink that lands here, measures 5.87 and 6.74.
    /// So the plate costs a mark about a point and a half of contrast and no
    /// legibility, in either appearance and in either state.
    ///
    /// It used to be a tint of the brand's own colour with a hairline around it,
    /// which is two edges on a shape whose whole job is to be a container, and
    /// fifteen different containers down one list.
    private var tile: some View {
        Tokens.surface(size * Ratio.tileRadius)
            .fill(Tokens.quiet(Tokens.Fill.logoTile))
    }

    @ViewBuilder
    private var glyph: some View {
        if let custom = NSImage(named: "logo-\(providerID)") {
            // Inked like every other branch. Dropping in artwork replaces the
            // silhouette, not the rule: one bitmap arriving at full brand
            // saturation is exactly the clash the vector marks just gave up, and
            // as a template it also picks up the caller's disconnected ink
            // instead of staying bright on a row that is saying nothing.
            Image(nsImage: custom)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(ink)
        } else if let mark {
            SVGShape(pathData: mark.pathData, viewBox: mark.viewBox)
                .fill(ink)
        } else {
            // The same ink as a real mark, at the weight a filled glyph reads
            // at: a lettermark is standing in for artwork, so it has to carry
            // the same optical mass as the marks above and below it rather than
            // announce that it is a fallback.
            //
            // SF Pro, at the same weight `ProviderMark` sets its own fallback:
            // the app has two faces, and a rounded display face used for one
            // letter in one state was a third.
            Text(String(fallbackName.prefix(1)).uppercased())
                .font(.system(
                    size: size * (showsTile ? Ratio.letter : Ratio.plainLetter),
                    weight: .semibold
                ))
                .foregroundColor(ink)
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
///
/// Also deliberately no `opticalScale`: here the frame the caller gives *is* the
/// glyph box, and the strip's layout is measured off that box, so a factor above
/// 1 would put Gemini's mark over its neighbour instead of into its own margin.
/// The panel normalises mass inside a box it owns; the strip has no margin to
/// spend.
public struct ProviderMark: View {
    /// The service family, not the account — "claude", never "claude#2" — so
    /// two subscriptions to one service resolve to the one mark with no
    /// unpicking at the call site.
    public let serviceID: String
    public let size: CGFloat
    /// The single colour the mark is drawn in. Resolved by the caller, because
    /// the answer differs per destination: the banded brand colour in a coloured
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
                    .foregroundColor(ink)
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
