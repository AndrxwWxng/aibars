import Foundation
import CoreGraphics
import SwiftUI

/// Vector artwork for each provider's brand mark.
///
/// Except where noted at the entry, the path data is the single-path glyph
/// published by simple-icons (the icon set is CC0-1.0). The logos themselves
/// remain trademarks of their respective owners and appear here only to
/// identify the service each row reports usage for.
///
/// A mark is inked by its host, not by this file: the set publishes a single
/// path with no `fill`, and every entry here carries geometry, a raw brand hex
/// as data, and an optical scale. What the file supplies instead of a colour is
/// two *bands*, each a rule for turning a raw brand hex into something legal on
/// this app's grounds — `brandInk` for a mark's colour used as a figure or a
/// meter fill, `liveInk` for the mark itself. Both hold one lightness and spend
/// the brand on hue alone, because chroma in this app means measurement or
/// state and identity is carried by the silhouette.
///
/// The other thing normalised per mark is optical mass (`opticalScale`, below),
/// which is the other half of the "row of stickers" problem — coverage varies
/// 2.7× across the set.
///
/// A mark can be replaced without touching this file: drop an image named
/// `logo-<providerID>` into an asset catalog and `ProviderLogo` prefers it.
public struct BrandMark {
    public let providerID: String
    public let title: String
    /// Coordinate space the path data is authored in.
    public let viewBox: CGSize
    /// SVG path data, non-zero winding.
    public let pathData: String
    /// The brand's primary colour, 0xRRGGBB.
    ///
    /// Data, not an instruction: nothing draws this literal. It is the hue the
    /// banded pair in `brandInk(dark:)` is derived from, and it is kept so the
    /// derivation stays checkable.
    public let hex: UInt32

    /// How much to grow or shrink this glyph inside its box so it carries the
    /// same optical weight as its neighbours.
    ///
    /// Multiplies the glyph frame only — the box (`logoSize`) never changes, so
    /// no row moves and `RowGeometry` never sees it. The numbers are
    /// `sqrt(0.34 / coverage)`, clamped to 0.80…1.10, where coverage is the
    /// share of the glyph box each path actually inks (rasterised at 256×256)
    /// and 0.34 is the set's middle. Without it OpenCode's solid square reads
    /// 2.7× heavier than Gemini's star at the same 18pt, which is a list of
    /// logos rather than one designed column.
    public let opticalScale: CGFloat

    public init(
        providerID: String,
        title: String,
        viewBox: CGSize,
        pathData: String,
        hex: UInt32,
        opticalScale: CGFloat = 1
    ) {
        self.providerID = providerID
        self.title = title
        self.viewBox = viewBox
        self.pathData = pathData
        self.hex = hex
        self.opticalScale = opticalScale
    }

    public static func mark(for providerID: String) -> BrandMark? {
        all.first { $0.providerID == providerID }
    }

    // MARK: - The one place brand hue still surfaces

    /// The brand's colour, banded to be legible as text.
    ///
    /// Two surfaces ask for brand hue and only two: the menu bar strip under
    /// `menuBarColour == .perBar`, and meters and figures under
    /// `ColorRamp.provider`. Both are the user asking for it. Neither can take
    /// the raw literal: `hex` is authored for a logo on white, so Copilot's
    /// near-black drew a meter at 1.09:1 on a dark panel and Claude's orange set
    /// a percentage at 2.91:1 on a light one.
    ///
    /// So hue is kept and lightness and chroma are not: OKLCh L 0.455 / C ≤ 0.08
    /// light, L 0.80 / C ≤ 0.07 dark. Every entry clears 4.60:1 on the worst
    /// plane in the panel in both appearances, which makes it legal as a *figure*
    /// and not merely as a bar, and 4.80:1 against `Meter.track`. The cost is
    /// that Claude, Mistral and MiniMax come out near-identical — three warm
    /// browns one band apart. That is what banding a brand palette to one
    /// luminance does, and it is the right trade here, because the thing telling
    /// those rows apart is the glyph.
    ///
    /// The light half was L 0.48, and it moved because the ground under it did.
    /// "The worst ground in the panel" used to mean a hovered `.always` card at
    /// `#E1E2E4`; it now means the *pressed* card over the wallpaper that pushes
    /// hardest, `#D0D1D3` light and `#36373A` dark, which is a step lighter and a
    /// step darker respectively. Measured there, the shipped light half ran
    /// 3.91–3.93:1 — under the 4.5:1 this doc claims — so it is re-cut rather
    /// than re-described. 4.5:1 on `#D0D1D3` bounds a light figure at L\* ≤ 38.32
    /// and 4.6:1 at L\* ≤ 37.73; at OKLCh L 0.455 the band's loudest entry is
    /// Perplexity's cyan at L\* 37.63, so the 4.60 above is the measurement and
    /// not a rounding of 4.5. Light now runs L\* 35.66–37.63, 4.62–4.97 on the
    /// worst plane, 6.59–7.09 on `Surface.base`.
    ///
    /// The dark half did not move: L\* 75.80–77.74 measures 6.18–6.55 on
    /// `#36373A` and 10.09–10.69 on `Surface.base`, so it clears the new floor
    /// with the values it already had.
    ///
    /// Resolved rather than dynamic because the strip is rasterised through
    /// `ImageRenderer`, which draws in the light appearance whatever the menu
    /// bar is doing; the panel side takes `brandInk` instead.
    public func brandInk(dark: Bool) -> Color {
        let band = Self.band(providerID)
        return Color(hex: dark ? band.dark : band.light)
    }

