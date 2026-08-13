import XCTest
import SwiftUI
@testable import aibarsCore

/// The two things a row reserves, and the one rule both of them keep: **a row's
/// reservation is a function of its settings and of whether it holds a reading
/// at all — never of what the reading says.**
///
/// `RowGeometryTests` asserts the arithmetic of one row at stated inputs. This
/// asserts the property across the whole space a user can put the panel in,
/// which is a different kind of test and catches a different kind of mistake:
/// the geometry model was internally consistent when the panel shipped with two
/// of these defects in it, and would have *recorded* both rather than caught
/// them. Every case here sweeps rather than spot-checks, because both defects
/// appeared at one combination of settings and were invisible at the shipped one.
final class RowReservationTests: XCTestCase {

    /// The whole space, named once: five presets, three densities and both ends
    /// of the text-size slider plus the middle. 45 configurations, and each case
    /// below walks all of them.
    ///
    /// Density and text scale are swept *over* each preset rather than left to
    /// it, because they are the two settings that move every box on the row —
    /// and a preset pins one value of each, so a preset sweep alone measures five
    /// points of a 45-point space.
    private static let densities = AppearanceSettings.Density.allCases
    private static let textScales: [Double] = [0.85, 1.0, 1.30]

    /// The panel widths a user can set, both ends of the slider included. The
    /// same four `PanelWidthContractTests` draws at, so a failure here and a
    /// failure there are talking about the same panel.
    private static let panelWidths: [Double] = [300, 356, 420, 520]

    @MainActor
    private func settings(_ name: String) -> AppearanceSettings {
        let domain = "aibars.row-reservation-tests.\(name)"
        guard let store = UserDefaults(suiteName: domain) else {
            XCTFail("could not open a scratch defaults domain")
            return AppearanceSettings(store: .standard)
        }
        store.removePersistentDomain(forName: domain)
        return AppearanceSettings(store: store)
    }

    /// Walks the space, handing each configuration to the body along with a
    /// label that says which one it was — a bare `XCTAssertEqual` failure in a
    /// 45-iteration sweep is a number with no address.
    @MainActor
    private func sweep(
        _ name: String,
        _ body: (AppearanceSettings, String) throws -> Void
    ) rethrows {
        let appearance = settings(name)
        for preset in AppearanceSettings.Preset.allCases {
            for density in Self.densities {
                for scale in Self.textScales {
                    appearance.apply(preset)
                    appearance.density = density
                    appearance.textScale = scale
                    try body(appearance, "\(preset.rawValue)/\(density.rawValue)/\(Int(scale * 100))%")
                }
            }
        }
    }

    // MARK: - Height across the states one row passes through

    /// The headline invariant, stated as the test that would have caught the
    /// defect that shipped.
    ///
    /// A row can be in three states that differ by less than a whole line:
    /// waiting for its first answer, holding a reading whose caption has nothing
    /// on it, and holding a failure. The reserved height must be the same number
    /// in all three, because `MenuBarExtra` sizes its window to what the rows
    /// report and a row that grows when a fetch lands resizes the panel under the
    /// pointer.
    ///
    /// It was not the same number. `lines` returned `[.meter, .window]` for every
    /// non-success state and `[.meter]` for a success whose caption was empty, so
    /// under Minimal — which switches off amounts, countdowns and the further
    /// windows, leaving nothing for that caption to say — every row was one
    /// `lineBox` shorter the moment its first reading arrived, and nine rows of it
    /// moved the whole panel.
    ///
    /// Measured through `ProviderRow`'s own reservation rather than by naming
    /// line sets, since the defect was in the *choice* of line set and a test that
    /// names the sets cannot see it.
    @MainActor
    func testTheReservedHeightIsTheSameInEveryStateARowCanBeIn() throws {
        let provider = try Self.connectedProvider()
        try sweep("height-across-states") { appearance, at in
            let heights = Self.states(for: provider).map { state in
                (state.name, Self.reservation(appearance: appearance, provider: provider, result: state.result).height)
            }
            let spread = (heights.map(\.1).max() ?? 0) - (heights.map(\.1).min() ?? 0)
            XCTAssertEqual(
                spread, 0,
                "\(at): the row reserved \(heights.map { "\($0.0) \($0.1)pt" }.joined(separator: ", "))"
            )
        }
    }

    /// The same property one level down, so a failure says whether the height
    /// moved or the *reason* for the height moved. A row that reserved the same
    /// total out of different line sets would pass the case above and still be
    /// one refactor away from failing it.
    @MainActor
    func testTheLineSetIsTheSameInEveryStateARowCanBeIn() throws {
        let provider = try Self.connectedProvider()
        try sweep("lines-across-states") { appearance, at in
            let sets = Self.states(for: provider).map { state in
                (state.name, Self.reservation(appearance: appearance, provider: provider, result: state.result))
            }
            for (name, geometry) in sets.dropFirst() {
                XCTAssertEqual(
                    geometry, sets[0].1,
                    "\(at): \(name) measured differently from \(sets[0].0)"
                )
            }
        }
    }

