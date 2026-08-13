import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// The panel's one horizontal contract: **nothing the panel draws may fall
/// outside the panel.**
///
/// It is not a nicety. `MenuBarContentView` draws its ground at
/// `.frame(width: panelWidth)`, and a SwiftUI frame does not clip — a subview
/// whose *minimum* width exceeds the proposal is laid out at that minimum and
/// centred, so it draws outside the ground on both sides and `MenuBarExtra`
/// then sizes its window to the overflowing content. Worse, every row in the
/// list shares one `VStack` and each row is `.frame(maxWidth: .infinity)`: a
/// single service with a wide caption drags *every other row* off-centre with
/// it. One bad row is a broken panel, which is exactly how it shipped.
///
/// Asserted in pixels rather than in points, and that is deliberate. The
/// obvious measurement — `NSHostingView.fittingSize` — cannot answer this
/// question from either end. Asked of the panel it returns `panelWidth`,
/// because the outer `.frame(width:)` fixes it whatever the content underneath
/// is doing. Asked of a bare row it over-reports, because `fittingSize` does
/// not resolve a `ViewThatFits` the way a real layout pass does, and both the
/// header's summary and a row's identity run are `ViewThatFits`. So the panel
/// is drawn into a canvas wider than itself and the margins are inspected: ink
/// outside the ground is content that escaped, and nothing else is.
final class PanelWidthContractTests: XCTestCase {

    /// How much clear canvas is left on each side of the panel. Wide enough to
    /// catch the escape rather than to contain it — the shipped defect put
    /// roughly 125pt past each edge.
    private static let margin: CGFloat = 200

    /// The panel widths a user can set, including both ends of the slider.
    private static let widths: [Double] = [300, 356, 420, 520]

    /// The text-size slider's two ends and the shipped value between them.
    ///
    /// Swept with the widths rather than left at 100%, because every reserved
    /// width in the row is a multiple of a type size and the text column is not:
    /// at 130% the figure rails, the chip runs and the spend all grow while the
    /// panel stays where the user put it, so a 300pt panel at 130% is the
    /// narrowest line the app can be asked to fit anything on. It is also the
    /// only combination that drives `chipLimit` down to its floor, which is the
    /// one branch where the reservation is not simply a division.
    private static let scales: [Double] = [0.85, 1.0, 1.30]

    // MARK: - The contract