    /// The same banded colour as a dynamic value, for a call site with no
    /// appearance to hand — `AnyUsageProvider.accentColor`, which is captured
    /// once and drawn in whichever appearance the panel is open in.
    public var brandInk: Color {
        let band = Self.band(providerID)
        return Tokens.dynamic(light: band.light, dark: band.dark)
    }

    /// The banded pair, keyed by provider.
    ///
    /// Grouped the way the brands are: Claude and Claude Code are one company
    /// and one colour, and the seven near-black marks (OpenAI's two, Cursor,
    /// Copilot, Grok, OpenCode, Z.ai) have no hue left to keep once they are
    /// lifted to a readable lightness, so they land on the neutral with
    /// everything else that has no band of its own.
    ///
    /// Copilot is in that list and used to have a `case` of its own returning
    /// `(0x656363, 0xBFBDBD)` — OKLab ΔE **0.0031** light and **0.0027** dark
    /// from `neutralBand`, one 8-bit step per channel, and about a thirtieth of
    /// the smallest difference an eye resolves. The case is deleted rather than
    /// re-cut: its raw `0x181717` measures OKLCh C 0.0016, which is quantisation
    /// noise in a near-black and not a brand decision, so it belongs with the
    /// achromatic set. Re-derived at the new light lightness it would have come
    /// out `0x575656` against the neutral's `0x575757` — ΔE 0.0030, the same
    /// invisible distinction arriving again, which is why the answer is to stop
    /// keying it rather than to keep the number in step.
    ///
    /// Mistral keeps a case of its own even though `0x7C4635` is one 8-bit step
    /// from Claude's `0x7C4634`, which looks like the distinction Copilot just
    /// lost. It is not the same thing. Copilot's case duplicated the `default`,
    /// so deleting it removes a branch and changes nothing; Claude and Mistral are
    /// two entries that both have to exist, and merging them would be a grouping
    /// choice rather than the removal of a dead one. `liveBand` below does merge
    /// them, because there the two derive to a byte-identical light half.
    ///
    /// Every light value below is re-derived at OKLCh L 0.455; the dark values
    /// are unchanged. The derivation is one function of the raw `hex`, so the
    /// same code that produces these also reproduces every dark hex byte for
    /// byte — which is the check that the light half was re-cut and not retyped.
    private static func band(_ providerID: String) -> (light: UInt32, dark: UInt32) {
        switch providerID {
        case "claude", "claudecode": return (0x7C4634, 0xE6AF9D)
        case "mistral":             return (0x7C4635, 0xE6AF9E)
        case "minimax":             return (0x7D443D, 0xE7ADA4)
        case "perplexity":          return (0x00626F, 0x87CBD7)
        case "openrouter":          return (0x4C5283, 0xB2BAEB)
        case "deepseek":            return (0x455483, 0xACBCEC)
        case "gemini":              return (0x5F4B7B, 0xC6B3E4)
        default:                    return neutralBand
        }
    }

    /// Where a mark with no hue worth banding lands, and the safe answer for a
    /// mark added tomorrow: grey that reads, rather than a saturated literal
    /// that outshouts the alert.
    ///
    /// The light half was `0x636363` (L\* 41.96, 3.93:1 on the worst plane) and
    /// is the band's own rule at C 0: the grey at OKLCh L 0.455, L\* 36.99,
    /// 4.73:1.
    private static let neutralBand: (light: UInt32, dark: UInt32) = (0x575757, 0xBEBEBE)

    // MARK: - The brand as a mark rather than as a figure

