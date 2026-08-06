import SwiftUI
import AppKit

/// Rasterises the meter into an `NSImage` for the status bar.
///
/// `MenuBarExtra` will not reliably draw a `Shape`-based label — the glyph came
/// out blank in the menu bar while rendering correctly everywhere else. Handing
/// AppKit a finished image is what status items actually expect, and it brings
/// two things with it: a template image inherits the menu bar's own light/dark
/// and vibrancy treatment for free, and the size is exact rather than whatever
/// SwiftUI negotiates inside the status item.
@MainActor
public enum MenuBarIcon {
    /// Status bar glyphs sit in a 22pt bar; 13pt of drawing with integral width
    /// keeps the bars crisp.
    public static let height: CGFloat = 13

    private static let cache = Lock<[String: NSImage]>([:])

    /// - Parameter tint: non-nil paints the alert colour, which also means the
    ///   image can't be a template — templates are recoloured by AppKit.
    public static func image(levels: [Double], tint: Color?) -> NSImage {
        let key = cacheKey(levels: levels, tint: tint)
        if let cached = cache.withLock({ $0[key] }) { return cached }

        let glyph = UsageMeterGlyph(
            levels: levels,
            alertColor: tint,
            height: height
        )
        // Rendered in black; a template image's colour is supplied by AppKit.
        let renderer = ImageRenderer(content: glyph.foregroundStyle(.black))
        renderer.scale = 2

        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 18, height: height))
        image.isTemplate = tint == nil
        image.accessibilityDescription = "AI usage"

        cache.withLock { $0[key] = image }
        return image
    }

    /// Levels are bucketed before they reach the cache key: the meter can only
    /// show so many distinct bar heights, and a key per raw percentage would
    /// re-render on every refresh for no visible difference.
    private static func cacheKey(levels: [Double], tint: Color?) -> String {
        let bucketed = levels
            .map { Int((min(max($0, 0), 1) * 20).rounded()) }
            .sorted(by: >)
            .prefix(4)
            .map(String.init)
            .joined(separator: "-")
        return "\(bucketed)|\(tint == nil ? "mono" : "alert")"
    }
}
