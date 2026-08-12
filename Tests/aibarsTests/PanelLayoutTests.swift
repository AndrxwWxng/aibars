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

/// Hovering a row must not change its height.
///
/// The per-row actions were inserted on hover, so every row grew as the pointer
/// crossed it — and because MenuBarExtra sizes its window to the content, the
/// whole panel resized under the cursor. The space is reserved now and only
/// opacity changes, which this measures by comparing a row that shows its
/// actions against one that does not.
final class RowHoverLayoutTests: XCTestCase {
    @MainActor
    private func rowHeight(actions: AppearanceSettings.RowActionVisibility) -> CGFloat {
        let appearance = AppearanceSettings(store: UserDefaults(suiteName: "hover-\(actions.id)")!)
        appearance.rowActions = actions

        let state = AppState()
        let provider = state.providers[0]
        provider.isAuthenticated = true
        let snapshot = UsageData(
            providerID: provider.id,
            planName: "Pro",
            primary: UsageMetric(label: "5h window", used: 40, limit: 100, unit: "%")
        )

        let row = ProviderRow(
            provider: provider,
            result: .success(snapshot),
            onSignIn: {},
            appearance: appearance
        )
        let host = NSHostingView(rootView: AnyView(row.frame(width: 356)))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    /// `.always` is the hovered layout and `.onHover` the resting one. Equal
    /// heights mean crossing the row cannot move anything.
    @MainActor
    func testShowingActionsDoesNotChangeRowHeight() {
        let resting = rowHeight(actions: .onHover)
        let shown = rowHeight(actions: .always)
        XCTAssertEqual(
            resting, shown, accuracy: 0.5,
            "the row is \(shown)pt with actions and \(resting)pt without — hovering will resize the panel"
        )
    }

    /// Turning them off entirely may reclaim the space; it must not add any.
    @MainActor
    func testHidingActionsNeverGrowsTheRow() {
        XCTAssertLessThanOrEqual(rowHeight(actions: .never), rowHeight(actions: .onHover) + 0.5)
    }
}

// MARK: - The states one row passes through

/// A row must not change height for a reason the panel cannot see coming.
///
/// The class above covers the pointer's half of that; this covers the refresh's.
/// `MenuBarExtra` sizes its window to the height the rows report, so anything
/// that moves a row's height moves every row beneath it and resizes the window
/// while it is being read.
///
/// The line this draws, and it is the line the design draws: **structure may
/// change a row's height, content never may.** A fetch landing is structural —
/// a spinner line is replaced by a meter and a caption, which is a line more
/// than it was — and that happens once per launch, is what `RowGeometry.Lines`
/// declares, and is the panel growing into the thing it is about to say. What
/// must not move a row is anything that varies while that structure stands
/// still: a percentage ticking, a third digit arriving, a provider sending a
/// longer window name, a plan pill, an account address, or a message from an
/// endpoint nobody controls. Every test here is one of those, at every preset,
/// because density, text scale, bar thickness and meter style all move the boxes
/// this has to fit in and a preset is the combination a user ends up on.
///
/// One measurement deliberately not asserted, written down so the next reader
/// does not have to rediscover it. A metered row draws a point taller than
/// `RowGeometry.height` reserves for the same lines — 1pt at cozy, 1.4 at
/// dashboard's 105% type — because the window caption's tabular-digit run
/// measures a point over `Tokens.lineBox(detailSize)` at 11pt and up, while the
/// spinner and error lines measure it exactly. With `rowActions == .never` the
/// reservation runs the other way and is 3-5pt generous, which `RowGeometry`
/// documents on purpose. Nothing frames a row to that number today — only
/// `cardRadius` reads it — so both are latent, and the first thing that lays a
/// row out by it will clip a caption by a point.
final class RowStateLayoutTests: XCTestCase {

    /// What the row was handed, and nothing about how it looks.
    private enum Reading {
        /// No snapshot yet: the launch sweep is still out.
        case loading
        /// A metered window at this fraction of its cap.
        case reading(Double)
        /// A service that answered with a state rather than a quota — Copilot's
        /// "Active". It still occupies its meter slot, which is the claim
        /// `MeterSlot` exists to make.
        case noQuota
        /// The request failed outright, carrying whatever the provider said.
        case failed(String)
    }

