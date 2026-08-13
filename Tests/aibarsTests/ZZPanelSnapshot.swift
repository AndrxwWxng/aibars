import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// Renders the whole panel — header, rule, group headers, every row state — to
/// a PNG, so a change to the panel can be looked at rather than reasoned about.
///
/// The harness that was here before this one drew six bare rows on a flat
/// `Surface.base`, which is the one thing in the window that cannot show the
/// bug it was needed for: the panel's ground is drawn by
/// `MenuBarContentView` at `.frame(width: panelWidth)`, and the defect the user
/// reported is content escaping *that* frame. A row rendered on its own has no
/// frame to escape.
///
/// Off unless asked for. It writes files and spends about a second per
/// appearance, and CI has nothing to do with the output — so it is gated on
/// `AIBARS_SNAPSHOT=1` rather than on a name convention, and reports skipped
/// otherwise.
final class ZZPanelSnapshot: XCTestCase {

    private static var outputDirectory: URL {
        URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["AIBARS_SNAPSHOT_DIR"] ?? "/tmp")
    }

    private static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["AIBARS_SNAPSHOT"] == "1"
    }

    @MainActor
    func testWritePanelSnapshot() throws {
        try XCTSkipUnless(Self.isEnabled, "set AIBARS_SNAPSHOT=1 to write panel PNGs")

        let state = Self.populatedState()
        for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            let view = MenuBarContentView(
                state: state,
                showSettings: .constant(false),
                appearance: AppearanceSettings.shared
            )
            try Self.write(
                AnyView(view),
                to: "aibars_panel_\(name).png",
                scheme: scheme
            )
        }
    }

    /// The panel at both extremes of its width slider, which is where a
    /// reserved-width contract breaks first.
    @MainActor
    func testWritePanelWidthExtremes() throws {
        try XCTSkipUnless(Self.isEnabled, "set AIBARS_SNAPSHOT=1 to write panel PNGs")

        let appearance = AppearanceSettings.shared
        let original = appearance.panelWidth
        defer { appearance.panelWidth = original }

        let state = Self.populatedState()
        for width in [300.0, 520.0] {
            appearance.panelWidth = width
            let view = MenuBarContentView(
                state: state,
                showSettings: .constant(false),
                appearance: appearance
            )
            try Self.write(
                AnyView(view),
                to: "aibars_panel_w\(Int(width)).png",
                scheme: .dark
            )
        }
    }

    // MARK: - Fixtures

    /// A panel carrying one row of every kind the app can draw, with the
    /// payloads real providers actually send.
    ///
    /// Claude Code's three windows are the interesting ones and they are copied
    /// from `ClaudeCodeProvider` rather than invented: it reports `Today`,
    /// `7 days` and `30 days` at `limit: 0` with token counts in them, which is
    /// the exact shape that overflows the panel — a seven-character label and a
    /// nine-character reading against a chip estimate that reserves four and
    /// seven.
    @MainActor
    static func populatedState() -> AppState {
        let state = AppState()
        let now = Date()

        func provider(_ id: String) -> AnyUsageProvider? {
            state.providers.first { $0.serviceID == id }
        }

        // Codex — a metered service on a free plan, read from Firefox.
        if let codex = provider("codex") {
            codex.isAuthenticated = true
            codex.browserOrigin = "Firefox"
            state.snapshots[codex.id] = .success(UsageData(
                providerID: codex.id,
                planName: "Free",
                primary: UsageMetric(
                    label: "30d window", used: 0, limit: 100, unit: "%",
                    resetDate: now.addingTimeInterval(29 * 86_400 + 23 * 3_600)
                ),
                secondary: [UsageMetric(label: "Credits", used: 0, limit: 0, unit: nil)]
            ))
        }

        // Cursor — a long work address, which is what squeezes the title line.
        if let cursor = provider("cursor") {
            cursor.isAuthenticated = true
            state.snapshots[cursor.id] = .success(UsageData(
                providerID: cursor.id,
                planName: "Pro",
                primary: UsageMetric(
                    label: "Requests", used: 320, limit: 500, unit: nil,
                    resetDate: now.addingTimeInterval(8 * 86_400 + 16 * 3_600)
                ),
                accountLabel: "andrewwang123118@gmail.com"
            ))
        }

        // Claude Code — the overflow case: a four-figure spend beside three
        // token windows with no ceiling.
        if let claudeCode = provider("claudecode") {
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
                    amountMinor: 870_047,
                    currency: "USD",
                    exponent: 2,
                    period: .month,
                    confidence: .estimated
                )
            ))
        }

        // Claude — the row the panel is usually about: near cap, with a weekly
        // window riding the caption line.
        if let claude = provider("claude") {
            claude.isAuthenticated = true
            state.snapshots[claude.id] = .success(UsageData(
                providerID: claude.id,
                planName: "Max 20x",
                primary: UsageMetric(
                    label: "5h session", used: 92, limit: 100, unit: "%",
                    resetDate: now.addingTimeInterval(4_800)
                ),
                secondary: [
                    UsageMetric(label: "Weekly", used: 61, limit: 100, unit: "%",
                                resetDate: now.addingTimeInterval(2 * 86_400)),
                    UsageMetric(label: "Opus weekly", used: 12, limit: 100, unit: "%")
                ],
                accountLabel: "work"
            ))
        }

        // ChatGPT — reports a state rather than a quota.
        if let chatgpt = provider("chatgpt") {
            chatgpt.isAuthenticated = true
            state.snapshots[chatgpt.id] = .success(UsageData(
                providerID: chatgpt.id,
                planName: "Plus",
                primary: UsageMetric(label: "Subscription active", used: 0, limit: 0, unit: nil)
            ))
        }

        // OpenCode — connected and answering nothing yet.
        if let openCode = provider("opencode") {
            openCode.isAuthenticated = true
            state.snapshots[openCode.id] = nil
        }

        // Grok — connected and failing.
        if let grok = provider("grok") {
            grok.isAuthenticated = true
            state.snapshots[grok.id] = .failure(.network("the host is not answering"))
        }

        state.lastRefresh = now.addingTimeInterval(-12)
        return state
    }

    // MARK: - Rendering

    @MainActor
    private static func write(
        _ view: AnyView,
        to filename: String,
        scheme: ColorScheme
    ) throws {
        let host = NSHostingView(rootView: AnyView(view.environment(\.colorScheme, scheme)))
        host.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        let size = host.fittingSize
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        // A hosting view laid out this turn has not drawn yet; without a spin
        // the bitmap comes back as the pre-layout frame.
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))

        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let data = try XCTUnwrap(rep.representation(using: .png, properties: [:]))

        let url = outputDirectory.appendingPathComponent(filename)
        try data.write(to: url)
        // The reported size is the whole point of the width snapshots: a panel
        // wider than `panelWidth` is content that has escaped its frame.
        print("WROTE \(url.path) \(size.width)x\(size.height)")
    }
}