    /// The brand's colour as a *mark* is drawn in it: hue only, at `Ink.mark`'s
    /// own lightness.
    ///
    /// A second band and not a second opinion. `brandInk` above is cut for a
    /// meter fill and a percentage — a figure has to clear 4.5:1 — and a mark is
    /// neither of those. It is an 18pt silhouette in the leading column, standing
    /// in the ladder the whole panel's hierarchy is built from (`body` 15.20 →
    /// `mark` 10.58 → `muted` 6.85 on `Surface.base`). Painting it at the figure
    /// band's lightness measures **7.04:1** for a live Claude, which is the
    /// `muted` rung and not the `mark` one: a service that *is* reporting would
    /// be drawn at the weight this app uses to say a service is not. Measured,
    /// not feared — that is the number the band above produces.
    ///
    /// So this band holds `Ink.mark`'s lightness exactly (OKLCh L 0.3496 light,
    /// L 0.8414 dark) and spends the brand only on hue, at C ≤ 0.070. Every entry
    /// lands within **0.35:1** of `Ink.mark`'s own contrast on every ground in
    /// the app — base, hovered card, raised, logo tile, the worst plane and both
    /// ends of the menu bar's range, in both appearances — and the worst of them
    /// is 7.11:1 (MiniMax, dark worst plane) against a 3:1 floor. That is the
    /// property an escape hatch rests on: turning brand colour off removes a hue
    /// and moves no measurement.
    ///
    /// **The chroma ceiling is C ≤ 0.070, one value for both appearances.** It is
    /// the tighter half of the ceiling `brandInk` already holds (0.08 light /
    /// 0.07 dark), applied to both because a mark is a far denser shape than a
    /// 5pt bar and must not be allowed the looser of the two. No brand exceeds
    /// it, and the reason is arithmetic rather than luck: the ceiling is applied
    /// *before* the derivation, so a raw hue louder than it is simply clamped —
    /// the loudest value the set produces after 8-bit quantisation is C 0.0705
    /// (OpenRouter dark), and the only entry under the ceiling is Perplexity's
    /// light half at C 0.0619, where the sRGB gamut at L 0.3496 and h 209.8 runs
    /// out before the ceiling does.
    ///
    /// The ceiling is also chosen against the alarms, which are the only other
    /// chroma in the application: `Ink.attention` is OKLCh C **0.0965** light and
    /// 0.1506 dark, `Ink.alarm` C 0.1414 light and 0.1069 dark. The binding case
    /// is the light amber, the quietest thing in the app that means "act", and
    /// 0.070 is **0.725×** it — 0.465× the dark amber, 0.495× the light red,
    /// 0.655× the dark red. The loudest derived value, 0.0705, is 0.730× the
    /// light amber. A brand mark cannot out-shout an alarm because it is not
    /// permitted three quarters of its saturation.
    ///
    /// Resolved rather than dynamic, for the reason `brandInk(dark:)` is: the
    /// strip is rasterised through `ImageRenderer`, which draws in the light
    /// appearance whatever the menu bar is doing. Panel-side callers take
    /// `liveInk` below.
    public func liveInk(dark: Bool) -> Color {
        let band = Self.liveBand(providerID)
        return Color(hex: dark ? band.dark : band.light)
    }

    /// The same pair as a dynamic value, for a call site with an appearance to
    /// resolve against — which is every surface except the strip.
    public var liveInk: Color {
        let band = Self.liveBand(providerID)
        return Tokens.dynamic(light: band.light, dark: band.dark)
    }

    /// The live band, keyed by provider.
    ///
    /// Grouped the way the derivation came out rather than the way the companies
    /// are. Claude and Claude Code are one company and one colour, which is the
    /// same grouping `band(_:)` makes. Mistral joins them because at C 0.070 and
    /// one lightness it *is* that colour: raw hues 38.8° and 37.6° derive to a
    /// byte-identical light half and to dark halves `0xF4BCAA` and `0xF4BCAB`,
    /// OKLab ΔE 0.0013 apart. Shipping those as two cases would be the distinction
    /// `band(_:)`'s deleted Copilot entry was. The seven brands with no entry are
    /// the achromatic set — OpenAI's two, Cursor, Copilot, Grok, Z.ai, OpenCode,
    /// and anything added tomorrow — and they fall through to the mark ink, which
    /// is this band's own rule evaluated at C 0 rather than an exception to it.
    ///
    /// DeepSeek and OpenRouter stay separate at ΔE 0.0100 light and 0.0101 dark:
    /// perceptibly two periwinkles, barely. They are two independent derivations
    /// that happen to land close, not two names for one colour.
    private static func liveBand(_ providerID: String) -> (light: UInt32, dark: UInt32) {
        switch providerID {
        case "claude", "claudecode", "mistral": return (0x592C1E, 0xF4BCAA)
        case "minimax":    return (0x592B25, 0xF5BAB1)
        case "gemini":     return (0x423158, 0xD4C1F1)
        // The one entry below the ceiling, and not by choice: the sRGB gamut at
        // L 0.3496 and h 209.8 runs out at C 0.0619.
        case "perplexity": return (0x00434C, 0x94D8E4)
        case "deepseek":   return (0x2C385F, 0xB9CAFA)
        case "openrouter": return (0x32365E, 0xBFC7F9)
        default:           return achromaticBand
        }
    }