    @MainActor
    private func result(_ reading: Reading, provider: AnyUsageProvider) -> Result<UsageData, ProviderError>? {
        switch reading {
        case .loading:
            return nil
        case .failed(let message):
            // `.parse` rather than an auth failure: the auth cases are the same
            // line with a different glyph, and this is the one whose text comes
            // from the far end of a network connection.
            return .failure(.parse(message))
        case .reading(let percent):
            return .success(
                UsageData(
                    providerID: provider.id,
                    planName: "Max",
                    primary: UsageMetric(
                        label: "5h",
                        used: percent * 100,
                        limit: 100,
                        unit: "%",
                        // A window with a stated length and a reset in the
                        // future, so the countdown and the pace riser both have
                        // something to say. A metric without them draws the
                        // quieter of the two layouts, and the busier one is the
                        // one that can go wrong.
                        resetDate: Date().addingTimeInterval(3600),
                        windowDuration: 5 * 3600
                    )
                )
            )
        case .noQuota:
            return .success(
                UsageData(
                    providerID: provider.id,
                    primary: UsageMetric(label: "Status", used: 0, limit: 0)
                )
            )
        }
    }

    /// A metered row carrying as much text as anything can put on one: a window
    /// name no rail is reserved for, a plan that is a sentence, and an account
    /// label that is an email address. Every one of them is a `lineLimit(1)`
    /// away from being a second line.
    @MainActor
    private func wordyResult(_ provider: AnyUsageProvider) -> Result<UsageData, ProviderError> {
        .success(
            UsageData(
                providerID: provider.id,
                planName: "Max 20x subscription, annual",
                primary: UsageMetric(
                    label: "Weekly limit, all models, per account",
                    used: 40,
                    limit: 100,
                    unit: "%",
                    resetDate: Date().addingTimeInterval(3600),
                    windowDuration: 5 * 3600
                ),
                accountLabel: "andrew.wang.long.address@example.com"
            )
        )
    }