    /// And the same three states as the row actually draws them, because the
    /// reservation is read by the card's corner radius and by nothing else.
    ///
    /// One point of tolerance, and the point is measured rather than rounded off.
    /// Of the 45 configurations exactly two are not equal to the digit — Minimal
    /// at compact and at cozy, both at 85% type — and there for a reason that is
    /// the rail's and not the line's: those are the configurations where the row
    /// is governed by its title line, and the 14pt square the rail draws a
    /// spinner or a warning triangle in stands a point above the box the figure
    /// beside it takes at 11pt type. 35pt waiting and failed against 34pt
    /// reporting. What this case exists to catch is a whole line, which is 13pt
    /// at the smallest density and was what these rows differed by before the
    /// reservation stopped reading the fetch.
    @MainActor
    func testTheRowDrawsTheSameHeightInEveryStateItCanBeIn() throws {
        let provider = try Self.connectedProvider()
        try sweep("drawn-across-states") { appearance, at in
            let heights = Self.states(for: provider).map { state in
                (state.name, Self.drawnHeight(appearance: appearance, provider: provider, result: state.result))
            }
            let spread = (heights.map(\.1).max() ?? 0) - (heights.map(\.1).min() ?? 0)
            XCTAssertLessThanOrEqual(
                spread, 1.0,
                "\(at): the row drew \(heights.map { "\($0.0) \($0.1)pt" }.joined(separator: ", "))"
            )
        }
    }

    /// And the reading itself is not an input at all: the same row at 0%, at 99%
    /// and at a three-digit reading reserves one height. The rails are reserved
    /// rather than measured, so this is the case that fails if anyone ever
    /// reaches for a `GeometryReader` or a measured string.
    @MainActor
    func testWhatTheReadingSaysIsNotAnInput() throws {
        let provider = try Self.connectedProvider()
        try sweep("height-across-readings") { appearance, at in
            let heights = [0.0, 0.09, 0.42, 0.99, 1.0].map { percent in
                Self.reservation(
                    appearance: appearance,
                    provider: provider,
                    result: .success(Self.reading(percent, provider: provider))
                ).height
            }
            XCTAssertEqual(heights.max(), heights.min(), "\(at): the reading moved the row to \(heights)")
        }
    }

    /// A row nobody has connected is the one short row, and it must stay short:
    /// fifteen of them is what a first launch looks like, and reserving a meter
    /// slot and a line under each would be fifteen rows of air explaining that
    /// there is nothing to explain.
    @MainActor
    func testAnUnconnectedRowReservesNothingUnderItsTitle() throws {
        let provider = try Self.connectedProvider()
        provider.isAuthenticated = false
        defer { provider.isAuthenticated = true }
        try sweep("unconnected") { appearance, at in
            let short = Self.reservation(appearance: appearance, provider: provider, result: nil)
            let reporting = Self.reservation(
                appearance: appearance,
                provider: provider,
                result: .success(Self.reading(0.42, provider: provider))
            )
            XCTAssertLessThan(
                short.height, reporting.height,
                "\(at): a row with no credential and no snapshot reserved a detail block"
            )
        }
    }

    /// The other half of the same bit, and the state the panel got wrong: a
    /// session that expires while the panel is open clears `isAuthenticated`
    /// with the failure already stored. The row has something to say and must
    /// keep the box to say it in — keyed off "does this row hold a snapshot"
    /// rather than off the credential alone.
    @MainActor
    func testARowThatHasReportedKeepsItsBoxWhenItsSessionDies() throws {
        let provider = try Self.connectedProvider()
        try sweep("expired") { appearance, at in
            provider.isAuthenticated = true
            let live = Self.reservation(
                appearance: appearance, provider: provider, result: .failure(.parse("timed out"))
            )
            provider.isAuthenticated = false
            let expired = Self.reservation(
                appearance: appearance, provider: provider, result: .failure(.sessionExpired)
            )
            provider.isAuthenticated = true
            XCTAssertEqual(
                expired, live,
                "\(at): the row collapsed when its credential was discarded under it"
            )
        }
    }

    // MARK: - The chips fit the line they ride on

