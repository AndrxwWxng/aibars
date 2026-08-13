import XCTest
import SwiftUI
@testable import aibarsCore

/// Prints the metrics the shared appearance object currently resolves to, so a
/// number quoted in a comment can be checked against the one the app computes.
///
/// It asserts nothing — the print is the output — so it is gated with the other
/// harnesses on `DebugHarness` and reports skipped in an ordinary run.
final class ZZMetricsDump: XCTestCase {
    @MainActor
    func testDump() throws {
        try DebugHarness.skipUnlessAsked("print the resolved appearance metrics")

        let a = AppearanceSettings.shared
        let m = a.metrics
        print("DUMP density=\(a.density) scale=\(a.textScale) title=\(m.titleSize) detail=\(m.detailSize) caption=\(m.captionSize) figure=\(m.figureSize) unit=\(m.unitSize) bar=\(m.barHeight) contentSpacing=\(m.contentSpacing) pad=\(m.rowVerticalPadding) rail=\(m.headlineRail)")
        print("DUMP logoStyle=\(a.logoStyle) logoSize=\(a.logoSize) secondary=\(a.secondaryWindows) rowBackground=\(a.rowBackground) caution=\(a.cautionThreshold) warning=\(a.warningThreshold) meterStyle=\(a.meterStyle)")
        print("DUMP titleWeight=\(Tokens.Ramp.titleWeight) alert=\(Tokens.Ramp.alertWeight)")
    }
}