    @MainActor
    private func rowHeight(
        _ result: Result<UsageData, ProviderError>?,
        appearance: AppearanceSettings,
        name: String
    ) throws -> CGFloat {
        let provider = try connectedProvider()
        let row = ProviderRow(
            provider: provider,
            result: result,
            onSignIn: {},
            appearance: appearance,
            budgets: try scratchBudgets(name),
            trend: try scratchTrends(name)
        )
        let host = NSHostingView(
            rootView: AnyView(row.frame(width: CGFloat(appearance.panelWidth)))
        )
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @MainActor
    private func rowHeight(
        _ reading: Reading,
        appearance: AppearanceSettings,
        name: String
    ) throws -> CGFloat {
        let provider = try connectedProvider()
        return try rowHeight(result(reading, provider: provider), appearance: appearance, name: name)
    }

    /// `showsCountdowns` is forced on over the preset rather than left to it.
    /// Minimal switches it off, and a metered row with no caption is one line
    /// shorter — a fact about a setting rather than about a state, and the
    /// busier layout is the one worth measuring.
    @MainActor
    private func presetSettings(_ preset: AppearanceSettings.Preset) throws -> AppearanceSettings {
        let appearance = try scratchAppearance("state.\(preset.rawValue)")
        appearance.apply(preset)
        appearance.showsCountdowns = true
        return appearance
    }

    /// The percentage is the one thing on a row that changes every minute the
    /// panel is open, and it is not allowed to move anything. Both ends and both
    /// thresholds, because the figure changes weight at the warning and the fill
    /// squares its trailing end there.
    @MainActor
    func testTheReadingItselfNeverChangesTheRowsHeight() throws {
        for preset in AppearanceSettings.Preset.allCases {
            let appearance = try presetSettings(preset)
            var heights: [String: CGFloat] = [:]
            for percent in [0, 0.09, 0.4, 0.85, 1.0] {
                heights[String(percent)] = try rowHeight(
                    .reading(percent), appearance: appearance, name: "reading.\(preset.rawValue)"
                )
            }
            let spread = (heights.values.max() ?? 0) - (heights.values.min() ?? 0)
            XCTAssertLessThanOrEqual(
                spread, 0.5,
                "\(preset.rawValue): the row measured \(heights) across one window's own range"
            )
        }
    }

    /// The horizontal invariant seen from the vertical side, and the one digit
    /// that matters. Tabular figures fix the width of a digit and not the length
    /// of a string, so an unreserved rail lets "9%" reflow to "100%" — and the
    /// way that shows up in a panel this narrow is not a nudged column but a
    /// wrapped figure, "100" over "%", a whole line taller than the row it is in.
    @MainActor
    func testTheRowIsTheSameHeightAtNineAndAtAHundredPercent() throws {
        for preset in AppearanceSettings.Preset.allCases {
            let appearance = try presetSettings(preset)
            let single = try rowHeight(.reading(0.09), appearance: appearance, name: "digits.\(preset.rawValue)")
            let triple = try rowHeight(.reading(1.0), appearance: appearance, name: "digits.\(preset.rawValue)")
            XCTAssertEqual(
                single, triple, accuracy: 0.5,
                "\(preset.rawValue): the row is \(single)pt at 9% and \(triple)pt at 100% — "
                + "the third digit has wrapped the figure"
            )
        }
    }

    /// How much a service has to say is the provider's business and not the
    /// panel's. Claude's per-model weekly caps arrive as "Weekly · per-model",
    /// plan names arrive as whatever marketing calls the tier, and an account
    /// label is an email address — none of which the row has room for, and all
    /// of which it has to truncate rather than wrap.
    @MainActor
    func testHowMuchAServiceHasToSayNeverChangesTheRowsHeight() throws {
        for preset in AppearanceSettings.Preset.allCases {
            let appearance = try presetSettings(preset)
            // Both labels on, so the two rows differ in their text and in
            // nothing else: a preset that hides the plan pill would otherwise
            // pass this by never drawing the thing under test.
            appearance.showsPlanNames = true
            appearance.showsAccountLabels = true
            let provider = try connectedProvider()

            let plain = try rowHeight(.reading(0.4), appearance: appearance, name: "wordy.\(preset.rawValue)")
            let wordy = try rowHeight(
                wordyResult(provider), appearance: appearance, name: "wordy.\(preset.rawValue)"
            )
            XCTAssertEqual(
                plain, wordy, accuracy: 0.5,
                "\(preset.rawValue): a row with long labels is \(wordy)pt against \(plain)pt — "
                + "something on the title line has wrapped instead of truncating"
            )
        }
    }

    /// The height law, as the one test that would catch it breaking.
    ///
    /// A row's height is a function of the settings and of one bit — does this
    /// row have a reading to report — and of nothing else. Not which error. Not
    /// whether a spinner is turning. So a row waiting for its first fetch is
    /// exactly as tall as the error it may turn into and as the reading it may
    /// turn into, and the panel cannot resize under the pointer when either
    /// arrives.
    ///
    /// This used to assert the opposite, on the argument that a loading row has
    /// nothing to say and should cost nothing. It said nothing at all: `lines`
    /// returned empty while loading and `detailContent` had no branch for it, so
    /// four enabled services with no snapshot yet drew four rows containing a
    /// service name and nothing else — no status, no spinner, no "Sign in" —
    /// which is what a new user stares at for the app's first seconds. The row
    /// says "Checking…" now, in the box it was already reserving.
    @MainActor
    func testAPendingRowIsExactlyAsTallAsTheErrorItMayBecome() throws {
        for preset in AppearanceSettings.Preset.allCases {
            let appearance = try presetSettings(preset)
            let loading = try rowHeight(.loading, appearance: appearance, name: "line.\(preset.rawValue)")
            let failed = try rowHeight(
                .failed("timed out"), appearance: appearance, name: "line.\(preset.rawValue)"
            )
            let reading = try rowHeight(
                .reading(0.42), appearance: appearance, name: "line.\(preset.rawValue)"
            )
            XCTAssertEqual(
                failed, loading, accuracy: 0.5,
                "\(preset.rawValue): the pending row is \(loading)pt and the error row \(failed)pt — "
                + "the panel resizes when a fetch fails"
            )
            XCTAssertEqual(
                reading, loading, accuracy: 0.5,
                "\(preset.rawValue): the pending row is \(loading)pt and the reporting row \(reading)pt — "
                + "the panel resizes under the pointer when the first reading lands"
            )
            XCTAssertGreaterThan(loading, 0, "\(preset.rawValue): the pending row measured nothing")
        }
    }

    /// And an error message is the one string on a row that arrives from the far
    /// end of a network connection, so it is the one place a row's height could
    /// be set by somebody else. Two lines is the cap the row asks for; a
    /// paragraph must not buy a third.
    @MainActor
    func testNoMessageFromAProviderCanGrowTheRowPastASecondLine() throws {
        let paragraph = String(
            repeating: "the provider answered with something this parser could not read. ", count: 20
        )
        for preset in AppearanceSettings.Preset.allCases {
            let appearance = try presetSettings(preset)
            let short = try rowHeight(
                .failed("timed out"), appearance: appearance, name: "long.\(preset.rawValue)"
            )
            let long = try rowHeight(
                .failed(paragraph), appearance: appearance, name: "long.\(preset.rawValue)"
            )
            XCTAssertLessThanOrEqual(
                long, short + Tokens.lineBox(appearance.metrics.detailSize) + 0.5,
                "\(preset.rawValue): 1300 characters took the row from \(short)pt to \(long)pt — the "
                + "second line is meant to be the last one"
            )
        }
    }

    /// A service that publishes a state rather than a quota still occupies its
    /// meter slot: a hairline where the bar would be, with the same line under
    /// it. That is the whole reason `MeterSlot` is drawn on a row with nothing to
    /// meter, and without it a quotaless row would sit a meter and a gap shorter
    /// than its neighbours.
    ///
    /// Bounded by the slot's own height rather than asserted equal, because the
    /// two are a point apart for the type-metric reason this class's own
    /// documentation gives — and a point is not the failure being looked for. The
    /// failure is the slot going missing, which is at least five points at any
    /// density.
    @MainActor
    func testAQuotalessServiceStillOccupiesItsMeterSlot() throws {
        for preset in AppearanceSettings.Preset.allCases {
            let appearance = try presetSettings(preset)
            let metered = try rowHeight(.reading(0.4), appearance: appearance, name: "slot.\(preset.rawValue)")
            let quotaless = try rowHeight(.noQuota, appearance: appearance, name: "slot.\(preset.rawValue)")
            let slot = appearance.metrics.barHeight + appearance.metrics.captionGap
            XCTAssertLessThan(
                abs(metered - quotaless), slot,
                "\(preset.rawValue): a reading draws \(metered)pt and a status \(quotaless)pt, which is "
                + "the \(slot)pt slot — a service reporting no quota has lost its meter"
            )
        }
    }
}

// MARK: - One right edge

/// Every figure in the window ends on one column.
///
/// The rails are *reserved* rather than measured, and the difference is only
/// visible from outside: tabular figures fix the width of a digit and not the
/// length of a string, so a measured column moves as a row ticks from 9% to
/// 100% and drags whatever sits beside it. Rendered, because the claim is about
/// where ink lands, and read off the unit tick — the `%` is the same glyph at
/// the same size and the same neutral ink in every band and under every ramp, so
/// comparing two rows by it is exact rather than approximate.
final class FigureRailAlignmentTests: XCTestCase {

