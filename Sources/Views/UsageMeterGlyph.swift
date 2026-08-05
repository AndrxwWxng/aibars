import SwiftUI

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
    public let height: CGFloat
    public let barCount: Int

    public init(
        levels: [Double],
        alertColor: Color? = nil,
        alertThreshold: Double = 0.85,
        height: CGFloat = 13,
        barCount: Int = 4
    ) {
        self.levels = levels
        self.alertColor = alertColor
        self.alertThreshold = alertThreshold
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
                .fill(Color.primary.opacity(0.55))
                .frame(width: totalWidth, height: baselineHeight)
        }
        .frame(width: totalWidth, height: height, alignment: .bottom)
    }

    /// An empty bar stays as a faint stub on the axis — present, but clearly
    /// not reporting usage.
    private func fill(for level: Double) -> Color {
        guard level > 0 else { return Color.primary.opacity(0.32) }
        guard let alertColor, level >= alertThreshold else { return .primary }
        return alertColor
    }
}

/// Colour ramp shared by the meter, the usage bars, and the menu bar badge.
public enum UsageTint {
    public static func color(for percent: Double) -> Color {
        switch percent {
        case ..<0.60: return Color(hex: 0x30A46C)   // green
        case ..<0.85: return Color(hex: 0xE0A200)   // amber
        default:      return Color(hex: 0xE5484D)   // red
        }
    }

    /// Menu bar tint — nil below the threshold so the glyph stays monochrome
    /// and unobtrusive most of the time.
    public static func menuBarTint(for percent: Double) -> Color? {
        percent >= 0.85 ? color(for: percent) : nil
    }
}
