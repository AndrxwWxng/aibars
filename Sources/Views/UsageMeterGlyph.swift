import SwiftUI
import AppKit

/// The app's own mark: a small bar chart on a baseline.
///
/// Each bar is one service, tallest usage first, so a glance at the menu bar
/// tells you both how many services are near their cap and how close the worst
/// one is. The baseline is what keeps the mark legible when everything is idle —
/// without it a quiet meter is just a row of dots.
///
/// Drawn in `Color.primary` so it inherits the menu bar's light/dark treatment,
/// and tinted only on the bars that have actually crossed the threshold.
public struct UsageMeterGlyph: View {
    /// Fill levels, 0...1. Rendered tallest-first; padded to `barCount`.
    public let levels: [Double]
    /// Highlight colour, applied per bar — only bars at or above
    /// `alertThreshold` take it, so one maxed-out service doesn't make the
    /// whole meter look maxed out.
    public let alertColor: Color?
    public let alertThreshold: Double
    /// Colour every bar by its own level rather than only flagging the worst
    /// one. Four grey bars and a number tell you how bad the worst service is;
    /// they don't tell you whether that's one service or all of them.
    public let perBarColour: Bool
    /// The colour for everything that is not carrying a usage tint: the baseline
    /// and the stubs of bars with nothing to report.
    ///
    /// `Color.primary` cannot do this job here. A coloured glyph is rasterised
    /// into a non-template image, so AppKit stops recolouring it and primary
    /// resolves once — to black — which is invisible on a dark menu bar. The
    /// caller resolves it against the menu bar's actual appearance instead.
    public let neutral: Color
    public let height: CGFloat
    public let barCount: Int

    public init(
        levels: [Double],
        alertColor: Color? = nil,
        alertThreshold: Double = 0.85,
        perBarColour: Bool = false,
        neutral: Color = .primary,
        height: CGFloat = 13,
        barCount: Int = 4
    ) {
        self.levels = levels
        self.alertColor = alertColor
        self.alertThreshold = alertThreshold
        self.perBarColour = perBarColour
        self.neutral = neutral
        self.height = height
        self.barCount = barCount
    }

    private var normalized: [Double] {
        let sorted = levels.map { min(max($0, 0), 1) }.sorted(by: >)
        return (0..<barCount).map { $0 < sorted.count ? sorted[$0] : 0 }
    }

    // Everything scales off `height` so the same mark works at 13pt in the menu
    // bar and at 44pt in the About pane.
    private var barWidth: CGFloat { max(2, (height * 0.23).rounded()) }
    private var spacing: CGFloat { max(1.5, height * 0.14) }
    private var baselineHeight: CGFloat { max(1, (height * 0.09).rounded()) }
    private var plotHeight: CGFloat { height - baselineHeight - max(1, height * 0.11) }
    private var stubHeight: CGFloat { max(1.5, height * 0.14) }
    private var totalWidth: CGFloat {
        CGFloat(barCount) * barWidth + CGFloat(barCount - 1) * spacing
    }

    public var body: some View {
        VStack(spacing: max(1, height * 0.11)) {
            HStack(alignment: .bottom, spacing: spacing) {
                ForEach(Array(normalized.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: barWidth * 0.4, style: .continuous)
                        .fill(fill(for: level))
                        .frame(width: barWidth, height: max(stubHeight, plotHeight * level))
                }
            }
            .frame(height: plotHeight, alignment: .bottom)

            RoundedRectangle(cornerRadius: baselineHeight / 2, style: .continuous)
                .fill(neutral.opacity(0.55))
                .frame(width: totalWidth, height: baselineHeight)
        }
        .frame(width: totalWidth, height: height, alignment: .bottom)
        // The status item rasterises this view through `ImageRenderer`, which
        // draws in the light appearance whatever the menu bar is doing — so the
        // usage ramp would bake its light-panel colours into a dark menu bar.
        // Pinning the scheme to the app's own appearance is a no-op everywhere
        // the glyph is drawn as a live view.
        .environment(\.colorScheme, MenuBarIcon.isDarkMenuBar ? .dark : .light)
    }

    /// An empty bar stays as a faint stub on the axis — present, but clearly
    /// not reporting usage.
    private func fill(for level: Double) -> Color {
        guard level > 0 else { return neutral.opacity(0.32) }
        if perBarColour { return UsageTint.color(for: level) }
        guard let alertColor, level >= alertThreshold else { return neutral }
        return alertColor
    }
}

/// Colour ramp shared by the meter, the usage bars, and the menu bar badge.
public enum UsageTint {
    public static func color(for percent: Double) -> Color {
        switch percent {
        case ..<0.60: return ramp(light: 0x136F41, dark: 0x30A46C)   // green
        case ..<0.85: return ramp(light: 0x8F6100, dark: 0xE0A200)   // amber
        default:      return ramp(light: 0xC62A2F, dark: 0xE5484D)   // red
        }
    }

    /// One stop on the ramp, resolved against the appearance it is drawn in.
    ///
    /// The ramp is also the text colour for the percentage readouts, and one
    /// fixed value cannot serve both appearances: the dark values sit at
    /// 2.2:1–3.9:1 on a light panel, well under the 4.5:1 that body text needs.
    /// The dark values are the originals; the light ones are the same hues
    /// darkened until they clear it.
    private static func ramp(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green:   CGFloat((hex >>  8) & 0xFF) / 255,
                blue:    CGFloat( hex        & 0xFF) / 255,
                alpha:   1
            )
        })
    }

    /// Menu bar tint — nil below the threshold so the glyph stays monochrome
    /// and unobtrusive most of the time.
    public static func menuBarTint(for percent: Double) -> Color? {
        percent >= 0.85 ? color(for: percent) : nil
    }
}