    /// The scale the columns below are counted in. Fixed here so a pixel can be
    /// turned back into a point without asking the raster.
    private static let scale: CGFloat = 2

    @MainActor
    private func settings() throws -> AppearanceSettings {
        let appearance = try scratchAppearance("rail")
        // Nothing hidden and nothing added: the panel's own default look, with
        // the row's buttons resting so their glyphs cannot be the rightmost ink
        // on the title line.
        appearance.rowActions = .onHover
        return appearance
    }

    /// Where the headline figure's ink ends, in points from the row's leading
    /// edge, read off the title line alone — the meter beneath it runs the full
    /// width of the text column and would otherwise answer instead.
    @MainActor
    private func figureEdge(reading: Double, appearance: AppearanceSettings) throws -> CGFloat {
        let provider = try connectedProvider()
        let row = ProviderRow(
            provider: provider,
            result: .success(
                UsageData(
                    providerID: provider.id,
                    primary: UsageMetric(label: "5h", used: reading * 100, limit: 100, unit: "%")
                )
            ),
            onSignIn: {},
            appearance: appearance,
            budgets: try scratchBudgets("rail"),
            trend: try scratchTrends("rail")
        )
        .frame(width: CGFloat(appearance.panelWidth))

        let raster = try XCTUnwrap(Raster(row, scale: Self.scale))
        let titleLine = CGRect(
            x: 0,
            y: 0,
            width: raster.size.width,
            // The title line is held at the height of the row's action buttons,
            // which is taller than either type size at every density — so this
            // covers the figure and stops above the meter.
            height: appearance.metrics.rowVerticalPadding + Tokens.Control.rowIconButton
        )
        let column = try XCTUnwrap(
            raster.lastInkedColumn(in: titleLine),
            "the title line came back blank at \(reading)"
        )
        return CGFloat(column + 1) / Self.scale
    }

