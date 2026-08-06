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

    /// - Parameter colourPerBar: paint each bar by its own usage level. That
    ///   turns the glyph from "the worst service is at N%" into "here is every
    ///   service", which is the whole reason for having bars rather than a
    ///   number. A coloured image can't be a template, so AppKit stops
    ///   recolouring it — which is fine, since the colour is the point.
    public static func image(levels: [Double], tint: Color?, colourPerBar: Bool = true) -> NSImage {
        // With nothing reporting there is no colour to show, so the glyph goes
        // back to being a template and inherits the menu bar's own treatment.
        let coloured = colourPerBar && levels.contains { $0 > 0 }
        let key = cacheKey(levels: levels, tint: tint, coloured: coloured)
        if let cached = cache.withLock({ $0[key] }) { return cached }

        let glyph = UsageMeterGlyph(
            levels: levels,
            alertColor: tint,
            perBarColour: coloured,
            height: height
        )
        // Rendered in black; a template image's colour is supplied by AppKit.
        let renderer = ImageRenderer(content: glyph.foregroundStyle(.black))
        renderer.scale = 2

        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 18, height: height))
        image.isTemplate = !coloured
        image.accessibilityDescription = "AI usage"

        cache.withLock { $0[key] = image }
        return image
    }

    /// Levels are bucketed before they reach the cache key: the meter can only
    /// show so many distinct bar heights, and a key per raw percentage would
    /// re-render on every refresh for no visible difference.
    private static func cacheKey(levels: [Double], tint: Color?, coloured: Bool) -> String {
        let bucketed = levels
            .map { Int((min(max($0, 0), 1) * 20).rounded()) }
            .sorted(by: >)
            .prefix(4)
            .map(String.init)
            .joined(separator: "-")
        return "\(bucketed)|\(tint == nil ? "mono" : "alert")|\(coloured ? "rgb" : "tpl")"
    }
}