    /// The width contract, as arithmetic: **what the row reserves for the chips
    /// is at least what the row can draw in them.**
    ///
    /// The drawn run is `chipLimit` chips of at most `chipCap` each, the
    /// `Space.medium` gaps between them, and — in the one case `chipSplit`
    /// overruns the limit by an item — a "+N" beside them. Add the caption's own
    /// gap and the spend it cannot give back, and the total may not exceed the
    /// text column. It did, by 40pt at the shipped width, and because
    /// `SecondaryChipRun` is `.fixedSize()` the excess went past the panel's edge
    /// and took every other row's alignment with it.
    ///
    /// Written out of `Tokens` rather than out of `RowGeometry`'s own helpers,
    /// which are private for exactly this reason: an assertion that asks the
    /// subject for both sides of the sum can only fail if the subject disagrees
    /// with itself.
    @MainActor
    func testTheChipReservationIsAnUpperBoundOnWhatTheRunCanDraw() {
        let appearance = settings("chip-bound")
        for density in Self.densities {
            for scale in Self.textScales {
                for panelWidth in Self.panelWidths {
                    appearance.density = density
                    appearance.textScale = scale
                    appearance.panelWidth = panelWidth
                    let at = "\(density.rawValue)/\(Int(scale * 100))%/\(Int(panelWidth))pt"

                    let size = appearance.metrics.detailSize
                    let column = RowGeometry(
                        metrics: appearance.metrics,
                        showsPercentage: appearance.showsPercentage,
                        meterStyle: appearance.meterStyle,
                        logoStyle: appearance.logoStyle,
                        logoSize: CGFloat(appearance.logoSize),
                        panelWidth: CGFloat(appearance.panelWidth),
                        rowActions: appearance.rowActions,
                        lines: []
                    ).textColumnWidth

                    for carriesSpend in [false, true] {
                        let limit = RowGeometry.chipLimit(
                            textColumnWidth: column, chipSize: size, carriesSpend: carriesSpend
                        )
                        let cap = RowGeometry.chipCap(
                            textColumnWidth: column, chipSize: size, carriesSpend: carriesSpend
                        )
                        // What `SpendFigure` holds at the head of the line: nine
                        // mono cells for "$8,700.47", the gap, and three for the
                        // "est." qualifier.
                        let spend = carriesSpend
                            ? Tokens.figureWidth(size, digits: 9)
                                + Tokens.Space.snug
                                + Tokens.figureWidth(size, digits: 3)
                            : 0
                        // "+99", which `chipSplit` puts beside its one real chip
                        // rather than in place of it when the line holds one.
                        let overflow = Tokens.figureWidth(size, digits: 3)

                        for chips in 1...limit {
                            let n = CGFloat(chips)
                            let run = n * cap + (n - 1) * Tokens.Space.medium
                            XCTAssertLessThanOrEqual(
                                spend + Tokens.Space.medium + run, column,
                                "\(at): \(chips) chips of \(cap)pt beside a \(spend)pt spend "
                                + "overrun a \(column)pt text column"
                            )
                        }
                        // The overrun case: the limit's worth of chips is
                        // `max(1, limit - 1)`, and the "+N" is an item of its own.
                        let shown = CGFloat(max(1, limit - 1))
                        let overrun = shown * cap + shown * Tokens.Space.medium + overflow
                        XCTAssertLessThanOrEqual(
                            spend + Tokens.Space.medium + overrun, column,
                            "\(at): \(Int(shown)) chips and a +N beside a \(spend)pt spend "
                            + "overrun a \(column)pt text column"
                        )
                    }
                }
            }
        }
    }

    /// The same bound seen from the drawing rather than from the arithmetic: the
    /// run a row would actually build, hosted and measured, against the cap the
    /// row reserved for it.
    ///
    /// This is the half the arithmetic cannot check. The estimate and the drawing
    /// were two different models of one chip — the estimate counted a capsule and
    /// a dot, the drawing counted a label with no ceiling on it — and each was
    /// self-consistent. Only measuring the drawn view against the reserved number
    /// catches that, which is why the fixture is the worst payload the app has
    /// ever been sent: a seven-character label beside a nine-character reading,
    /// and a nineteen-character label beside a percentage.
    @MainActor
    func testTheDrawnChipNeverExceedsTheWidthReservedForIt() {
        let appearance = settings("chip-drawn")
        let worst = [
            UsageMetric(label: "30 days", used: 9_767_200_000, limit: 0, unit: "tokens"),
            UsageMetric(label: "Weekly · all models", used: 61, limit: 100, unit: "%"),
            UsageMetric(label: "Weekly · per-model", used: 8, limit: 100, unit: "%")
        ]
        for density in Self.densities {
            for scale in Self.textScales {
                for panelWidth in Self.panelWidths {
                    appearance.density = density
                    appearance.textScale = scale
                    appearance.panelWidth = panelWidth
                    let at = "\(density.rawValue)/\(Int(scale * 100))%/\(Int(panelWidth))pt"

                    let column = RowGeometry(
                        metrics: appearance.metrics,
                        showsPercentage: appearance.showsPercentage,
                        meterStyle: appearance.meterStyle,
                        logoStyle: appearance.logoStyle,
                        logoSize: CGFloat(appearance.logoSize),
                        panelWidth: CGFloat(appearance.panelWidth),
                        rowActions: appearance.rowActions,
                        lines: []
                    ).textColumnWidth
                    let cap = RowGeometry.chipCap(
                        textColumnWidth: column,
                        chipSize: appearance.metrics.detailSize,
                        carriesSpend: true
                    )

                    for metric in worst {
                        let chip = SecondaryChip(
                            metric: metric, accent: .accentColor, appearance: appearance, cap: cap
                        )
                        let host = NSHostingView(rootView: AnyView(chip))
                        let drawn = host.fittingSize.width
                        XCTAssertLessThanOrEqual(
                            drawn, cap + 0.5,
                            "\(at): \"\(metric.label)\" drew \(drawn)pt inside a \(cap)pt cap"
                        )
                    }
                }
            }
        }
    }