    /// Where the header's own content column ends.
    ///
    /// Measured with a 1pt marker in the trailing slot rather than off the real
    /// header's ink: the cluster of icon buttons that normally sits there is
    /// drawn from glyphs that stop short of their own frames, and what is under
    /// test is the edge the header is laid out to, not how a chevron is centred.
    @MainActor
    private func headerEdge(_ appearance: AppearanceSettings) throws -> CGFloat {
        let header = PanelHeader(
            appearance: appearance,
            summary: "claude 92% · updated 12s ago"
        ) {
            Rectangle()
                .fill(Color.black)
                .frame(width: Tokens.Control.hairline, height: Tokens.Space.medium)
        }
        .frame(width: CGFloat(appearance.panelWidth))

        let raster = try XCTUnwrap(Raster(header, scale: Self.scale))
        let column = try XCTUnwrap(
            raster.lastInkedColumn(in: CGRect(origin: .zero, size: raster.size)),
            "the header came back blank"
        )
        return CGFloat(column + 1) / Self.scale
    }

    /// One digit, two digits, three: the column does not move. This is the whole
    /// of what "reserved" buys, and the only way to see it is from the pixels —
    /// the rail is the same number in all three cases whether it is reserved or
    /// measured, and it is the ink that gives the difference away.
    @MainActor
    func testEveryReadingEndsOnTheSameColumn() throws {
        let appearance = try settings()
        var edges: [String: CGFloat] = [:]
        for reading in [0.09, 0.4, 1.0] {
            edges[String(Int(reading * 100))] = try figureEdge(reading: reading, appearance: appearance)
        }
        XCTAssertEqual(
            Set(edges.values).count, 1,
            "the figures ended at \(edges) — the rail is being measured off the string rather than reserved"
        )
    }

