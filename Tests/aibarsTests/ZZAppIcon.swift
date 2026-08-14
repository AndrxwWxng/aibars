import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// Cuts the ten PNGs of `Assets.xcassets/AppIcon.appiconset` from `AppIconArt`.
///
/// The icon is committed as pixels, because a build cannot run a test — but it
/// is *authored* here, so nobody has to open a drawing tool to change it, and so
/// the mark on the tile stays the mark `AppMarkGeometry` describes rather than a
/// tracing of it that drifts. Run it after touching `AppIconArt`:
///
/// ```
/// xcodebuild test -scheme aibars -destination 'platform=macOS' \
///   -only-testing:aibarsTests/ZZAppIcon \
///   TEST_RUNNER_AIBARS_SNAPSHOT=1 \
///   TEST_RUNNER_AIBARS_ICON_DIR="$PWD/Resources/Assets.xcassets/AppIcon.appiconset"
/// ```
///
/// Off unless asked for, like every other `ZZ` harness: it writes files and
/// asserts nothing about them, and a CI run that rewrote the committed icon on
/// its way past would be a build step disguised as a test.
///
/// One master at 1024 and nine downsamples. Drawing each size from the vector
/// would be the more careful thing at 16 and 32 — Apple's own icons are cut per
/// size — but the mark is 1.23 times wider than it is tall and `AppMarkGeometry`
/// floors its box at 8pt, so a 16pt canvas asks the hinted grid for a mark wider
/// than the tile under it. Downsampling is also what keeps the ten images
/// recognisably one icon; `CGContext` at `.high` is a Lanczos, which is what a
/// drawing tool would use for the same job.
final class ZZAppIcon: XCTestCase {
    /// Every rung macOS asks for, as (pixels, filename). The set is
    /// 16/32/128/256/512 at 1× and 2×, which collapses to seven distinct
    /// rasters — 32, 256 and 512 are each named twice — and the catalog wants
    /// them as ten separate files.
    private static let rungs: [(pixels: Int, name: String)] = [
        (16, "icon_16x16.png"),
        (32, "icon_16x16@2x.png"),
        (32, "icon_32x32.png"),
        (64, "icon_32x32@2x.png"),
        (128, "icon_128x128.png"),
        (256, "icon_128x128@2x.png"),
        (256, "icon_256x256.png"),
        (512, "icon_256x256@2x.png"),
        (512, "icon_512x512.png"),
        (1024, "icon_512x512@2x.png")
    ]

    @MainActor
    func testWriteTheAppIcon() throws {
        try DebugHarness.skipUnlessAsked("cut the app icon from AppIconArt")

        let directory = URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["AIBARS_ICON_DIR"]
                ?? DebugHarness.outputDirectory.path)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )

        let master = try XCTUnwrap(Self.master(), "the 1024 master did not render")
        XCTAssertEqual(master.width, 1024)

        for rung in Self.rungs {
            let image = rung.pixels == master.width
                ? master
                : try XCTUnwrap(
                    Self.downsample(master, to: rung.pixels),
                    "\(rung.name) did not downsample"
                )
            let url = directory.appendingPathComponent(rung.name)
            try Self.writePNG(image, to: url)
            print("wrote \(url.path) — \(image.width)×\(image.height)")
        }
    }

    /// The 1024 master, rendered at scale 1 so that one point is one pixel and
    /// the numbers in `AppIconArt` mean what they say.
    @MainActor
    private static func master() -> CGImage? {
        let renderer = ImageRenderer(content: AppIconArt(side: 1024))
        renderer.scale = 1
        renderer.isOpaque = false
        return renderer.cgImage
    }

    /// A smaller raster of the same drawing.
    ///
    /// `.high` interpolation, and premultiplied-last on an *empty* context: the
    /// tile does not fill its canvas, so the margin has to stay transparent
    /// rather than picking up whatever the context was cleared to.
    private static func downsample(_ image: CGImage, to side: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }

    private static func writePNG(_ image: CGImage, to url: URL) throws {
        let rep = NSBitmapImageRep(cgImage: image)
        rep.size = NSSize(width: image.width, height: image.height)
        let data = try XCTUnwrap(
            rep.representation(using: .png, properties: [:]),
            "PNG encoding failed for \(url.lastPathComponent)"
        )
        try data.write(to: url)
    }
}