    // MARK: - Fixtures

    /// The three states a row that holds something can be in, in the order a real
    /// launch meets them.
    @MainActor
    private static func states(
        for provider: AnyUsageProvider
    ) -> [(name: String, result: Result<UsageData, ProviderError>?)] {
        [
            ("waiting", nil),
            // A reading with nothing for the caption to say: no reset date, so no
            // countdown, and a percentage window, whose amount is its own name.
            // This is the state that used to be one line shorter than the two
            // beside it.
            ("reporting", .success(reading(0.42, provider: provider))),
            ("failed", .failure(.parse("the provider answered with something this parser could not read")))
        ]
    }

    @MainActor
    private static func reading(_ percent: Double, provider: AnyUsageProvider) -> UsageData {
        UsageData(
            providerID: provider.id,
            primary: UsageMetric(label: "5h", used: percent * 100, limit: 100, unit: "%")
        )
    }

    /// What `ProviderRow` reserves for this state, asked of the row itself.
    ///
    /// The row's own `geometry`, not a `RowGeometry` this file builds from the
    /// same settings — a test that reconstructs the predicate it is checking can
    /// only ever agree with itself, and "the reservation and the drawing were
    /// each self-consistent" is the exact shape of both defects this suite exists
    /// for.
    @MainActor
    private static func reservation(
        appearance: AppearanceSettings,
        provider: AnyUsageProvider,
        result: Result<UsageData, ProviderError>?
    ) -> RowGeometry {
        row(appearance: appearance, provider: provider, result: result).geometry
    }

    /// Both stores empty and neither of them the shared one: a budget on the
    /// service under test adds a meter to the row, and a pace line adds a
    /// caption, so whatever the machine running the suite has been collecting
    /// would decide the height being measured.
    @MainActor
    private static func row(
        appearance: AppearanceSettings,
        provider: AnyUsageProvider,
        result: Result<UsageData, ProviderError>?
    ) -> ProviderRow {
        ProviderRow(
            provider: provider,
            result: result,
            onSignIn: {},
            appearance: appearance,
            budgets: BudgetStore(store: scratchDefaults("budgets")),
            trend: UsageTrendStore(store: scratchDefaults("trends"))
        )
    }

    @MainActor
    private static func scratchDefaults(_ name: String) -> UserDefaults {
        let domain = "aibars.row-reservation-tests.\(name)"
        guard let store = UserDefaults(suiteName: domain) else { return .standard }
        store.removePersistentDomain(forName: domain)
        return store
    }

    /// The height the row *draws*, which is the number `MenuBarExtra` actually
    /// sizes its window to.
    ///
    /// The reservation above is read by one thing — the card's corner radius — so
    /// on its own it can be right while the row is wrong, which is how the panel
    /// shipped with a documented invariant it did not hold. The two are asserted
    /// against the same three states so neither can drift alone.
    @MainActor
    private static func drawnHeight(
        appearance: AppearanceSettings,
        provider: AnyUsageProvider,
        result: Result<UsageData, ProviderError>?
    ) -> CGFloat {
        let hosted = row(appearance: appearance, provider: provider, result: result)
            .frame(width: CGFloat(appearance.panelWidth))
        let host = NSHostingView(rootView: AnyView(hosted))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize.height
    }

    @MainActor
    private static func connectedProvider() throws -> AnyUsageProvider {
        let state = AppState()
        let provider = try XCTUnwrap(
            state.providers.first(where: { $0.serviceID == "claude" }),
            "the app shipped without the service this suite measures"
        )
        provider.isAuthenticated = true
        return provider
    }
}
