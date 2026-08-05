import XCTest
import SwiftUI
@testable import aibarsCore

final class SVGPathTests: XCTestCase {
    func testParsesAbsoluteAndRelativeCommands() {
        // A 10x10 square drawn with a relative line-to and an implicit repeat.
        let path = SVGPath.cgPath(from: "M0 0 h10 v10 H0 Z")
        XCTAssertEqual(path.boundingBox.width, 10, accuracy: 0.001)
        XCTAssertEqual(path.boundingBox.height, 10, accuracy: 0.001)
    }

    func testImplicitLineToAfterMoveTo() {
        // Extra coordinate pairs after an `M` are line-tos, not more move-tos.
        let path = SVGPath.cgPath(from: "M0 0 5 0 5 5")
        XCTAssertFalse(path.isEmpty)
        XCTAssertEqual(path.boundingBox.maxX, 5, accuracy: 0.001)
    }

    func testOmittedSeparatorsBeforeMinusAndDecimal() {
        let path = SVGPath.cgPath(from: "M0 0l2.5.5-1.5 1")
        XCTAssertEqual(path.boundingBox.maxX, 2.5, accuracy: 0.001)
        XCTAssertEqual(path.boundingBox.maxY, 1.5, accuracy: 0.001)
    }

    func testArcProducesRoundedGeometry() {
        // Half-circle of radius 5 from (0,0) to (10,0): the sweep should bulge
        // 5 units away from the chord.
        let path = SVGPath.cgPath(from: "M0 0 A5 5 0 0 1 10 0")
        XCTAssertEqual(path.boundingBox.width, 10, accuracy: 0.01)
        XCTAssertEqual(path.boundingBox.height, 5, accuracy: 0.01)
    }

    func testPackedArcFlags() {
        // Optimisers emit flags jammed against the following number.
        let packed = SVGPath.cgPath(from: "M0 0a5 5 0 015 5")
        let spaced = SVGPath.cgPath(from: "M0 0a5 5 0 0 1 5 5")
        XCTAssertEqual(packed.boundingBox.width, spaced.boundingBox.width, accuracy: 0.001)
        XCTAssertEqual(packed.boundingBox.height, spaced.boundingBox.height, accuracy: 0.001)
    }
}

final class BrandMarkTests: XCTestCase {
    /// Services with no published single-path logo. These fall back to a
    /// lettermark, which is deliberate — better an honest initial than a
    /// hand-drawn approximation of someone's trademark.
    private static let withoutMarks: Set<String> = ["grok"]

    @MainActor
    func testEveryRegisteredProviderHasAMarkOrIsExempt() {
        for provider in AppState().providers {
            if Self.withoutMarks.contains(provider.id) {
                XCTAssertNil(
                    BrandMark.mark(for: provider.id),
                    "\(provider.id) now has a mark — drop it from the exempt list"
                )
            } else {
                XCTAssertNotNil(BrandMark.mark(for: provider.id), "missing brand mark for \(provider.id)")
            }
        }
    }

    /// Guards against a path that silently fails to parse (empty), or one that
    /// parses into nonsense far outside its declared view box.
    func testMarksFillTheirViewBox() throws {
        for mark in BrandMark.all {
            let path = SVGPath.cgPath(from: mark.pathData)
            XCTAssertFalse(path.isEmpty, "\(mark.providerID) produced an empty path")

            let box = path.boundingBox
            XCTAssertGreaterThan(box.width, mark.viewBox.width * 0.5, "\(mark.providerID) is too narrow")
            XCTAssertGreaterThan(box.height, mark.viewBox.height * 0.5, "\(mark.providerID) is too short")
            XCTAssertGreaterThanOrEqual(box.minX, -0.5, "\(mark.providerID) overflows left")
            XCTAssertGreaterThanOrEqual(box.minY, -0.5, "\(mark.providerID) overflows top")
            XCTAssertLessThanOrEqual(box.maxX, mark.viewBox.width + 0.5, "\(mark.providerID) overflows right")
            XCTAssertLessThanOrEqual(box.maxY, mark.viewBox.height + 0.5, "\(mark.providerID) overflows bottom")
        }
    }

    func testNearBlackMarksFlipToLightOnDarkBackgrounds() throws {
        let openAI = try XCTUnwrap(BrandMark.mark(for: "chatgpt"))
        XCTAssertLessThan(openAI.luminance, 0.22)
        XCTAssertNotEqual(openAI.foreground(dark: true), Color(hex: openAI.hex))
        XCTAssertEqual(openAI.foreground(dark: false), Color(hex: openAI.hex))

        let claude = try XCTUnwrap(BrandMark.mark(for: "claude"))
        XCTAssertEqual(claude.foreground(dark: true), Color(hex: claude.hex))
    }
}

final class CountdownTests: XCTestCase {
    func testFormats() {
        let now = Date()
        XCTAssertEqual(Countdown.short(until: now.addingTimeInterval(45), from: now), "45s")
        XCTAssertEqual(Countdown.short(until: now.addingTimeInterval(90), from: now), "1m")
        XCTAssertEqual(Countdown.short(until: now.addingTimeInterval(3600 * 3 + 720), from: now), "3h 12m")
        XCTAssertEqual(Countdown.short(until: now.addingTimeInterval(86400 * 2 + 3600 * 4), from: now), "2d 4h")
        XCTAssertNil(Countdown.short(until: now.addingTimeInterval(-5), from: now))
    }
}
