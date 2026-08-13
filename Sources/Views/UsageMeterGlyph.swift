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
    /// `Tokens.Ink.body` by default, and the default moved because the token it
    /// used to name is gone. `Tokens.Ink.arc` was the app's own indigo — this
    /// mark in the header, this mark in About, a text link, the sign-in word on a
    /// disconnected row, and the connect dialog's buttons. Indigo is not grey,
    /// amber or red, and the palette now spends chroma on alarm alone, so the
    /// token is deleted rather than re-cut. Arc's job — "this is the app" — is
    /// carried by the silhouette below, which is what a mark is for.
    ///
    /// `body` rather than `mark` because in both of the places this default is
    /// taken — the panel header and the About pane — the drawing *is* the
    /// subject rather than a label beside one, and that is the rung `body` names:
    /// 15.20:1 light and 17.49:1 dark on `Surface.base`, against `mark`'s 10.58
    /// and 11.94. Nothing in this file reaches for a hue any more, which is the
    /// same rule stated from the other side: a mark drawn in a meter's colour
    /// would say "this is how full you are" where it has to say "this is aibars".
    ///
    /// A caller rasterising the mark into a template image passes a flat colour
    /// instead, because a template is drawn from its alpha and AppKit supplies
    /// the rest — so the strip's fallback glyph is not a third call site.
    public let tint: Color

    public init(size: CGFloat, tint: Color = Tokens.Ink.body) {
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
/// appearances — measured, the dark stops sit at 1.75:1–2.45:1 on a light panel
/// and the light stops at 1.84:1–2.65:1 on a dark one, all well under the 4.5:1
/// body text needs.
///
/// No pair is written out here any more. All three stops are `Tokens.Ink`
/// tokens, so each pair lives once, in the palette, and the ramp stops being a
/// second file's opinion about a colour the first file also holds. That is the
/// lesson amber taught twice: `0xB45309` and then `0xF5A623` were both "the
/// ramp's amber" written out beside `Ink.attention`, and both times one of the
/// two got re-cut for contrast and the other did not. Every stop clears 4.5:1 on
/// the worst plane in the panel — the pressed row card over the hardest
/// wallpaper — at 4.80/4.81 resting, 4.90/4.53 amber, 6.92/6.34 red.
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
        //
        // `Ink.muted` itself, not a private grey beside it. It was
        // 0x5F636B / 0x8A8F98, which sat within 3 L* of the token in both
        // appearances — a duplicate rather than a decision, and the dark half of
        // it measured 4.48:1 on the pressed row card, under the text floor. The
        // consequence is worth saying out loud: below caution, `ColorRamp.usage`
        // and `ColorRamp.mono` now resolve identically. They still differ above
        // it, which is the only band where that setting was ever saying anything.
        case ..<0.80: return Tokens.Ink.muted                                  // resting grey
        // One amber, and it is `Ink.attention` itself rather than a second copy
        // of its pair. The light stop used to be 0xB45309, which is a different
        // amber from the one "this needs you" is drawn in — two ambers a user has
        // to learn — and it measured 3.87:1 on a hovered `.always` card, which is
        // the worst ground in the panel and is shipped by three of the five
        // presets. A figure below the 4.5:1 floor is not a reading.
        //
        // Referenced, not repeated. Written out here as 0x8A5A00 / 0xF5A623 it
        // was byte-identical to the token by hand, in a second file, which is the
        // arrangement that produced the two ambers in the first place: one of the
        // two gets re-cut for contrast and the other does not.
        case ..<0.95: return Tokens.Ink.attention                              // amber
        // The same move for red, and for the same reason: it was
        // 0xB92126 / 0xFF6B6E here and nowhere else, so the top of the ramp was
        // the one stop with no owner in the palette. It is `Ink.alarm` now.
        //
        // The new pair is also the fix for a defect the old one had. Amber and
        // red have to be told apart in a greyscale screenshot and by a
        // deuteranope, and 0xB92126 sat 1.8 L* from the light amber and
        // 0xFF6B6E 2.9 L* from the dark one — the same weight in two hues.
        // `Ink.alarm` is always the stop *further* from the ground: L* 26.53
        // against amber's 36.02 in light, 76.65 against 65.73 in dark, so the
        // gaps are 9.49 and 10.92 and "worse than amber" survives the hue going.
        default:      return Tokens.Ink.alarm                                  // red
        }
    }

}
