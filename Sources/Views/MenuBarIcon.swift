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
    nonisolated public static let height: CGFloat = 13

    private static let cache = Lock<[String: NSImage]>([:])

    /// Whether the menu bar is currently dark. The menu bar follows the system
    /// appearance, which is what `effectiveAppearance` reports.
    static var isDarkMenuBar: Bool {
        NSApp?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// - Parameter colourPerBar: paint each bar by its own usage level. That
    ///   turns the glyph from "the worst service is at N%" into "here is every
    ///   service", which is the whole reason for having bars rather than a
    ///   number. A coloured image can't be a template, so AppKit stops
    ///   recolouring it — which is fine, since the colour is the point.
    public static func image(
        levels: [Double],
        tint: Color?,
        colourPerBar: Bool = true,
        height: CGFloat = MenuBarIcon.height,
        barCount: Int = 4
    ) -> NSImage {
        // With nothing reporting there is no colour to show, so the glyph goes
        // back to being a template and inherits the menu bar's own treatment.
        let coloured = colourPerBar && levels.contains { $0 > 0 }
        // Height and bar count are settings now, so they belong in the key —
        // otherwise changing either returns the previously rendered size.
        let key = cacheKey(
            levels: levels, tint: tint, coloured: coloured,
            height: height, barCount: barCount,
            // A coloured glyph bakes its neutral colour in, so a theme change
            // has to produce a different image rather than the cached one.
            dark: coloured && isDarkMenuBar
        )
        if let cached = cache.withLock({ $0[key] }) { return cached }

        // A template image is recoloured by AppKit, so black is right for it. A
        // coloured one is not, so its neutral parts have to be resolved here
        // against the menu bar's own appearance — otherwise the baseline and the
        // idle stubs render black and vanish on a dark menu bar.
        let neutral: Color = coloured ? (isDarkMenuBar ? .white : .black) : .black
        let glyph = UsageMeterGlyph(
            levels: levels,
            alertColor: tint,
            perBarColour: coloured,
            neutral: neutral,
            height: height,
            barCount: barCount
        )
        let renderer = ImageRenderer(content: glyph.foregroundStyle(neutral))
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
    private static func cacheKey(
        levels: [Double],
        tint: Color?,
        coloured: Bool,
        height: CGFloat,
        barCount: Int,
        dark: Bool
    ) -> String {
        let bucketed = levels
            .map { Int((min(max($0, 0), 1) * 20).rounded()) }
            .sorted(by: >)
            .prefix(barCount)
            .map(String.init)
            .joined(separator: "-")
        return "\(bucketed)|\(tint == nil ? "mono" : "alert")|\(coloured ? "rgb" : "tpl")|\(Int(height))|\(barCount)|\(dark ? "dark" : "light")"
    }
}

/// Publishes when the system flips between light and dark.
///
/// A coloured status image has its neutral colour baked in, so a theme change has
/// to redraw it. SwiftUI re-renders on state changes, not on appearance changes,
/// and the menu bar label has no other reason to update — so without this the
/// glyph keeps yesterday's colour until the next usage refresh.
@MainActor
public final class SystemAppearanceObserver: ObservableObject {
    public static let shared = SystemAppearanceObserver()

    @Published public private(set) var isDark: Bool

    private var observer: NSObjectProtocol?

    private init() {
        isDark = MenuBarIcon.isDarkMenuBar
        observer = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The notification arrives a beat before effectiveAppearance catches
            // up, so read it on the next turn of the loop.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.isDark = MenuBarIcon.isDarkMenuBar
                }
            }
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }
}
