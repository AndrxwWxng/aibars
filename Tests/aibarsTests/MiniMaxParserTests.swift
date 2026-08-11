import XCTest
@testable import aibarsCore

/// The shape coverage lives in `MiniMaxUsageParserTests` in ParserTests.swift.
/// This file covers the one thing that has to hold for every shape at once: the
/// window has no stated length, so the metric must carry none.
final class MiniMaxWindowDurationTests: XCTestCase {
    /// A pace notch on a made-up duration is a made-up instrument, and MiniMax
    /// is the provider where the endpoint belongs to the user rather than to
    /// aibars — there is nothing to read a length out of, in any of the shapes.
    func testNoShapeEverStatesAWindowLength() {
        let shapes: [(String, [String: Any])] = [
            ("flattened", ["used": 73, "limit": 100, "reset_at": "2026-08-02T00:00:00Z"]),
            ("nested usage", ["usage": ["primary": ["used": 12, "limit": 50]]]),
            ("nested data", ["data": ["tokens": ["used": 1_200_000, "limit": 5_000_000]]]),
            ("empty", [:])
        ]
        for (name, raw) in shapes {
            let data = MiniMaxUsageParser.parse(raw, planName: nil)
            XCTAssertNil(data.primary.windowDuration, "\(name) shape invented a window length")
            for metric in data.secondary {
                XCTAssertNil(metric.windowDuration, "\(name) shape invented a window length")
            }
        }
    }

    /// A reset date is the end of a window, not its length: knowing when the
    /// count clears says nothing about when it started, so carrying one must
    /// not tempt the parser into a duration.
    func testAResetDateDoesNotImplyALength() {
        let raw: [String: Any] = ["used": 40, "limit": 100, "reset_at": "2026-08-02T00:00:00Z"]
        let data = MiniMaxUsageParser.parse(raw, planName: "API")
        XCTAssertNotNil(data.primary.resetDate)
        XCTAssertNil(data.primary.windowDuration)
    }

    /// With no key of its own the series falls back to the normalised label,
    /// which for the nested shape is the user's own payload key.
    func testWindowKeyIsLeftToTheLabelFallback() {
        let raw: [String: Any] = [
            "data": ["Monthly Tokens": ["used": 1, "limit": 10]]
        ]
        let data = MiniMaxUsageParser.parse(raw, planName: nil)
        XCTAssertNil(data.primary.windowKey)
        XCTAssertEqual(HistorySeriesID.windowKey(for: data.primary.label), "monthly-tokens")
    }
}
