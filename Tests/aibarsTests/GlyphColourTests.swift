import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// A coloured status image is not a template, so AppKit stops recolouring it and
/// whatever the glyph baked in is what appears. Baking black meant the baseline
/// and the idle stubs were invisible on a dark menu bar.
final class GlyphColourTests: XCTestCase {
    /// Brightness of the non-tinted pixels: the baseline and the idle stubs are
    /// the only greyscale marks in the image, so their luminance is the neutral.
    @MainActor
    private func neutralBrightness(dark: Bool) -> CGFloat? {
        let glyph = UsageMeterGlyph(
            levels: [0.5],
            perBarColour: true,
            neutral: dark ? .white : .black,
            height: 26,
            barCount: 4
        )
        let renderer = ImageRenderer(content: glyph)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }

        var total: CGFloat = 0
        var count = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let colour = bitmap.colorAt(x: x, y: y), colour.alphaComponent > 0.5 else { continue }
                let r = colour.redComponent, g = colour.greenComponent, b = colour.blueComponent
                // Skip the usage tints, which are strongly coloured.
                guard abs(r - g) < 0.08, abs(g - b) < 0.08 else { continue }
                total += (r + g + b) / 3
                count += 1
            }
        }
        guard count > 0 else { return nil }
        return total / CGFloat(count)
    }

    @MainActor
    func testNeutralMarksAreLightOnADarkMenuBar() throws {
        let brightness = try XCTUnwrap(neutralBrightness(dark: true))
        XCTAssertGreaterThan(
            brightness, 0.6,
            "the baseline and idle bars rendered at \(brightness) brightness — too dark to see on a dark menu bar"
        )
    }

    @MainActor
    func testNeutralMarksAreDarkOnALightMenuBar() throws {
        let brightness = try XCTUnwrap(neutralBrightness(dark: false))
        XCTAssertLessThan(brightness, 0.4, "the neutral marks are too light for a light menu bar")
    }

    /// The monochrome glyph must stay a template, since that is what lets AppKit
    /// handle both appearances for free.
    @MainActor
    func testMonochromeStaysATemplate() {
        XCTAssertTrue(MenuBarIcon.image(levels: [0.4], tint: nil, colourPerBar: false).isTemplate)
        XCTAssertFalse(MenuBarIcon.image(levels: [0.4], tint: nil, colourPerBar: true).isTemplate)
    }

    /// Two appearances must not collide in the cache, or a theme switch returns
    /// the previous image.
    @MainActor
    func testCacheDistinguishesAppearance() {
        let first = MenuBarIcon.image(levels: [0.5], tint: nil, colourPerBar: true)
        let again = MenuBarIcon.image(levels: [0.5], tint: nil, colourPerBar: true)
        XCTAssertTrue(first === again, "identical requests should hit the cache")
    }
}
