import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// The one switch for every harness in this suite that asserts nothing.
///
/// The `ZZ` files are here to be read by a human, not to pass or fail: two of
/// them print numbers and this one writes PNGs. An ordinary `xcodebuild test`
/// wants none of it, and the harness that was gated the least — it wrote
/// `/tmp/aibars_states_*.png` on every CI run, unasked — is the one that made
/// the case for putting the decision in a single place rather than in a
/// convention each new harness has to notice.
///
/// It lives in this file because this is the harness the gate was written for.
/// A fourth harness should call `skipUnlessAsked` rather than write a fourth
/// copy of the string literal, which is how the third one came to be missing.
///
/// The variable is read as `AIBARS_SNAPSHOT`; under `xcodebuild` it is set as
/// `TEST_RUNNER_AIBARS_SNAPSHOT`, which the test runner strips the prefix from
/// before the process sees it.
enum DebugHarness {
    static var isEnabled: Bool {
        ProcessInfo.processInfo.environment["AIBARS_SNAPSHOT"] == "1"
    }

    /// Skips unless the harnesses were asked for, so the run reports these as
    /// skipped rather than as passes that measured nothing.
    static func skipUnlessAsked(
        _ what: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        try XCTSkipUnless(isEnabled, "set AIBARS_SNAPSHOT=1 to \(what)", file: file, line: line)
    }

    /// Where the file-writing harnesses put their output. `/tmp` only because
    /// something has to be the fallback — CI passes a directory it can collect,
    /// and nothing under `/tmp` survives a reboot to be found later and
    /// mistaken for the current panel.
    static var outputDirectory: URL {
        URL(fileURLWithPath:
            ProcessInfo.processInfo.environment["AIBARS_SNAPSHOT_DIR"] ?? "/tmp")
    }
}

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
/// `DebugHarness`, above, and reports skipped otherwise.
final class ZZPanelSnapshot: XCTestCase {

    /// The shipped defaults on a scratch domain, never `AppearanceSettings.shared`.
    ///
    /// Two reasons, and the first is the one that bit. This harness *writes* to
    /// the object — `testWritePanelWidthExtremes` walks `panelWidth` to 300 and
    /// 520 — and it restored the value in a `defer`, which does not run when the
    /// process is killed. Being interrupted is the normal way a render session
    /// ends: you look at the PNGs and stop the run. `PanelLayoutTests` records the
    /// consequence in its own doc — `testWidthIsFixed` measuring a 420pt panel
    /// after this harness was interrupted.
    ///
    /// The second is what the pictures are for. A render is read as "this is what
    /// the app draws", so it has to be what the app draws on a *fresh install* and
    /// not what it draws for whoever happened to run it. Two reviewers comparing
    /// before-and-after PNGs were comparing two panels' settings as well as two
    /// panels.
    @MainActor
    private func defaults() throws -> AppearanceSettings {
        try isolatedSettings("panel-snapshot")
    }

    @MainActor
    func testWritePanelSnapshot() throws {
        try DebugHarness.skipUnlessAsked("write panel PNGs")

        let appearance = try defaults()
        let state = Self.populatedState()
        for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            let view = MenuBarContentView(
                state: state,
                showSettings: .constant(false),
                appearance: appearance
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
        try DebugHarness.skipUnlessAsked("write panel PNGs")

        let appearance = try defaults()
        let state = Self.populatedState()
        // Both appearances at both extremes, not dark alone. The width slider is
        // where a reserved-width contract breaks first and the light palette is
        // where a *contrast* one does — the two hues are cut against different
        // grounds in the two appearances and the light half has the less room —
        // so a change reviewed at one width in one appearance has been reviewed
        // at a quarter of the cases the panel actually ships.
        for width in [300.0, 520.0] {
            appearance.panelWidth = width
            for (name, scheme) in [("", ColorScheme.dark), ("_light", ColorScheme.light)] {
                let view = MenuBarContentView(
                    state: state,
                    showSettings: .constant(false),
                    appearance: appearance
                )
                try Self.write(
                    AnyView(view),
                    to: "aibars_panel_w\(Int(width))\(name).png",
                    scheme: scheme
                )
            }
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

        // Gemini — the state no shipped screenshot has ever contained.
        //
        // `warningThreshold` defaults to 0.95 and the highest reading in this
        // fixture was Claude's 92, so every claim the near-cap contract makes —
        // the fill's square trailing cap, the figure at `Ramp.alertWeight`, the
        // ramp's red stop, and now the fill running past the redline — went
        // unlooked-at for two releases because the picture could not hold the
        // state. 97 is inside the band at both ends: over the threshold by two
        // and under the cap by three, so the square cap is drawn against a track
        // that is still visibly not full.
        if let gemini = provider("gemini") {
            gemini.isAuthenticated = true
            state.snapshots[gemini.id] = .success(UsageData(
                providerID: gemini.id,
                planName: "Pro",
                primary: UsageMetric(
                    label: "Daily", used: 97, limit: 100, unit: "%",
                    resetDate: now.addingTimeInterval(3 * 3_600)
                )
            ))
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

        let url = DebugHarness.outputDirectory.appendingPathComponent(filename)
        try data.write(to: url)
        // The reported size is the whole point of the width snapshots: a panel
        // wider than `panelWidth` is content that has escaped its frame.
        print("WROTE \(url.path) \(size.width)x\(size.height)")
    }
}