    /// Where a brand with no hue lands, byte-identical to `Tokens.Ink.mark`.
    ///
    /// It has to be. This band's claim is that brand colour changes hue and never
    /// weight, so a brand with no hue must come out at exactly the ink a mark
    /// already draws in — which makes the whole achromatic set a strict no-op and
    /// not a special case. Written as literals rather than reached through
    /// `Tokens.Ink.mark` because `liveInk(dark:)` is resolved rather than dynamic
    /// and the strip takes one half of it; a test asserts the two stay equal in
    /// both appearances, so the duplication cannot drift.
    private static let achromaticBand: (light: UInt32, dark: UInt32) = (0x383A42, 0xC7CBD3)

    /// The OpenAI glyph, carried by two entries.
    ///
    /// simple-icons published it up to v14 and has since dropped it from the
    /// set, so this is the last CC0 revision of the mark. It is a shared
    /// constant rather than two pasted copies because `chatgpt` and `codex` are
    /// the same company's mark: one copy quietly drifting from the other is the
    /// one bug a single constant cannot have.
    private static let openAIGlyph = "M22.2819 9.8211a5.9847 5.9847 0 0 0-.5157-4.9108 6.0462 6.0462 0 0 0-6.5098-2.9A6.0651 6.0651 0 0 0 4.9807 4.1818a5.9847 5.9847 0 0 0-3.9977 2.9 6.0462 6.0462 0 0 0 .7427 7.0966 5.98 5.98 0 0 0 .511 4.9107 6.051 6.051 0 0 0 6.5146 2.9001A5.9847 5.9847 0 0 0 13.2599 24a6.0557 6.0557 0 0 0 5.7718-4.2058 5.9894 5.9894 0 0 0 3.9977-2.9001 6.0557 6.0557 0 0 0-.7475-7.0729zm-9.022 12.6081a4.4755 4.4755 0 0 1-2.8764-1.0408l.1419-.0804 4.7783-2.7582a.7948.7948 0 0 0 .3927-.6813v-6.7369l2.02 1.1686a.071.071 0 0 1 .038.052v5.5826a4.504 4.504 0 0 1-4.4945 4.4944zm-9.6607-4.1254a4.4708 4.4708 0 0 1-.5346-3.0137l.142.0852 4.783 2.7582a.7712.7712 0 0 0 .7806 0l5.8428-3.3685v2.3324a.0804.0804 0 0 1-.0332.0615L9.74 19.9502a4.4992 4.4992 0 0 1-6.1408-1.6464zM2.3408 7.8956a4.485 4.485 0 0 1 2.3655-1.9728V11.6a.7664.7664 0 0 0 .3879.6765l5.8144 3.3543-2.0201 1.1685a.0757.0757 0 0 1-.071 0l-4.8303-2.7865A4.504 4.504 0 0 1 2.3408 7.872zm16.5963 3.8558L13.1038 8.364 15.1192 7.2a.0757.0757 0 0 1 .071 0l4.8303 2.7913a4.4944 4.4944 0 0 1-.6765 8.1042v-5.6772a.79.79 0 0 0-.407-.667zm2.0107-3.0231l-.142-.0852-4.7735-2.7818a.7759.7759 0 0 0-.7854 0L9.409 9.2297V6.8974a.0662.0662 0 0 1 .0284-.0615l4.8303-2.7866a4.4992 4.4992 0 0 1 6.6802 4.66zM8.3065 12.863l-2.02-1.1638a.0804.0804 0 0 1-.038-.0567V6.0742a4.4992 4.4992 0 0 1 7.3757-3.4537l-.142.0805L8.704 5.459a.7948.7948 0 0 0-.3927.6813zm1.0976-2.3654l2.602-1.4998 2.6069 1.4998v2.9994l-2.5974 1.4997-2.6067-1.4997Z"

