import XCTest
import SwiftUI
@testable import aibarsCore

/// The menu bar icon came out blank because `MenuBarExtra` won't draw a
/// Shape-based label. It's a rasterised image now, and "the image has visible
/// pixels" is the one property that failure would have violated.
final class MenuBarIconTests: XCTestCase {
    @MainActor
    func testIconHasVisiblePixelsAtEveryUsageLevel() throws {
        for levels in [[], [0.05], [0.5], [0.9, 0.6, 0.3, 0.1]] {
            let image = MenuBarIcon.image(levels: levels, tint: nil)
            XCTAssertGreaterThan(image.size.width, 0, "zero-width icon for \(levels)")
            XCTAssertGreaterThan(image.size.height, 0, "zero-height icon for \(levels)")
            XCTAssertGreaterThan(
                opaquePixels(in: image), 20,
                "icon for \(levels) is effectively blank"
            )
        }
    }

    /// Colour is what makes the glyph say "one service is red and the rest are
    /// fine" instead of just "the worst one is at N%", and AppKit repaints
    /// template images — so an icon carrying usage must not be one.
    @MainActor
    func testIconWithUsageKeepsItsColour() {
        XCTAssertFalse(MenuBarIcon.image(levels: [0.4], tint: nil).isTemplate)
        XCTAssertFalse(MenuBarIcon.image(levels: [0.95], tint: .red).isTemplate)
    }

    /// Nothing reporting means no colour to keep, so the glyph goes back to
    /// being a template and inherits the menu bar's own light/dark treatment.
    @MainActor
    func testIdleIconIsATemplate() {
        XCTAssertTrue(MenuBarIcon.image(levels: [], tint: nil).isTemplate)
        XCTAssertTrue(MenuBarIcon.image(levels: [0, 0], tint: nil).isTemplate)
        // And the caller can always ask for the monochrome version.
        XCTAssertTrue(MenuBarIcon.image(levels: [0.4], tint: nil, colourPerBar: false).isTemplate)
    }

    @MainActor
    func testIconFitsTheMenuBar() {
        let image = MenuBarIcon.image(levels: [0.9, 0.5], tint: nil)
        XCTAssertLessThanOrEqual(image.size.height, 16, "taller than the status bar allows")
        XCTAssertLessThanOrEqual(image.size.width, 26, "wider than a status glyph should be")
    }

    private func opaquePixels(in image: NSImage) -> Int {
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return 0 }
        var count = 0
        for x in 0..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                if let colour = bitmap.colorAt(x: x, y: y), colour.alphaComponent > 0.05 {
                    count += 1
                }
            }
        }
        return count
    }
}

final class SessionStoreTests: XCTestCase {
    private let a = "session-store-test-a"
    private let b = "session-store-test-b"

    override func tearDown() {
        SessionStore.shared.clear(a)
        SessionStore.shared.clear(b)
        super.tearDown()
    }

    /// All tokens share one Keychain item now, so the round trip has to keep
    /// providers from overwriting each other.
    func testMultipleProvidersShareOneItemWithoutClobbering() throws {
        let store = SessionStore.shared
        try store.setToken("alpha", for: a)
        try store.setToken("beta", for: b)

        XCTAssertEqual(store.token(for: a), "alpha")
        XCTAssertEqual(store.token(for: b), "beta")

        store.invalidateCache()
        XCTAssertEqual(store.token(for: a), "alpha", "lost after a reload")
        XCTAssertEqual(store.token(for: b), "beta", "lost after a reload")

        store.clear(a)
        store.invalidateCache()
        XCTAssertNil(store.token(for: a))
        XCTAssertEqual(store.token(for: b), "beta", "clearing one dropped the other")
    }

    func testMetadataTracksCredentialsWithoutReadingTheKeychain() throws {
        let store = SessionStore.shared
        XCTAssertFalse(store.hasCredential(for: a))
        try store.setToken("alpha", for: a)
        XCTAssertTrue(store.hasCredential(for: a))
        store.clear(a)
        XCTAssertFalse(store.hasCredential(for: a))
    }
}
