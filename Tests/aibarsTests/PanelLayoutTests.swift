import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// The panel has to ask for a sensible height on its own.
///
/// `MenuBarExtra` sizes its window to whatever the content requests, and a
/// `ScrollView` requests nothing — so the panel shipped as a 51pt strip
/// containing only the header, with the list collapsed to zero. Every snapshot
/// I took looked right because the harness handed the hosting view an explicit
/// frame, which is exactly the thing the real window does not do. These tests
/// measure the intrinsic size, with nothing imposed.
final class PanelLayoutTests: XCTestCase {
    @MainActor
    private func panel(connected: Int) -> NSHostingView<AnyView> {
        let state = AppState()
        for (index, provider) in state.providers.prefix(connected).enumerated() {
            provider.isAuthenticated = true
            state.snapshots[provider.id] = .success(
                UsageData(
                    providerID: provider.id,
                    planName: "Pro",
                    primary: UsageMetric(label: "5h window", used: Double(index * 10), limit: 100, unit: "%"),
                    secondary: [UsageMetric(label: "Weekly", used: 40, limit: 100, unit: "%")]
                )
            )
        }
        let view = MenuBarContentView(state: state, showSettings: .constant(false))
            .environmentObject(state)
        return NSHostingView(rootView: AnyView(view))
    }

    @MainActor
    func testPanelAsksForEnoughHeightToShowItsRows() {
        let host = panel(connected: 3)
        let height = host.fittingSize.height
        XCTAssertGreaterThan(
            height, 200,
            "the panel only asked for \(height)pt — the list has collapsed and the window will show the header alone"
        )
    }

    @MainActor
    func testTallerContentAsksForMoreRoom() {
        let short = panel(connected: 1).fittingSize.height
        let tall = panel(connected: 4).fittingSize.height
        XCTAssertGreaterThan(tall, short, "height doesn't track the number of rows")
    }

    /// And it has to stop somewhere, or a long list runs off the screen instead
    /// of scrolling. The ceiling follows the display rather than a fixed number,
    /// so the invariant is "fits on screen with room for the menu bar", not any
    /// particular height.
    @MainActor
    func testHeightStaysOnScreen() {
        let available = NSScreen.main?.visibleFrame.height ?? 800
        let host = panel(connected: 9)
        XCTAssertLessThanOrEqual(host.fittingSize.height, available - 60)
    }

    @MainActor
    func testWidthIsFixed() {
        XCTAssertEqual(panel(connected: 3).fittingSize.width, 356)
    }
}