    public static let all: [BrandMark] = [
        BrandMark(
            providerID: "claude",
            title: "Claude",
            viewBox: CGSize(width: 24, height: 24),
            pathData: "m4.7144 15.9555 4.7174-2.6471.079-.2307-.079-.1275h-.2307l-.7893-.0486-2.6956-.0729-2.3375-.0971-2.2646-.1214-.5707-.1215-.5343-.7042.0546-.3522.4797-.3218.686.0608 1.5179.1032 2.2767.1578 1.6514.0972 2.4468.255h.3886l.0546-.1579-.1336-.0971-.1032-.0972L6.973 9.8356l-2.55-1.6879-1.3356-.9714-.7225-.4918-.3643-.4614-.1578-1.0078.6557-.7225.8803.0607.2246.0607.8925.686 1.9064 1.4754 2.4893 1.8336.3643.3035.1457-.1032.0182-.0728-.164-.2733-1.3539-2.4467-1.445-2.4893-.6435-1.032-.17-.6194c-.0607-.255-.1032-.4674-.1032-.7285L6.287.1335 6.6997 0l.9957.1336.419.3642.6192 1.4147 1.0018 2.2282 1.5543 3.0296.4553.8985.2429.8318.091.255h.1579v-.1457l.1275-1.706.2368-2.0947.2307-2.6957.0789-.7589.3764-.9107.7468-.4918.5828.2793.4797.686-.0668.4433-.2853 1.8517-.5586 2.9021-.3643 1.9429h.2125l.2429-.2429.9835-1.3053 1.6514-2.0643.7286-.8196.85-.9046.5464-.4311h1.0321l.759 1.1293-.34 1.1657-1.0625 1.3478-.8804 1.1414-1.2628 1.7-.7893 1.36.0729.1093.1882-.0183 2.8535-.607 1.5421-.2794 1.8396-.3157.8318.3886.091.3946-.3278.8075-1.967.4857-2.3072.4614-3.4364.8136-.0425.0304.0486.0607 1.5482.1457.6618.0364h1.621l3.0175.2247.7892.522.4736.6376-.079.4857-1.2142.6193-1.6393-.3886-3.825-.9107-1.3113-.3279h-.1822v.1093l1.0929 1.0686 2.0035 1.8092 2.5075 2.3314.1275.5768-.3218.4554-.34-.0486-2.2039-1.6575-.85-.7468-1.9246-1.621h-.1275v.17l.4432.6496 2.3436 3.5214.1214 1.0807-.17.3521-.6071.2125-.6679-.1214-1.3721-1.9246L14.38 17.959l-1.1414-1.9428-.1397.079-.674 7.2552-.3156.3703-.7286.2793-.6071-.4614-.3218-.7468.3218-1.4753.3886-1.9246.3157-1.53.2853-1.9004.17-.6314-.0121-.0425-.1397.0182-1.4328 1.9672-2.1796 2.9446-1.7243 1.8456-.4128.164-.7164-.3704.0667-.6618.4008-.5889 2.386-3.0357 1.4389-1.882.929-1.0868-.0062-.1579h-.0546l-6.3385 4.1164-1.1293.1457-.4857-.4554.0608-.7467.2307-.2429 1.9064-1.3114Z",
            hex: 0xD97757,
            opticalScale: 0.93
        ),
        // The OpenAI glyph; provenance is on `openAIGlyph`.
        BrandMark(
            providerID: "chatgpt",
            title: "OpenAI",
            viewBox: CGSize(width: 24, height: 24),
            pathData: BrandMark.openAIGlyph,
            hex: 0x0D0D0D,
            opticalScale: 0.95
        ),
        BrandMark(
            providerID: "cursor",
            title: "Cursor",
            viewBox: CGSize(width: 24, height: 24),
            pathData: "M11.503.131 1.891 5.678a.84.84 0 0 0-.42.726v11.188c0 .3.162.575.42.724l9.609 5.55a1 1 0 0 0 .998 0l9.61-5.55a.84.84 0 0 0 .42-.724V6.404a.84.84 0 0 0-.42-.726L12.497.131a1.01 1.01 0 0 0-.996 0M2.657 6.338h18.55c.263 0 .43.287.297.515L12.23 22.918c-.062.107-.229.064-.229-.06V12.335a.59.59 0 0 0-.295-.51l-9.11-5.257c-.109-.063-.064-.23.061-.23",
            hex: 0x1A1A1A,
            opticalScale: 0.85
        ),
        BrandMark(
            providerID: "copilot",
            title: "GitHub Copilot",
            viewBox: CGSize(width: 24, height: 24),
            pathData: "M23.922 16.997C23.061 18.492 18.063 22.02 12 22.02 5.937 22.02.939 18.492.078 16.997A.641.641 0 0 1 0 16.741v-2.869a.883.883 0 0 1 .053-.22c.372-.935 1.347-2.292 2.605-2.656.167-.429.414-1.055.644-1.517a10.098 10.098 0 0 1-.052-1.086c0-1.331.282-2.499 1.132-3.368.397-.406.89-.717 1.474-.952C7.255 2.937 9.248 1.98 11.978 1.98c2.731 0 4.767.957 6.166 2.093.584.235 1.077.546 1.474.952.85.869 1.132 2.037 1.132 3.368 0 .368-.014.733-.052 1.086.23.462.477 1.088.644 1.517 1.258.364 2.233 1.721 2.605 2.656a.841.841 0 0 1 .053.22v2.869a.641.641 0 0 1-.078.256Zm-11.75-5.992h-.344a4.359 4.359 0 0 1-.355.508c-.77.947-1.918 1.492-3.508 1.492-1.725 0-2.989-.359-3.782-1.259a2.137 2.137 0 0 1-.085-.104L4 11.746v6.585c1.435.779 4.514 2.179 8 2.179 3.486 0 6.565-1.4 8-2.179v-6.585l-.098-.104s-.033.045-.085.104c-.793.9-2.057 1.259-3.782 1.259-1.59 0-2.738-.545-3.508-1.492a4.359 4.359 0 0 1-.355-.508Zm2.328 3.25c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm-5 0c.549 0 1 .451 1 1v2c0 .549-.451 1-1 1-.549 0-1-.451-1-1v-2c0-.549.451-1 1-1Zm3.313-6.185c.136 1.057.403 1.913.878 2.497.442.544 1.134.938 2.344.938 1.573 0 2.292-.337 2.657-.751.384-.435.558-1.15.558-2.361 0-1.14-.243-1.847-.705-2.319-.477-.488-1.319-.862-2.824-1.025-1.487-.161-2.192.138-2.533.529-.269.307-.437.808-.438 1.578v.021c0 .265.021.562.063.893Zm-1.626 0c.042-.331.063-.628.063-.894v-.02c-.001-.77-.169-1.271-.438-1.578-.341-.391-1.046-.69-2.533-.529-1.505.163-2.347.537-2.824 1.025-.462.472-.705 1.179-.705 2.319 0 1.211.175 1.926.558 2.361.365.414 1.084.751 2.657.751 1.21 0 1.902-.394 2.344-.938.475-.584.742-1.44.878-2.497Z",
            hex: 0x181717,
            opticalScale: 1.03
        ),
        BrandMark(
            providerID: "minimax",
            title: "MiniMax",
            viewBox: CGSize(width: 24, height: 24),
            pathData: "M11.43 3.92a.86.86 0 1 0-1.718 0v14.236a1.999 1.999 0 0 1-3.997 0V9.022a.86.86 0 1 0-1.718 0v3.87a1.999 1.999 0 0 1-3.997 0V11.49a.57.57 0 0 1 1.139 0v1.404a.86.86 0 0 0 1.719 0V9.022a1.999 1.999 0 0 1 3.997 0v9.134a.86.86 0 0 0 1.719 0V3.92a1.998 1.998 0 1 1 3.996 0v11.788a.57.57 0 1 1-1.139 0zm10.572 3.105a2 2 0 0 0-1.999 1.997v7.63a.86.86 0 0 1-1.718 0V3.923a1.999 1.999 0 0 0-3.997 0v16.16a.86.86 0 0 1-1.719 0V18.08a.57.57 0 1 0-1.138 0v2a1.998 1.998 0 0 0 3.996 0V3.92a.86.86 0 0 1 1.719 0v12.73a1.999 1.999 0 0 0 3.996 0V9.023a.86.86 0 1 1 1.72 0v6.686a.57.57 0 0 0 1.138 0V9.022a2 2 0 0 0-1.998-1.997",
            hex: 0xE1483B,
            opticalScale: 1.10
        ),
        BrandMark(
            providerID: "gemini",
            title: "Google Gemini",
            viewBox: CGSize(width: 24, height: 24),
            pathData: "M11.04 19.32Q12 21.51 12 24q0-2.49.93-4.68.96-2.19 2.58-3.81t3.81-2.55Q21.51 12 24 12q-2.49 0-4.68-.93a12.3 12.3 0 0 1-3.81-2.58 12.3 12.3 0 0 1-2.58-3.81Q12 2.49 12 0q0 2.49-.96 4.68-.93 2.19-2.55 3.81a12.3 12.3 0 0 1-3.81 2.58Q2.49 12 0 12q2.49 0 4.68.96 2.19.93 3.81 2.55t2.55 3.81",
            hex: 0x8E75B2,
            opticalScale: 1.10
        ),
        BrandMark(
            providerID: "perplexity",
            title: "Perplexity",
            viewBox: CGSize(width: 24, height: 24),
            pathData: "M22.3977 7.0896h-2.3106V.0676l-7.5094 6.3542V.1577h-1.1554v6.1966L4.4904 0v7.0896H1.6023v10.3976h2.8882V24l6.932-6.3591v6.2005h1.1554v-6.0469l6.9318 6.1807v-6.4879h2.8882V7.0896zm-3.4657-4.531v4.531h-5.355l5.355-4.531zm-13.2862.0676 4.8691 4.4634H5.6458V2.6262zM2.7576 16.332V8.245h7.8476l-6.1149 6.1147v1.9723H2.7576zm2.8882 5.0404v-3.8852h.0001v-2.6488l5.7763-5.7764v7.0111l-5.7764 5.2993zm12.7086.0248-5.7766-5.1509V9.0618l5.7766 5.7766v6.5588zm2.8882-5.0652h-1.733v-1.9723L13.3948 8.245h7.8478v8.087z",
            hex: 0x1FB8CD,
            opticalScale: 1.08
        ),
        BrandMark(
            providerID: "deepseek",
            title: "DeepSeek",
            viewBox: CGSize(width: 24, height: 24),
            pathData: "M23.748 4.651c-.254-.124-.364.113-.512.233-.051.04-.094.09-.137.137-.372.397-.806.657-1.373.626-.829-.046-1.537.214-2.163.848-.133-.782-.575-1.248-1.247-1.548-.352-.155-.708-.311-.955-.65-.172-.24-.219-.509-.305-.774-.055-.16-.11-.323-.293-.35-.2-.031-.278.136-.356.276-.313.572-.434 1.202-.422 1.84.027 1.436.633 2.58 1.838 3.393.137.094.172.187.129.323-.082.28-.18.553-.266.833-.055.179-.137.218-.328.14a5.5 5.5 0 0 1-1.737-1.179c-.857-.828-1.631-1.743-2.597-2.46a12 12 0 0 0-.689-.47c-.985-.957.13-1.743.387-1.836.27-.098.094-.433-.778-.428-.872.003-1.67.295-2.687.685a3 3 0 0 1-.465.136 9.6 9.6 0 0 0-2.883-.101c-1.885.21-3.39 1.1-4.497 2.622C.082 8.776-.231 10.854.152 13.02c.403 2.284 1.568 4.175 3.36 5.653 1.857 1.533 3.997 2.284 6.438 2.14 1.482-.085 3.132-.284 4.994-1.86.47.234.962.328 1.78.398.629.058 1.235-.031 1.705-.129.735-.155.684-.836.418-.961-2.155-1.004-1.682-.595-2.112-.926 1.095-1.295 2.768-3.598 3.284-6.733.05-.346.115-.834.108-1.114-.004-.171.035-.238.23-.257a4.2 4.2 0 0 0 1.545-.475c1.397-.763 1.96-2.016 2.093-3.517.02-.23-.004-.467-.247-.588M11.58 18.168c-2.088-1.642-3.101-2.183-3.52-2.16-.39.024-.32.472-.234.763.09.288.207.487.371.74.114.167.192.416-.113.603-.673.416-1.842-.14-1.897-.168-1.361-.801-2.5-1.86-3.301-3.306-.775-1.393-1.225-2.888-1.299-4.482-.02-.385.094-.522.477-.592a4.7 4.7 0 0 1 1.53-.038c2.131.311 3.946 1.264 5.467 2.774.868.86 1.525 1.887 2.202 2.89.72 1.066 1.494 2.082 2.48 2.915.348.291.626.513.892.677-.802.09-2.14.109-3.055-.615zm1.001-6.44a.306.306 0 0 1 .415-.287.3.3 0 0 1 .113.074.3.3 0 0 1 .086.214c0 .17-.136.307-.308.307a.303.303 0 0 1-.306-.307m3.11 1.596c-.2.081-.4.151-.591.16a1.25 1.25 0 0 1-.798-.254c-.274-.23-.47-.358-.551-.758a1.7 1.7 0 0 1 .015-.588c.07-.327-.007-.537-.238-.727-.188-.156-.426-.199-.689-.199a.6.6 0 0 1-.254-.078.253.253 0 0 1-.114-.358 1 1 0 0 1 .192-.21c.356-.202.767-.136 1.146.016.352.144.618.408 1.001.782.392.451.462.576.685.915.176.264.336.536.446.848.066.194-.02.353-.25.45",
            hex: 0x4D6BFE,
            opticalScale: 0.96
        ),
        // Not a simple-icons glyph (the set has no Grok entry): an xAI brand asset,
        // 1024x1024 view box, two subpaths concatenated. Used to identify the
        // service, not under CC0.
        BrandMark(
            providerID: "grok",
            title: "Grok",
            viewBox: CGSize(width: 1024, height: 1024),
            pathData: "M395.479 633.828L735.91 381.105C752.599 368.715 776.454 373.548 784.406 392.792C826.26 494.285 807.561 616.253 724.288 699.996C641.016 783.739 525.151 802.104 419.247 760.277L303.556 814.143C469.49 928.202 670.987 899.995 796.901 773.282C896.776 672.843 927.708 535.937 898.785 412.476L899.047 412.739C857.105 231.37 909.358 158.874 1016.4 10.6326C1018.93 7.11771 1021.47 3.60279 1024 0L883.144 141.651V141.212L395.392 633.916 M325.226 695.251C206.128 580.84 226.662 403.776 328.285 301.668C403.431 226.097 526.549 195.254 634.026 240.596L749.454 186.994C728.657 171.88 702.007 155.623 671.424 144.2C533.19 86.9942 367.693 115.465 255.323 228.382C147.234 337.081 113.244 504.215 171.613 646.833C215.216 753.423 143.739 828.818 71.7385 904.916C46.2237 931.893 20.6216 958.87 0 987.429L325.139 695.339",
            hex: 0x0A0A0A,
            opticalScale: 1.10
        ),
        BrandMark(
            providerID: "openrouter",
            title: "OpenRouter",
            viewBox: CGSize(width: 24, height: 24),
            pathData: "M16.778 1.844v1.919q-.569-.026-1.138-.032-.708-.008-1.415.037c-1.93.126-4.023.728-6.149 2.237-2.911 2.066-2.731 1.95-4.14 2.75-.396.223-1.342.574-2.185.798-.841.225-1.753.333-1.751.333v4.229s.768.108 1.61.333c.842.224 1.789.575 2.185.799 1.41.798 1.228.683 4.14 2.75 2.126 1.509 4.22 2.11 6.148 2.236.88.058 1.716.041 2.555.005v1.918l7.222-4.168-7.222-4.17v2.176c-.86.038-1.611.065-2.278.021-1.364-.09-2.417-.357-3.979-1.465-2.244-1.593-2.866-2.027-3.68-2.508.889-.518 1.449-.906 3.822-2.59 1.56-1.109 2.614-1.377 3.978-1.466.667-.044 1.418-.017 2.278.02v2.176L24 6.014Z",
            hex: 0x6467F2,
            opticalScale: 1.00
        ),
        BrandMark(
            providerID: "mistral",
            title: "Mistral",
            viewBox: CGSize(width: 24, height: 24),
            pathData: "M17.143 3.429v3.428h-3.429v3.429h-3.428V6.857H6.857V3.43H3.43v13.714H0v3.428h10.286v-3.428H6.857v-3.429h3.429v3.429h3.429v-3.429h3.428v3.429h-3.428v3.428H24v-3.428h-3.43V3.429z",
            hex: 0xFA520F,
            opticalScale: 0.91
        ),
        // Codex is OpenAI's, so it carries OpenAI's mark — the same one
        // `chatgpt` draws, deliberately, because there is no separate published
        // Codex glyph and inventing one would be drawing someone's trademark
        // for them. It is a second entry rather than an alias so the strip
        // resolves it by its own id: `chatgpt` reports subscription status and
        // `codex` reports usage windows, and they are two rows that can appear
        // at once.
        BrandMark(
            providerID: "codex",
            title: "OpenAI Codex",
            viewBox: CGSize(width: 24, height: 24),
            pathData: BrandMark.openAIGlyph,
            hex: 0x0D0D0D,
            opticalScale: 0.95
        ),
        // simple-icons slug `zdotai` — the set spells the dot out, this repo
        // keys marks by provider id, which is `zai`.
        BrandMark(
            providerID: "zai",
            title: "Z.ai",
            viewBox: CGSize(width: 24, height: 24),
            pathData: "M12.606 1.806l-1.677 2.388c-0.258 0.374-0.697 0.606-1.161 0.606h-9.162V1.794C0.594 1.806 12.606 1.806 12.606 1.806zM24 1.806L9.6 22.206 0 22.206 14.4 1.806zM11.394 22.206l1.69-2.4c0.258-0.374 0.697-0.606 1.161-0.606h9.149v3.006H11.394z",
            hex: 0x2D2D2D,
            opticalScale: 0.86
        ),
        // simple-icons slug `claudecode`. A different mark from `claude`, which
        // matters here: Claude and Claude Code are two rows measuring different
        // things, and at 13pt in the strip the only thing telling them apart is
        // the glyph. They keep the one brand colour because they are one brand.
        BrandMark(
            providerID: "claudecode",
            title: "Claude Code",
            viewBox: CGSize(width: 24, height: 24),
            pathData: "M21 10.5h3v3h-3v3h-1.5v3H18v-3h-1.5v3H15v-3H9v3H7.5v-3H6v3H4.5v-3H3v-3H0v-3h3v-6h18Zm-15 0h1.5v-3H6Zm10.5 0H18v-3h-1.5z",
            hex: 0xD97757,
            opticalScale: 0.90
        ),
        // simple-icons slug `opencode`.
        BrandMark(
            providerID: "opencode",
            title: "OpenCode",
            viewBox: CGSize(width: 24, height: 24),
            pathData: "M22 24H2V0h20zM17 4.8H7v14.4h10z",
            hex: 0x000000,
            opticalScale: 0.80
        ),
    ]
}