    /// And that column is the panel's own right edge, the one the header is laid
    /// out to. The failure this catches is a margin added on one side and not the
    /// other — a list inset by `Space.listMargin` horizontally as well as
    /// vertically would put every reading in the panel 6pt inside the line above
    /// them, which is exactly the kind of drift nothing else notices.
    @MainActor
    func testTheRailEndsWhereTheHeaderDoes() throws {
        let appearance = try settings()
        let rail = try figureEdge(reading: 0.4, appearance: appearance)
        let header = try headerEdge(appearance)

        XCTAssertLessThanOrEqual(
            rail, header,
            "the figure ends at \(rail)pt, past the header's own \(header)pt"
        )
        // They agree to the pixel today: the marker fills its cell and the tail
        // of a `%` reaches the end of its own, so the two edges land on the same
        // column. The slack is a point, for the right side bearing of a glyph
        // this test does not choose the font of — six points is a margin, which
        // is the thing being looked for.
        XCTAssertEqual(
            rail, header, accuracy: 1,
            "the figure ends at \(rail)pt and the header at \(header)pt — the rows and the chrome are "
            + "laid out to two different right edges"
        )
    }
}

// MARK: - The rasteriser these rendered assertions share

/// A scratch defaults domain, so nothing here reads or writes the settings of
/// whoever ran the suite.
///
/// `AppearanceSettings` decodes in `init`, so a domain left behind by an earlier
/// run would hand the next one somebody else's panel — which is why the domain
/// is emptied on the way in rather than on the way out.
@MainActor
private func scratchAppearance(_ name: String) throws -> AppearanceSettings {
    AppearanceSettings(store: try scratchDefaults("appearance.\(name)"))
}

/// The forecast's samples, empty. A row reads these to decide whether it has a
/// pace line to draw, and the shared store holds whatever the machine running
/// the tests has been collecting.
@MainActor
private func scratchTrends(_ name: String) throws -> UsageTrendStore {
    UsageTrendStore(store: try scratchDefaults("trends.\(name)"))
}

/// The user's budgets, empty, for the same reason: a budget on the service under
/// test would add a meter to the row and a line to its height.
@MainActor
private func scratchBudgets(_ name: String) throws -> BudgetStore {
    BudgetStore(store: try scratchDefaults("budgets.\(name)"))
}

private func scratchDefaults(_ name: String) throws -> UserDefaults {
    let domain = "aibars.panel-layout-tests.\(name)"
    let store = try XCTUnwrap(UserDefaults(suiteName: domain), "could not open a scratch defaults domain")
    store.removePersistentDomain(forName: domain)
    return store
}

/// The first service `AppState` declares, connected.
///
/// A real provider rather than a stub, because a row reads four things off one —
/// its name, its brand colour, whether it has a dashboard to open, and whether
/// it is authenticated at all — and three of those change what the row draws.
@MainActor
private func connectedProvider() throws -> AnyUsageProvider {
    let provider = try XCTUnwrap(AppState().providers.first, "AppState declared no services")
    provider.isAuthenticated = true
    return provider
}

/// A rasterised view, and the pixel arithmetic the rendered assertions share.
///
/// Rendered rather than reasoned about, because these are claims about what is
/// drawn: ground punched through a fill, a mark that has to be absent, a
/// bookmark at a card's leading edge, ink ending on a column. None of them is
/// reachable from a geometry function, and every one of them is the kind of
/// thing a refactor breaks without failing anything.
private struct Raster {
    let bitmap: NSBitmapImageRep
    /// Pixels per point, measured off the render rather than taken from
    /// `ImageRenderer.scale`: the two agree today, and measuring keeps this
    /// working if they ever stop.
    let scale: CGFloat
    /// The size the content laid itself out at, in points.
    let size: CGSize

    /// Anything above a tenth of full alpha counts as drawn. These assertions
    /// ask whether something is there rather than how dark it is, and the
    /// panel's own inks run from an opaque meter fill down to `Ink.idle`, which
    /// resolves at half alpha and would be invisible to a stricter threshold.
    private static let inked: CGFloat = 0.1

    @MainActor
    init?<Content: View>(_ content: Content, dark: Bool = false, scale requested: CGFloat = 2) {
        let renderer = ImageRenderer(
            content: content.environment(\.colorScheme, dark ? .dark : .light)
        )
        renderer.scale = requested
        var laid = CGSize.zero
        renderer.render { measured, _ in laid = measured }
        guard laid.width > 0, laid.height > 0,
              let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              bitmap.pixelsWide > 0, bitmap.pixelsHigh > 0 else { return nil }
        self.bitmap = bitmap
        self.size = laid
        self.scale = CGFloat(bitmap.pixelsWide) / laid.width
    }

    /// In sRGB always: the bitmap comes back in the display's own space, and
    /// every comparison here is between two colours read through this.
    func colour(x: Int, y: Int) -> NSColor? {
        guard x >= 0, x < bitmap.pixelsWide, y >= 0, y < bitmap.pixelsHigh else { return nil }
        return bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)
    }

