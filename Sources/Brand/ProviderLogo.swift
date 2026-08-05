import SwiftUI

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
    var luminance: Double {
        func channel(_ raw: UInt32) -> Double {
            let v = Double(raw) / 255
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel((hex >> 16) & 0xFF)
             + 0.7152 * channel((hex >> 8) & 0xFF)
             + 0.0722 * channel(hex & 0xFF)
    }

    /// The colour to draw the glyph in for a given appearance.
    func foreground(dark: Bool) -> Color {
        if dark && luminance < 0.22 { return Color(hex: 0xF2F2F2) }
        if !dark && luminance > 0.78 { return Color(hex: hex).opacity(0.85) }
        return Color(hex: hex)
    }

    /// The colour of the rounded tile behind the glyph. Brands that are
    /// essentially black would tint to nothing, so those fall back to a
    /// neutral wash.
    func tile(dark: Bool) -> Color {
        if luminance < 0.06 { return Color.primary.opacity(dark ? 0.10 : 0.07) }
        return Color(hex: hex, opacity: dark ? 0.22 : 0.15)
    }
}

/// A provider's logo in a rounded tile.
///
/// Prefers a bundled asset named `logo-<providerID>` when one exists, so a
/// brand's official artwork can be dropped in without a code change; falls
/// back to the vector mark, then to a lettermark for unknown providers.
public struct ProviderLogo: View {
    @Environment(\.colorScheme) private var colorScheme

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
            if showsTile {
                RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                    .fill(mark?.tile(dark: isDark) ?? fallbackColor.opacity(0.16))
                    .overlay(
                        RoundedRectangle(cornerRadius: size * 0.29, style: .continuous)
                            .strokeBorder(Color.primary.opacity(isDark ? 0.08 : 0.05), lineWidth: 0.5)
                    )
            }
            glyph
                .frame(width: size * 0.56, height: size * 0.56)
        }
        .frame(width: size, height: size)
        .accessibilityLabel(fallbackName)
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
            Text(String(fallbackName.prefix(1)).uppercased())
                .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
                .foregroundStyle(fallbackColor)
        }
    }
}