    @MainActor
    func testNothingDrawsOutsideThePanel() throws {
        let appearance = AppearanceSettings.shared
        let originalWidth = appearance.panelWidth
        let originalScale = appearance.textScale
        defer {
            appearance.panelWidth = originalWidth
            appearance.textScale = originalScale
        }

        let state = Self.pathologicalState()
        var failures: [String] = []

        for width in Self.widths {
            for scale in Self.scales {
                appearance.panelWidth = width
                appearance.textScale = scale
                let panel = MenuBarContentView(
                    state: state,
                    showSettings: .constant(false),
                    appearance: appearance
                )
                if let escape = Self.inkOutside(AnyView(panel), panelWidth: CGFloat(width)) {
                    failures.append(String(
                        format: "%.0fpt panel at %.0f%% type: ink %.0fpt outside the ground (%@ edge)",
                        width, scale * 100, escape.overhang, escape.edge
                    ))
                }
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "content escaped the panel ground:\n" + failures.joined(separator: "\n")
        )
    }

    /// The same contract one row at a time.
    ///
    /// A separate test because the panel-level one cannot see this: the list
    /// sits in a `ScrollView`, which *does* clip, so an over-wide row is hidden
    /// rather than drawn outside the window. It is not harmless — the row is
    /// laid out at its own minimum and centred inside the clip, so the whole
    /// list shifts leading-ward and loses its brand marks off one edge and its
    /// figures off the other, which is precisely the reported defect. Measured
    /// here without the scroll view, where the overflow has nowhere to hide.
    @MainActor
    func testNoRowDrawsOutsideItsPanelWidth() throws {
        let appearance = AppearanceSettings.shared
        let originalWidth = appearance.panelWidth
        let originalScale = appearance.textScale
        defer {
            appearance.panelWidth = originalWidth
            appearance.textScale = originalScale
        }

        let state = Self.pathologicalState()
        var failures: [String] = []

        for width in Self.widths {
            for scale in Self.scales {
                appearance.panelWidth = width
                appearance.textScale = scale
                for provider in state.providers where provider.isAuthenticated {
                    let row = ProviderRow(
                        provider: provider,
                        result: state.snapshots[provider.id],
                        onSignIn: {},
                        appearance: appearance
                    )
                    .frame(width: CGFloat(width))

                    if let escape = Self.inkOutside(AnyView(row), panelWidth: CGFloat(width)) {
                        failures.append(String(
                            format: "%.0fpt panel at %.0f%% type: %@ draws %.0fpt past the %@ edge",
                            width, scale * 100, provider.serviceID, escape.overhang, escape.edge
                        ))
                    }
                }
            }
        }

        XCTAssertTrue(
            failures.isEmpty,
            "rows escape the panel width:\n" + failures.joined(separator: "\n")
        )
    }

    // MARK: - Fixtures

    /// Every payload shape that has ever been able to widen a row, in one
    /// panel: token windows with no ceiling, a four-figure spend, three
    /// percentage windows with long names, and a sixty-character work address.
    ///
    /// Taken from what providers really send rather than invented.
    /// `ClaudeCodeProvider` reports `Today`, `7 days` and `30 days` at
    /// `limit: 0` with token counts in them — a seven-character label beside a
    /// nine-character reading, against a chip estimate that reserves four and
    /// seven.
    @MainActor
    static func pathologicalState() -> AppState {
        let state = AppState()
        let now = Date()

        if let claudeCode = state.providers.first(where: { $0.serviceID == "claudecode" }) {
            claudeCode.isAuthenticated = true
            state.snapshots[claudeCode.id] = .success(UsageData(
                providerID: claudeCode.id,
                primary: UsageMetric(label: "Spend", used: 0, limit: 0, unit: nil),
                secondary: [
                    UsageMetric(label: "Today", used: 644_600_000, limit: 0, unit: "tokens"),
                    UsageMetric(label: "7 days", used: 4_334_500_000, limit: 0, unit: "tokens"),
                    UsageMetric(label: "30 days", used: 9_767_200_000, limit: 0, unit: "tokens")
                ],
                spend: SpendReport(
                    amountMinor: 870_047, currency: "USD", exponent: 2,
                    period: .month, confidence: .estimated
                )
            ))
        }

        if let claude = state.providers.first(where: { $0.serviceID == "claude" }) {
            claude.isAuthenticated = true
            state.snapshots[claude.id] = .success(UsageData(
                providerID: claude.id,
                planName: "Max 20x",
                primary: UsageMetric(
                    label: "5h session", used: 92, limit: 100, unit: "%",
                    resetDate: now.addingTimeInterval(4_800)
                ),
                secondary: [
                    UsageMetric(label: "Weekly · all models", used: 61, limit: 100, unit: "%"),
                    UsageMetric(label: "Weekly · Opus", used: 88, limit: 100, unit: "%"),
                    UsageMetric(label: "Weekly · per-model", used: 12, limit: 100, unit: "%")
                ],
                accountLabel: "ada.lovelace.engineering@verylongcompanyname.example.com"
            ))
        }

        state.lastRefresh = now.addingTimeInterval(-12)
        return state
    }

    // MARK: - Measurement

    /// The panel drawn into a canvas `2 * margin` wider than itself, with the
    /// margins scanned for ink.
    ///
    /// Returns nil when both margins are clear. Otherwise the further of the
    /// two overhangs, in points, and which edge it ran past.
    @MainActor
    private static func inkOutside(
        _ panel: AnyView,
        panelWidth: CGFloat
    ) -> (overhang: CGFloat, edge: String)? {
        // The panel is placed in a transparent canvas rather than given one of
        // its own grounds, so "is there ink here" is a question about alpha and
        // needs no colour comparison — and so the test cannot be fooled by a
        // palette change.
        let canvas = panel
            .frame(width: panelWidth + 2 * margin, alignment: .center)

        let host = NSHostingView(rootView: AnyView(canvas.environment(\.colorScheme, .dark)))
        host.appearance = NSAppearance(named: .darkAqua)
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // One run-loop turn, not a wall-clock wait. A hosting view laid out
        // this turn has not resolved its content yet and the bitmap comes back
        // as the pre-layout frame; a `0.4` sleep did the job by accident and
        // cost eleven seconds across the twenty-eight renders this suite makes.
        RunLoop.current.run(mode: .default, before: Date())

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return nil }
        host.cacheDisplay(in: host.bounds, to: rep)

        let scale = CGFloat(rep.pixelsWide) / size.width
        // A hair inside the margin, so a rounded corner's own antialiasing on
        // the ground's edge is not read as an escape.
        let slack: CGFloat = 1
        let leftEdge = Int(((margin - slack) * scale).rounded(.down))
        let rightEdge = Int(((margin + panelWidth + slack) * scale).rounded(.up))

        var worstLeft: Int?
        var worstRight: Int?

        for y in stride(from: 0, to: rep.pixelsHigh, by: 2) {
            for x in 0..<max(0, leftEdge) where rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.02 {
                if worstLeft == nil || x < worstLeft! { worstLeft = x }
            }
            for x in min(rightEdge, rep.pixelsWide)..<rep.pixelsWide
            where rep.colorAt(x: x, y: y)?.alphaComponent ?? 0 > 0.02 {
                if worstRight == nil || x > worstRight! { worstRight = x }
            }
        }

        let leftOverhang = worstLeft.map { (CGFloat(leftEdge - $0)) / scale } ?? 0
        let rightOverhang = worstRight.map { (CGFloat($0 - rightEdge)) / scale } ?? 0
        if leftOverhang <= 0 && rightOverhang <= 0 { return nil }
        return leftOverhang >= rightOverhang
            ? (leftOverhang, "leading")
            : (rightOverhang, "trailing")
    }
}
