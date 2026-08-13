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
            try Self.write(
                AnyView(try Self.panel(state: state, appearance: appearance)),
                to: "aibars_panel_\(name).png",
                scheme: scheme
            )
        }
    }

    /// The panel with the further windows on a line each, which is the
    /// **Dashboard** preset's setting and the one this harness could not show.
    ///
    /// It is a render of its own because the style is panel-wide: `.expanded` is
    /// one switch for every row, so "a row with expanded windows" is a picture of
    /// the whole panel with it on. What there is to look at is the ladder — every
    /// row holding `secondaryWindowLimit` lines whether or not the service filled
    /// them, which is what makes a row's height a function of the stepper instead
    /// of a function of the fetch. The empty rungs are the price, and a picture is
    /// the only honest way to decide whether the price is worth paying.
    ///
    /// A limit of four rather than the preset's six, because four is where the
    /// fixture straddles the interesting line: Claude Code fills three rungs of
    /// it, Claude two, Codex one, and the four rows that report no further windows
    /// at all — Perplexity, Copilot, Gemini, Cursor — hold four clear lines each.
    /// Every case the ladder has is in one picture, including the expensive one.
    @MainActor
    func testWritePanelWithExpandedWindows() throws {
        try DebugHarness.skipUnlessAsked("write panel PNGs")

        let appearance = try defaults()
        appearance.secondaryWindows = .expanded
        appearance.secondaryWindowLimit = 4
        let state = Self.populatedState()
        for (name, scheme) in [("dark", ColorScheme.dark), ("light", ColorScheme.light)] {
            try Self.write(
                AnyView(try Self.panel(state: state, appearance: appearance)),
                to: "aibars_panel_expanded_\(name).png",
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
                try Self.write(
                    AnyView(try Self.panel(state: state, appearance: appearance)),
                    to: "aibars_panel_w\(Int(width))\(name).png",
                    scheme: scheme
                )
            }
        }
    }

    // MARK: - The panel under test

    /// The panel, with the two stores its rows draw from handed in.
    ///
    /// Built here rather than at each of the three cases, because a render that
    /// reached for `UsageTrendStore.shared` and `BudgetStore.shared` would be two
    /// defects at once: it would write sample rings into the developer's own
    /// defaults, and the picture would show whatever that machine had been
    /// collecting rather than what the app draws. The same argument `defaults()`
    /// makes about `AppearanceSettings.shared`, one store along.
    ///
    /// The stores are seeded, and that is the point of them. Half of what this
    /// harness exists to show cannot be drawn by settings alone: a pace claim
    /// needs samples, a budget meter needs a budget, and until this pass there
    /// was neither — so **no render this project has ever reviewed contained a
    /// pace line**, including every render taken while the pace was a block that
    /// resized the panel when it arrived.
    @MainActor
    private static func panel(
        state: AppState,
        appearance: AppearanceSettings
    ) throws -> MenuBarContentView {
        MenuBarContentView(
            state: state,
            showSettings: .constant(false),
            appearance: appearance,
            budgets: try budgets(),
            trend: try trend(state: state)
        )
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

        // Perplexity — full, exactly. The state between Gemini's 97 and
        // Copilot's overage, and the one where the fill's square trailing cap
        // meets the end of its own track: at 97 the cap is drawn against a track
        // that is visibly not full, and at 100 there is nothing left to be
        // visibly anything. Nothing in the panel had ever drawn it.
        if let perplexity = provider("perplexity") {
            perplexity.isAuthenticated = true
            state.snapshots[perplexity.id] = .success(UsageData(
                providerID: perplexity.id,
                planName: "Pro",
                primary: UsageMetric(
                    label: "Daily", used: 100, limit: 100, unit: "%",
                    resetDate: now.addingTimeInterval(11 * 3_600)
                )
            ))
        }

        // Copilot — past the cap, which the app has a deliberate answer for and
        // no picture of. `UsageMetric.percent` clamps and `rawPercent` does not,
        // precisely so the meter stops at full while the figure says 137% — two
        // channels disagreeing on purpose, in the one direction that is honest.
        // The rail reserves three digits and a unit, so this is also the reading
        // that says whether it reserved enough.
        if let copilot = provider("copilot") {
            copilot.isAuthenticated = true
            state.snapshots[copilot.id] = .success(UsageData(
                providerID: copilot.id,
                planName: "Business",
                primary: UsageMetric(
                    label: "Premium requests", used: 411, limit: 300, unit: nil,
                    resetDate: now.addingTimeInterval(6 * 86_400)
                )
            ))
        }

        state.lastRefresh = now.addingTimeInterval(-12)
        return state
    }

    /// A budget on the one service in the fixture that reports money.
    ///
    /// Claude Code's spend is $8,700.47 estimated, so a $8,000 budget puts the
    /// row over by $700.47 — the state the budget meter was written for and the
    /// one no render has shown, since the harness had no store to set a budget
    /// in. Over rather than under deliberately: the under-budget drawing is a
    /// grey bar part-filled, which the panel already shows nine of, and the whole
    /// question a review of this meter has to answer is whether the alarm reads
    /// as an alarm beside the usage ramp above it.
    ///
    /// It also draws the "est." qualifier, since the spend behind it is arithmetic
    /// this app did rather than an invoice — `RowGeometry.spendReserve` counts
    /// three cells for that word and nothing had ever drawn it.
    @MainActor
    private static func budgets() throws -> BudgetStore {
        let store = BudgetStore(store: try scratch("budgets"))
        store.setBudget(Budget(amountMinor: 800_000, currency: "USD"), for: "claudecode")
        return store
    }

    /// Half an hour of rising samples for the three rows whose caption lines have
    /// room to carry a claim.
    ///
    /// Seeded through `record`, which is what the refresh loop calls, so the fit's
    /// own refusals — three samples, five minutes apart, a rising slope, an
    /// arrival inside twelve hours — all apply. A row that draws no pace here is a
    /// row the app would draw no pace for.
    ///
    /// Three rows and not one, because whether the claim survives is a question
    /// about *width*: `MetricCaption` offers it as the richest of five candidates
    /// and drops it first, so a row already carrying a spend, a countdown and two
    /// chips has no room for it at 356pt and a row carrying a countdown alone has
    /// plenty. That is the behaviour under review — the pace is the first thing to
    /// go and nothing else on the line moves when it does — and one seeded row
    /// could only show one half of it.
    @MainActor
    private static func trend(state: AppState) throws -> UsageTrendStore {
        let now = Date()
        let store = UsageTrendStore(store: try scratch("trend"), now: { now })
        for serviceID in ["gemini", "cursor", "claude"] {
            guard let provider = state.providers.first(where: { $0.serviceID == serviceID }),
                  case .success(let data)? = state.snapshots[provider.id],
                  data.primary.limit > 0
            else { continue }
            // Ending on the reading the row is showing, so the claim and the
            // figure beside it are about the same number: five samples at five
            // minutes, climbing to where the row already is.
            let landing = data.primary.percent
            for step in 0..<5 {
                let percent = max(0, landing - Double(4 - step) * 0.03)
                store.record(
                    UsageData(
                        providerID: data.providerID,
                        fetchedAt: now.addingTimeInterval(-Double(4 - step) * 300),
                        primary: UsageMetric(
                            label: data.primary.label,
                            used: percent * data.primary.limit,
                            limit: data.primary.limit,
                            unit: data.primary.unit,
                            resetDate: data.primary.resetDate
                        )
                    ),
                    for: provider.id
                )
            }
        }
        return store
    }

    /// A scratch defaults domain, wiped on the way in. `fatalError` on failure
    /// rather than a fallback to `.standard`, following `RowReservationTests`: a
    /// render seeded from the developer's own budgets and samples is not a weaker
    /// picture, it is a picture of a different app.
    @MainActor
    private static func scratch(_ name: String) throws -> UserDefaults {
        let domain = "dev.aibars.test-scratch.panel-snapshot.\(name)"
        let store = try XCTUnwrap(
            UserDefaults(suiteName: domain), "could not open the scratch domain \(domain)"
        )
        store.removePersistentDomain(forName: domain)
        return store
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
