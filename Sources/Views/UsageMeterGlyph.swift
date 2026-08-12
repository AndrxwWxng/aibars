import SwiftUI

/// The app's own mark: four bars on a baseline.
///
/// It reports nothing, and that is the change. The mark used to be the meter —
/// the bar heights were live usage levels — but the menu bar strip now carries
/// one brand glyph and one figure per service, so a mark that also carried data
/// would be two instruments in the same window answering the same question
/// differently. What is left is identity: the header, the About pane, and the
/// status item's "nothing to report yet" fallback.
///
/// Every measurement is a fraction of `size`, so 16pt in the panel header and
/// 44pt in About are the same shape rather than two drawings that resemble each
/// other.
public struct AppMark: View {
    /// The whole height of the mark, baseline included.
    public let size: CGFloat
    /// The mark's colour.
    ///
    /// `Tokens.Ink.arc` by default. The accent's call sites are a closed list of
    /// six — this mark in the panel header, this mark in About, a text link, the
    /// connect affordance on a disconnected row, the same affordance at first
    /// run, and a focus ring — and the first two are both this default. None of
    /// the six is a meter, which is why nothing else in this file reaches for
    /// Arc: the usage ramp below is a different statement, and a meter drawn in
    /// the app's own colour would say "this is aibars" where it has to say "this
    /// is how full you are".
    ///
    /// A caller rasterising the mark into a template image passes a flat colour
    /// instead, because a template is drawn from its alpha and AppKit supplies
    /// the rest — so the strip's fallback glyph is not a seventh call site.
    public let tint: Color

    public init(size: CGFloat, tint: Color = Tokens.Ink.arc) {
        self.size = size
        self.tint = tint
    }

    /// The mark's own profile, tallest first. Fixed, and these four values in
    /// particular: they are the heights the About pane passed in by hand while
    /// the glyph still took live levels, so the shape the app was already being
    /// represented by is the shape it keeps.
    private static let profile: [Double] = [0.9, 0.65, 0.4, 0.2]

    /// The baseline is quieter than the bars it carries. It exists to keep the
    /// mark legible as a mark — without it, four unequal bars floating in a
    /// 16pt box read as noise at menu bar size.
    private static let baselineOpacity: Double = 0.55

    // Every measurement is rounded to a whole point. Two of these — the spacing
    // and the plot height — were free-floating while the other two were already
    // rounded, which left `totalWidth` fractional at most sizes; the status item
    // then resamples the image to fit its slot, and half a point of resampling
    // is visible blur on a mark that is mostly 3pt-wide bars.
    private var barWidth: CGFloat { max(2, (size * 0.23).rounded()) }
    private var spacing: CGFloat { max(1, (size * 0.14).rounded()) }
    private var baselineHeight: CGFloat { max(1, (size * 0.09).rounded()) }
    /// Bars to baseline. Its own measurement rather than a share of the spacing:
    /// it is the gap that makes the baseline read as an axis instead of as a
    /// fifth bar lying on its side.
    private var baselineGap: CGFloat { max(1, (size * 0.11).rounded()) }
    /// Rounded down, so the three stacked parts can never add up to more than
    /// the height the caller asked for. Any slack left over sits above the bars,
    /// where nothing is drawn.
    private var plotHeight: CGFloat {
        max(1, (size - baselineHeight - baselineGap).rounded(.down))
    }
    private var totalWidth: CGFloat {
        let count = CGFloat(Self.profile.count)
        return count * barWidth + (count - 1) * spacing
    }

    public var body: some View {
        VStack(spacing: baselineGap) {
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(Self.profile.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: barWidth * 0.4, style: Tokens.Radius.style)
                        .fill(tint)
                        .frame(width: barWidth, height: barHeight(level))
                }
            }
            .frame(height: plotHeight, alignment: .bottom)

            RoundedRectangle(cornerRadius: baselineHeight / 2, style: Tokens.Radius.style)
                .fill(tint.opacity(Self.baselineOpacity))
                .frame(width: totalWidth, height: baselineHeight)
        }
        .frame(width: totalWidth, height: size, alignment: .bottom)
    }

    /// Integral like the rest: a bar whose top edge lands on half a pixel is a
    /// bar with a grey lid at menu bar size.
    private func barHeight(_ level: Double) -> CGFloat {
        max(1, (plotHeight * CGFloat(level)).rounded())
    }
}

/// The usage ramp: three stops, shared by every meter, every percentage and the
/// menu bar strip.
///
/// Each stop is a light/dark pair rather than one value, because the ramp is
/// also the text colour of a readout and a single value cannot serve both
/// appearances — the dark stops sit at 2.2:1–3.9:1 on a light panel, well under
/// the 4.5:1 body text needs. Every stop here clears 4.5:1 against
/// `Tokens.Surface.base` in its own appearance.
///
/// The boundaries are settings (`cautionThreshold`, `warningThreshold`); only
/// the palette lives here, so there is one place to read the ramp off. The
/// sampled boundaries below are the shipped defaults of those two settings, and
/// they are what a caller asking for "the caution colour" has to pass — they are
/// not a second, private opinion about where caution starts. Anything drawing a
/// live reading goes through `AppearanceSettings.tint(for:providerAccent:)`,
/// which reads the user's thresholds and the chosen ramp.
///
/// There is deliberately no menu bar variant here. Whether the strip takes a
/// tint at all depends on `menuBarColour`, which is a setting, so that decision
/// belongs to `AppearanceSettings.menuBarTint(for:)` and living in two places is
/// how the strip came to ignore `.monochrome` while the panel honoured it.
public enum UsageTint {
    public static func color(for percent: Double) -> Color {
        switch percent {
        // The resting stop is not a colour at all, and that is the point. It
        // used to be teal, and a panel of nine healthy rows was nine teal bars —
        // colour spent on the least informative state there is. Grey means a
        // healthy row carries no hue, so any hue anywhere in the panel means
        // something wants looking at. It is also strictly better than
        // teal→amber→red for deuteranomaly and protanopia, which collapse hues
        // towards each other but never towards grey.
        case ..<0.80: return Tokens.dynamic(light: 0x5F636B, dark: 0x8A8F98)   // resting grey
        case ..<0.95: return Tokens.dynamic(light: 0xB45309, dark: 0xF5A623)   // amber
        default:      return Tokens.dynamic(light: 0xC62A2F, dark: 0xFF6B6E)   // red
        }
    }

}