    func inkedPixels(in rect: CGRect) -> Int {
        var count = 0
        forEachPixel(in: rect) { colour, _, _ in
            if (colour?.alphaComponent ?? 0) > Self.inked { count += 1 }
        }
        return count
    }

    func firstInkedColumn(in rect: CGRect) -> Int? {
        var first: Int?
        forEachPixel(in: rect) { colour, x, _ in
            guard (colour?.alphaComponent ?? 0) > Self.inked else { return }
            first = min(first ?? x, x)
        }
        return first
    }

    func lastInkedColumn(in rect: CGRect) -> Int? {
        var last: Int?
        forEachPixel(in: rect) { colour, x, _ in
            guard (colour?.alphaComponent ?? 0) > Self.inked else { return }
            last = max(last ?? x, x)
        }
        return last
    }

    /// One unbroken length of a named colour along a scanline. A struct rather
    /// than a tuple only because a tuple cannot be read with a key path, and
    /// these are read as columns of labels.
    struct Run {
        let label: String
        var pixels: Int
    }

    /// The recognised runs along one scanline, in order.
    ///
    /// Unrecognised pixels are dropped rather than labelled: where two fills
    /// meet, the pixel between them is a blend of both and is honestly neither,
    /// and what these assertions are about is which named colours appear along a
    /// bar and in what order. Dropping the blend also merges the two halves of a
    /// run it interrupts, which is the reading a person would give.
    func runs(alongY y: CGFloat, of swatches: Swatches) -> [Run] {
        var runs: [Run] = []
        let row = pixel(y)
        for x in 0..<bitmap.pixelsWide {
            guard let label = swatches.label(of: colour(x: x, y: row)) else { continue }
            if runs.last?.label == label {
                runs[runs.count - 1].pixels += 1
            } else {
                runs.append(Run(label: label, pixels: 1))
            }
        }
        return runs
    }

    /// The pixel a point lands in.
    private func pixel(_ point: CGFloat) -> Int {
        Int((point * scale).rounded(.down))
    }

    private func forEachPixel(in rect: CGRect, _ body: (NSColor?, Int, Int) -> Void) {
        let columns = max(0, pixel(rect.minX))..<min(bitmap.pixelsWide, pixel(rect.maxX))
        let rows = max(0, pixel(rect.minY))..<min(bitmap.pixelsHigh, pixel(rect.maxY))
        for x in columns {
            for y in rows {
                body(colour(x: x, y: y), x, y)
            }
        }
    }
}

/// Reference colours, rendered through the same path as the view under test.
///
/// Never compared against the hex in `Tokens`. `ImageRenderer` hands back a
/// bitmap in the display's colour space, so `Surface.base` — #F7F8FA — reads
/// back a shade off out of it; the shift is the profile rather than a wrong colour, and
/// it is identical for a swatch and for a bar. Rendering the reference is what
/// makes the comparison exact instead of approximate, and it also means a token
/// that changes value moves the test with it rather than failing it.
private struct Swatches {
    private let references: [(label: String, colour: NSColor)]

    @MainActor
    init?(_ colours: [(label: String, colour: Color)], dark: Bool = false) {
        var resolved: [(label: String, colour: NSColor)] = []
        for entry in colours {
            guard let raster = Raster(
                    Rectangle().fill(entry.colour).frame(width: 4, height: 4),
                    dark: dark
                  ),
                  let middle = raster.colour(x: 4, y: 4) else { return nil }
            resolved.append((entry.label, middle))
        }
        references = resolved
    }

    /// The label this pixel is the colour of, or nil for anything else.
    func label(of colour: NSColor?) -> String? {
        guard let colour, colour.alphaComponent > 0.99 else { return nil }
        return references.first { matches(colour, $0.colour) }?.label
    }

    /// The same colour through the same pipeline lands on the same byte, so the
    /// tolerance is one 255th and is there for the rounding either side of that
    /// — not for telling two colours apart.
    private func matches(_ a: NSColor, _ b: NSColor) -> Bool {
        abs(a.redComponent - b.redComponent) < 0.005
            && abs(a.greenComponent - b.greenComponent) < 0.005
            && abs(a.blueComponent - b.blueComponent) < 0.005
    }
}
