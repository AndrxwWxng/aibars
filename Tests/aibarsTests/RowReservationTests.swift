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

    /// The whole space, named once: five presets, three densities, both ends of
    /// the text-size slider plus the middle, and the sparkline switch in both
    /// positions. 90 configurations, and each case below walks all of them.
    ///
    /// Density and text scale are swept *over* each preset rather than left to
    /// it, because they are the two settings that move every box on the row —
    /// and a preset pins one value of each, so a preset sweep alone measures five
    /// points of a 90-point space.
    ///
    /// The sparkline is swept for a different reason. It is the first optional
    /// drawing on the row that *reserves* — the pace line costs nothing when it
    /// says nothing, and this costs its slot whether or not there is a day of
    /// history behind it. That is the whole risk in it: a slot whose drawn height
    /// and reserved height disagree by a point reintroduces exactly the resize
    /// this suite exists to prevent, and it would only appear with the switch on.
    /// Overridden after `apply(preset)` rather than left to the preset, so the
    /// space stays 90 points wide on the day a preset turns the trace on.
    private static let densities = AppearanceSettings.Density.allCases
    private static let textScales: [Double] = [0.85, 1.0, 1.30]
    private static let sparklines: [Bool] = [false, true]

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
                    for sparkline in Self.sparklines {
                        appearance.apply(preset)
                        appearance.density = density
                        appearance.textScale = scale
                        appearance.showsRowSparkline = sparkline
                        try body(
                            appearance,
                            "\(preset.rawValue)/\(density.rawValue)/\(Int(scale * 100))%"
                                + "/trace \(sparkline ? "on" : "off")"
                        )
                    }
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

    /// And the same state as the row actually **draws** it, which is the layer
    /// the case above was missing and the defect that layer was hiding.
    ///
    /// The reservation was right and the drawing was not. `RowGeometry` holds the
    /// title line at `Control.rowIconButton` whenever `rowActions != .never`, and
    /// `ProviderRow` drew `RowActions` only `if provider.isAuthenticated` — so
    /// exactly the state the case above exists to protect, a row that has
    /// reported and whose session then dies, kept its reservation and lost its
    /// drawing. Measured on a hosted row at 356pt: **−4pt at cozy/85% and
    /// compact/85%, −2pt at cozy/100%**, which is 8–16pt of panel across four
    /// rows and 30–60pt across fifteen. `SessionStore` clears `isAuthenticated`
    /// in the same main-actor turn it stores the failure, so with the panel open
    /// that is `MenuBarExtra` resizing its window under the pointer.
    ///
    /// The lesson is the one `Lines.forecast` already taught and this suite still
    /// had a hole for: a reservation asserted at five call sites and never once
    /// hosted reads as coverage. Every state named in the reservation cases now
    /// has a drawn case beside it.
    @MainActor
    func testARowThatHasReportedDrawsTheSameBoxWhenItsSessionDies() throws {
        let provider = try Self.connectedProvider()
        try sweep("expired-drawn") { appearance, at in
            provider.isAuthenticated = true
            let live = Self.drawnHeight(
                appearance: appearance, provider: provider, result: .failure(.parse("timed out"))
            )
            provider.isAuthenticated = false
            let expired = Self.drawnHeight(
                appearance: appearance, provider: provider, result: .failure(.sessionExpired)
            )
            // And with a reading behind it, which is the shape a real expiry
            // takes: the last refresh succeeded, the next one found no session.
            let expiredWithReading = Self.drawnHeight(
                appearance: appearance,
                provider: provider,
                result: .success(Self.reading(0.42, provider: provider))
            )
            provider.isAuthenticated = true
            XCTAssertEqual(
                expired, live, accuracy: 1.0,
                "\(at): the row shrank when its credential was discarded under it — "
                    + "\(live)pt live against \(expired)pt expired"
            )
            XCTAssertEqual(
                expiredWithReading, live, accuracy: 1.0,
                "\(at): a row holding a reading shrank when its credential died — "
                    + "\(live)pt live against \(expiredWithReading)pt expired"
            )
        }
    }

    // MARK: - The settings the preset sweep cannot reach

    /// The four settings that reach a row's *vertical* layout, swept as
    /// themselves rather than through the presets that pin them.
    ///
    /// Every other case in this file walks preset × density × scale × trace, and
    /// a preset fixes `meterStyle`, `secondaryWindows`, `showsAmounts` and
    /// `showsCountdowns` in one go — so five presets sample five points of the
    /// 36 those four axes span, and all four are switches the Appearance pane
    /// offers separately. That gap hid a real defect: under `.ring` with the
    /// window line unreserved, `ProviderRow.stated` returned a `VStack` whose two
    /// children were both conditional and both absent, and an empty container is
    /// still a subview of a stack that spaces its children. The row stood
    /// `contentSpacing` taller while waiting and while failed — 4 / 6 / 8pt at
    /// compact / cozy / comfortable, 8pt a row and 120pt down a panel of fifteen
    /// — and **shrank when its first answer landed**, which is the resize this
    /// whole suite exists to make impossible, seen from its other side.
    ///
    /// No shipped preset lands there. That is exactly why it is worth sweeping:
    /// the settings a preset does not visit are the settings nothing measures.
    ///
    /// The quotaless payload is here for the same reason — it is a fifth state
    /// the row can be in, it takes a different branch of `primaryMetric` from
    /// every other case in this file, and nothing else draws it.
    @MainActor
    func testTheRowDrawsOneHeightAcrossTheRawSettingAxes() throws {
        let provider = try Self.connectedProvider()
        let appearance = settings("raw-axes")
        let quotaless = UsageData(
            providerID: provider.id,
            primary: UsageMetric(label: "Status", used: 0, limit: 0, unit: "")
        )
        for density in Self.densities {
            for meter in AppearanceSettings.MeterStyle.allCases {
                for windows in AppearanceSettings.SecondaryWindowStyle.allCases {
                    for amounts in [false, true] {
                        for countdowns in [false, true] {
                            appearance.apply(.comfortable)
                            appearance.density = density
                            appearance.meterStyle = meter
                            appearance.secondaryWindows = windows
                            appearance.showsAmounts = amounts
                            appearance.showsCountdowns = countdowns
                            let at = "\(density.rawValue)/\(meter.rawValue)/\(windows.rawValue)"
                                + "/amounts \(amounts)/countdowns \(countdowns)"
                            let states: [(String, Result<UsageData, ProviderError>?)] = [
                                ("waiting", nil),
                                ("reporting", .success(Self.reading(0.42, provider: provider))),
                                ("quotaless", .success(quotaless)),
                                ("failed", .failure(.parse("the provider answered with something unreadable")))
                            ]
                            let heights: [(String, CGFloat)] = states.map { state in
                                (
                                    state.0,
                                    Self.drawnHeight(
                                        appearance: appearance, provider: provider, result: state.1
                                    )
                                )
                            }
                            let spread = (heights.map(\.1).max() ?? 0) - (heights.map(\.1).min() ?? 0)
                            XCTAssertLessThanOrEqual(
                                spread, 1.0,
                                "\(at): the row drew "
                                    + heights.map { "\($0.0) \($0.1)pt" }.joined(separator: ", ")
                            )
                        }
                    }
                }
            }
        }
    }

    // MARK: - The trace reserves what it draws

    /// **The one thing the trace may cost, asked of the row rather than of the
    /// line set.** Turning the switch on adds `contentSpacing + sparklineHeight`
    /// and nothing else, in every state the row can be in.
    ///
    /// The trace is the first optional drawing on a row that reserves. The pace
    /// line is on by default precisely because it costs nothing when it says
    /// nothing; this costs its slot on a fresh install with no history at all, so
    /// the reservation is the only thing standing between the feature and a panel
    /// that grows a day after a service is connected.
    @MainActor
    func testTheTraceCostsExactlyItsOwnBlockInEveryState() throws {
        let provider = try Self.connectedProvider()
        let appearance = settings("trace-cost")
        for preset in AppearanceSettings.Preset.allCases {
            for density in Self.densities {
                for scale in Self.textScales {
                    for state in Self.states(for: provider) {
                        appearance.apply(preset)
                        appearance.density = density
                        appearance.textScale = scale
                        let at = "\(preset.rawValue)/\(density.rawValue)/\(Int(scale * 100))%/\(state.name)"

                        appearance.showsRowSparkline = false
                        let without = Self.reservation(
                            appearance: appearance, provider: provider, result: state.result
                        ).height
                        appearance.showsRowSparkline = true
                        let with = Self.reservation(
                            appearance: appearance, provider: provider, result: state.result
                        ).height

                        XCTAssertEqual(
                            with - without,
                            appearance.metrics.contentSpacing + appearance.metrics.sparklineHeight,
                            accuracy: 1e-9,
                            "\(at): the trace cost the row \(with - without)pt"
                        )
                    }
                }
            }
        }
    }

    /// And the row *draws* that same block — which is the half the reservation
    /// cannot see on its own, since `RowGeometry.height` is read by the card's
    /// corner radius and by nothing else.
    ///
    /// Measured with an empty store, deliberately: a row with no trace in it yet
    /// must draw exactly as tall as the slot reserved for it, because that is the
    /// state every row is in on the first launch after the switch is turned on.
    /// One point of tolerance, the same the state-constancy case takes and for
    /// the same reason — the rail's 14pt glyph square, not the trace.
    @MainActor
    func testTheRowDrawsTheTraceSlotItReserved() throws {
        let provider = try Self.connectedProvider()
        let appearance = settings("trace-drawn")
        for density in Self.densities {
            for scale in Self.textScales {
                appearance.density = density
                appearance.textScale = scale
                let at = "\(density.rawValue)/\(Int(scale * 100))%"
                let result = Result<UsageData, ProviderError>.success(
                    Self.reading(0.42, provider: provider)
                )

                appearance.showsRowSparkline = false
                let without = Self.drawnHeight(
                    appearance: appearance, provider: provider, result: result
                )
                appearance.showsRowSparkline = true
                let with = Self.drawnHeight(
                    appearance: appearance, provider: provider, result: result
                )

                XCTAssertEqual(
                    with - without,
                    appearance.metrics.contentSpacing + appearance.metrics.sparklineHeight,
                    accuracy: 1.0,
                    "\(at): the row drew \(with - without)pt where it reserved "
                    + "\(appearance.metrics.contentSpacing + appearance.metrics.sparklineHeight)pt"
                )
            }
        }
    }

    // MARK: - A pace arriving cannot change a row's height

    /// **The assertion the fold exists for, and the one nothing in the suite
    /// made.**
    ///
    /// One provider, one reading, one set of settings, two rows: one built
    /// against a trend store holding half an hour of rising samples, one against a
    /// store with nothing in it. The store is the *only* difference between them,
    /// and the two drawn heights must be the same number.
    ///
    /// What it would have reported against the block. `ForecastLine` was a fourth
    /// child of the row's detail stack, inserted when — and only when — the fit
    /// produced a phrase, so the paced row drew `contentSpacing +
    /// lineBox(captionSize)` taller than the unpaced one: 19pt at cozy/100%, and
    /// about 171pt down a nine-row panel. The comparison is exact rather than
    /// tolerant, so every one of the 90 configurations this sweeps would have
    /// failed, each naming its own — and a 19pt gap is not a rounding argument at
    /// any density. Nothing measured the two stores against each other, which is
    /// how a correct reservation for a block nothing inserted read as coverage for
    /// two releases.
    ///
    /// The premise is asserted before the heights are compared, and that is not
    /// ceremony: a fixture that quietly stopped producing a projection — a
    /// tightened refusal, a shortened staleness limit — would leave two identical
    /// unpaced rows and a test that passes by measuring nothing. So the paced
    /// store must resolve a sentence and the empty one must not.
    ///
    /// The store is fed rather than stubbed. `UsageTrendStore.record` is what the
    /// refresh loop calls, so five samples five minutes apart on a rising slope is
    /// the same ring a real half-hour at the keyboard builds, refusals and gap
    /// rule included.
    @MainActor
    func testAPaceArrivingCannotChangeARowsHeight() throws {
        let provider = try Self.connectedProvider()
        let now = Date()
        let paced = try Self.risingTrend(for: provider, now: now)
        let silent = UsageTrendStore(store: Self.scratchDefaults("pace-silent"), now: { now })
        let result = Result<UsageData, ProviderError>.success(Self.reading(0.42, provider: provider))

        // The premise, both halves of it.
        XCTAssertNotNil(
            ForecastLine.text(
                projection: paced.projection(for: provider.id), now: now, showsPace: true
            ),
            "the fixture stopped producing a pace, so this case measures two identical rows"
        )
        XCTAssertNil(
            ForecastLine.text(
                projection: silent.projection(for: provider.id), now: now, showsPace: true
            ),
            "the empty store produced a pace, so this case has no control"
        )

        try sweep("pace-arriving") { appearance, at in
            let with = Self.drawnHeight(
                appearance: appearance, provider: provider, result: result, trend: paced
            )
            let without = Self.drawnHeight(
                appearance: appearance, provider: provider, result: result, trend: silent
            )
            XCTAssertEqual(
                with, without,
                "\(at): the row drew \(with)pt with a pace on it and \(without)pt without one"
            )
        }
    }

    /// And the run it folded into is a real drawing, which is what makes the case
    /// above a claim about the row rather than about a sentence nobody draws.
    ///
    /// The pace takes **width and never height**: measured on the caption line
    /// itself at the width it asks for, the line is wider with the claim on it and
    /// exactly as tall. Then the run is measured on its own, against the line it
    /// rides — never taller than it, never shorter than the caption box it is held
    /// at — which is why the equality above holds by construction rather than by
    /// luck. The run is set at `captionSize`, and `captionSize` is under
    /// `detailSize` at every density and every text scale, so there is no
    /// arrangement of words in which the claim is the tallest thing on the row.
    @MainActor
    func testThePaceTakesWidthOnTheCaptionLineAndNeverHeight() throws {
        let appearance = settings("pace-on-the-line")
        let provider = try Self.connectedProvider()
        let now = Date()
        let trend = try Self.risingTrend(for: provider, now: now)
        let phrase = try XCTUnwrap(
            ForecastLine.text(projection: trend.projection(for: provider.id), now: now, showsPace: true)
        )

        for density in Self.densities {
            for scale in Self.textScales {
                appearance.density = density
                appearance.textScale = scale
                let metrics = appearance.metrics
                let at = "\(density.rawValue)/\(Int(scale * 100))%"

                func caption(_ pace: String?) -> CGSize {
                    let line = MetricCaption(
                        metric: UsageMetric(
                            label: "5h session", used: 42, limit: 100, unit: "%",
                            resetDate: now.addingTimeInterval(4_800)
                        ),
                        accent: .accentColor,
                        appearance: appearance,
                        pace: pace
                    )
                    // `fixedSize` and not a wide frame: it asks the line for its
                    // *ideal* width, which is the only measurement that can show
                    // a run being drawn — inside a frame the line fills the frame
                    // and the two are the same number whatever is on them. It
                    // also means `ViewThatFits` is offered everything it asks
                    // for, so the richest candidate is the one measured. The
                    // narrow end, where the claim is the first candidate dropped,
                    // is `ForecastLineTests`' subject and not this one's.
                    return NSHostingView(rootView: AnyView(line.fixedSize())).fittingSize
                }

                let with = caption(phrase)
                let without = caption(nil)
                XCTAssertGreaterThan(
                    with.width, without.width,
                    "\(at): the line is \(with.width)pt wide either way, so the pace was not drawn at all "
                    + "and the height case above is comparing two identical rows"
                )
                XCTAssertEqual(
                    with.height, without.height, accuracy: 0.5,
                    "\(at): the caption is \(with.height)pt with the pace on it and \(without.height)pt without"
                )

                // Why it cannot be otherwise, measured rather than asserted of the
                // arrangement: the run is set at `captionSize`, which is below
                // `detailSize` at every density and every scale, so it is never
                // the tallest thing on the line it rides. That is `ForecastLine`'s
                // own claim — "there is no arrangement of words in which it is the
                // tallest thing on the row" — and it is the reason the equality
                // above holds by construction and not by luck.
                let block = NSHostingView(
                    rootView: AnyView(ForecastLine(phrase: phrase, appearance: appearance))
                ).fittingSize
                XCTAssertLessThanOrEqual(
                    block.height, without.height,
                    "\(at): the pace run measures \(block.height)pt on a \(without.height)pt line"
                )
                XCTAssertGreaterThanOrEqual(
                    block.height, Tokens.lineBox(metrics.captionSize),
                    "\(at): the run is drawn under the caption box it is held at"
                )
            }
        }
    }

    // MARK: - Width may move things sideways and may never move them down

    /// **The panel getting wider cannot make a row taller.**
    ///
    /// This became a claim worth asserting when the meter stopped being a
    /// constant. `MeterGeometry.trackWidth(in:)` grows the bar with the column, so
    /// the slot is now sized from a `GeometryReader` — and a `GeometryReader` is
    /// greedy in *both* axes by default. `TrackWidth` pins the height around it,
    /// but "the modifier has a `.frame(height:)` on the outside" is the kind of
    /// thing that is true until somebody simplifies it, and the failure mode is
    /// the one the whole suite exists for: a row that changes height when the user
    /// drags a width slider, in a panel `MenuBarExtra` sizes to its content.
    ///
    /// The moved countdown is under test here too, and by the same measurement:
    /// `MetricCaption.countdownRidesTheEdge` is a width decision that reads the
    /// column, so it also has to be provably free of height.
    ///
    /// Four widths crossed with the full 90-configuration space, `XCTAssertEqual`
    /// with no tolerance, against the row's *drawn* height rather than its
    /// reservation — the reservation cannot see this at all, because `panelWidth`
    /// reaches `RowGeometry` only through `textColumnWidth` and never through any
    /// term of the height. That is exactly why the drawing is what is measured:
    /// the arithmetic is trivially width-free and the layout is where it could
    /// stop being so.
    ///
    /// The premise is asserted first so the case cannot pass by measuring a bar
    /// that never grew: at the shipped density the 300pt and 520pt columns give
    /// 160pt and 200pt of track.
    @MainActor
    func testTheTrackGrowingWithThePanelCannotChangeARowsHeight() throws {
        let provider = try Self.connectedProvider()
        let data = Self.reading(0.92, provider: provider)

        try sweep("track-growth-is-width-only") { appearance, at in
            var heights: [Double: CGFloat] = [:]
            var tracks: [Double: CGFloat] = [:]
            for width in Self.panelWidths {
                appearance.panelWidth = width
                heights[width] = Self.drawnHeight(
                    appearance: appearance, provider: provider, result: .success(data)
                )
                tracks[width] = MeterGeometry.trackWidth(
                    in: Self.reservation(
                        appearance: appearance, provider: provider, result: .success(data)
                    ).textColumnWidth
                )
            }

            // The bar really did grow, or the equality below is about nothing.
            let narrow = try XCTUnwrap(tracks[300])
            let wide = try XCTUnwrap(tracks[520])
            XCTAssertGreaterThan(
                wide, narrow,
                "\(at): the track is \(narrow)pt at 300 and \(wide)pt at 520, so it did not grow "
                    + "and this case is measuring a constant"
            )

            let expected = try XCTUnwrap(heights[300])
            for width in Self.panelWidths {
                XCTAssertEqual(
                    try XCTUnwrap(heights[width]), expected,
                    "\(at): the row draws \(heights[width] ?? -1)pt at \(width) against \(expected)pt "
                        + "at 300 — width has reached the height"
                )
            }
        }
    }

    /// And the same fact about the countdown, measured on the line it moved to
    /// rather than on the row around it.
    ///
    /// `countdownRidesTheEdge` takes the countdown out of the caption's sentence
    /// and puts it in the caption's trailing slot — the slot the chips ride when
    /// there are any. That is a *rearrangement* of one line, so the thing to prove
    /// is that the line is the same box either way: the caption is one `lineBox`
    /// whatever is on it, and a row whose caption grew when a reset date arrived
    /// would be the resize this suite exists to prevent, arriving through a clock.
    ///
    /// The premise first, as `testThePaceTakesWidthOnTheCaptionLineAndNeverHeight`
    /// does: the line is measurably wider with the countdown on it, so the height
    /// equality is not two measurements of an identical view.
    @MainActor
    func testTheCountdownTakesWidthOnTheCaptionLineAndNeverHeight() throws {
        let appearance = settings("countdown-on-the-edge")
        let now = Date()

        for density in Self.densities {
            for scale in Self.textScales {
                appearance.density = density
                appearance.textScale = scale
                let at = "\(density.rawValue)/\(Int(scale * 100))%"

                func caption(_ reset: Date?) -> CGSize {
                    let line = MetricCaption(
                        metric: UsageMetric(
                            label: "Daily", used: 100, limit: 100, unit: "%", resetDate: reset
                        ),
                        accent: .accentColor,
                        appearance: appearance
                    )
                    // `fixedSize`, for the reason the pace case gives: inside a
                    // frame the line fills the frame and both arrangements measure
                    // the same number whatever is drawn on them.
                    return NSHostingView(rootView: AnyView(line.fixedSize())).fittingSize
                }

                let with = caption(now.addingTimeInterval(11 * 3_600))
                let without = caption(nil)
                XCTAssertGreaterThan(
                    with.width, without.width,
                    "\(at): the line is \(with.width)pt wide either way, so the countdown was not "
                        + "drawn at all and the height check below is comparing two identical rows"
                )
                XCTAssertEqual(
                    with.height, without.height, accuracy: 0.5,
                    "\(at): the caption is \(with.height)pt with the countdown at its trailing edge "
                        + "and \(without.height)pt without one"
                )
            }
        }
    }

    // MARK: - The further windows are reserved from the settings

    /// **What the fetch came back with is not an input to the row's height.**
    ///
    /// Under `secondaryWindows == .expanded` — which the **Dashboard** preset
    /// ships, with a limit of six — the row drew one line per window the service
    /// reported and reserved none of them. So a service answering with three grew
    /// its row 3 × (contentSpacing + lineBox(detailSize)) = 60pt at cozy/100% the
    /// moment the answer landed, and `MenuBarExtra`, which sizes its window to its
    /// content, moved the panel under the pointer. A service that answered with
    /// one on Monday and three on Tuesday did it again.
    ///
    /// Four payloads, differing in nothing but how many further windows they
    /// carry: none, one, three, and the six the stepper allows. One height. The
    /// counts are the four the panel actually meets — a service with no further
    /// windows at all is the common case and is the one that pays for this, so it
    /// is measured rather than assumed.
    @MainActor
    func testWhatTheFetchReturnedIsNotAnInputToTheLadder() throws {
        let provider = try Self.connectedProvider()
        let appearance = settings("ladder-across-payloads")
        for density in Self.densities {
            for scale in Self.textScales {
                for limit in [1, 3, 6] {
                    appearance.density = density
                    appearance.textScale = scale
                    appearance.secondaryWindows = .expanded
                    appearance.secondaryWindowLimit = limit
                    let at = "\(density.rawValue)/\(Int(scale * 100))%/limit \(limit)"

                    let heights = [0, 1, 3, 6].map { count in
                        (count, Self.drawnHeight(
                            appearance: appearance,
                            provider: provider,
                            result: .success(Self.reading(0.42, provider: provider, windows: count))
                        ))
                    }
                    let spread = (heights.map(\.1).max() ?? 0) - (heights.map(\.1).min() ?? 0)
                    XCTAssertEqual(
                        spread, 0,
                        "\(at): the row drew "
                        + heights.map { "\($0.0) windows \($0.1)pt" }.joined(separator: ", ")
                    )
                }
            }
        }
    }

    /// And the ladder is the height it reserved: one line and the pitch in front
    /// of it per rung, drawn as well as reserved.
    ///
    /// This is the half the reservation cannot check on its own — `RowGeometry` is
    /// read by the card's corner radius and by nothing else — and it is the half
    /// that says the empty rungs are really there. Measured off a payload with no
    /// further windows in it at all, deliberately: that is the row that has to
    /// hold the ladder open, and a row whose rungs appeared only when there was
    /// something to put on them would pass every reservation case in this file and
    /// still resize the panel.
    ///
    /// The step is measured between limits rather than against a total, so the
    /// title line, the meter block and the trace cancel and what is left is one
    /// rung.
    ///
    /// Two assertions, because the rung has two things to be right about: it is
    /// the pitch `RowGeometry` reserved, and every rung is the same rung.
    ///
    /// Both take a point of tolerance and the point is measured rather than
    /// waved at. A hosted view reports whole points, and a line of type rounds up
    /// to them: at cozy/130% `lineBox(14.3)` is 17.3 and a drawn line is 18.0, so
    /// the drawing runs 0.7pt a rung over the reservation — the same slack the
    /// reservation has always taken against a caption, in the one direction that
    /// cannot clip. What no tolerance covers, and what the case beside this one
    /// asserts to the digit, is a rung that changes height according to whether
    /// the fetch put anything on it.
    @MainActor
    func testTheLadderDrawsEveryRungItReserved() throws {
        let provider = try Self.connectedProvider()
        let appearance = settings("ladder-drawn")
        let result = Result<UsageData, ProviderError>.success(
            Self.reading(0.42, provider: provider, windows: 0)
        )
        for density in Self.densities {
            for scale in Self.textScales {
                appearance.density = density
                appearance.textScale = scale
                appearance.secondaryWindows = .expanded
                let metrics = appearance.metrics
                let at = "\(density.rawValue)/\(Int(scale * 100))%"
                let reserved = metrics.contentSpacing + Tokens.lineBox(metrics.detailSize)

                appearance.secondaryWindowLimit = 1
                let one = Self.drawnHeight(appearance: appearance, provider: provider, result: result)
                appearance.secondaryWindowLimit = 6
                let six = Self.drawnHeight(appearance: appearance, provider: provider, result: result)
                // Off the widest span rather than off one step, because a hosted
                // view reports a whole number of points: a 21.2pt rung shows as a
                // 21pt step and a 22pt one, and five of them average back to what
                // it actually is.
                let rung = (six - one) / 5
                XCTAssertEqual(
                    rung, reserved, accuracy: 1.0,
                    "\(at): a rung draws \(rung)pt where the row reserved \(reserved)pt"
                )

                for limit in 2...5 {
                    appearance.secondaryWindowLimit = limit
                    let deeper = Self.drawnHeight(
                        appearance: appearance, provider: provider, result: result
                    )
                    XCTAssertEqual(
                        deeper, one + CGFloat(limit - 1) * rung, accuracy: 1.0,
                        "\(at): a ladder of \(limit) drew \(deeper)pt, off the line between "
                        + "\(one)pt at one rung and \(six)pt at six"
                    )
                }
            }
        }
    }

    /// The other style pays nothing for the same setting. `.chips` folds the
    /// further windows onto the caption line and `.hidden` drops them, so the
    /// stepper — which is the ladder's depth under `.expanded` — must not reserve
    /// a single point under either.
    @MainActor
    func testTheStepperCostsNoHeightWhereTheWindowsDoNotRideALine() throws {
        let provider = try Self.connectedProvider()
        let appearance = settings("ladder-other-styles")
        let result = Result<UsageData, ProviderError>.success(
            Self.reading(0.42, provider: provider, windows: 3)
        )
        for style in [AppearanceSettings.SecondaryWindowStyle.chips, .hidden] {
            appearance.secondaryWindows = style
            appearance.secondaryWindowLimit = 1
            let shallow = Self.drawnHeight(appearance: appearance, provider: provider, result: result)
            appearance.secondaryWindowLimit = 6
            let deep = Self.drawnHeight(appearance: appearance, provider: provider, result: result)
            XCTAssertEqual(
                shallow, deep, accuracy: 0.5,
                "\(style.rawValue): the stepper moved the row from \(shallow)pt to \(deep)pt"
            )
        }
    }

    // MARK: - The budget block

    /// **A budgeted row is one height in every state, spend or no spend.**
    ///
    /// This is the third block on this row to be reserved from a setting after
    /// being drawn from a payload, and it was the largest of the three. The
    /// budget block is a `secondaryBarHeight` track and a `lineBox(detailSize)`
    /// line joined at `captionGap`, and the row pays `contentSpacing` in front of
    /// it — 6 + 3 + 3 + 14 = 26pt at cozy/100%, against the 19pt the pace block
    /// cost and the 20pt a ladder rung costs. `MenuBarExtra` sizes its window to
    /// its content, so a block that arrives with the first spend is the panel
    /// resizing under the pointer.
    ///
    /// Four states rather than the usual three, and the fourth is the point. A
    /// budgeted service passes through *waiting*, *failed*, *reporting with no
    /// spend in the payload* and *reporting with one* — `BudgetPolicy` refuses the
    /// comparison in the first three, so `ProviderRow.budget(for:)` has to hold
    /// the block open in all of them. The two that were wrong when this case was
    /// written were the ends of that list: `detailContent` drew nothing at all
    /// while loading (the block simply was not called for), and drew a
    /// `BudgetMeter` the moment a reading with a spend landed.
    ///
    /// `XCTAssertEqual` with no tolerance, exactly as the pace case uses: 26pt is
    /// not a rounding argument at any density, and all four states draw the same
    /// two children at the same sizes, so there is no line of type here that can
    /// round differently between one state and the next.
    ///
    /// The premise is asserted first, twice over, for the reason the pace case
    /// states: without it a store that silently stopped holding the budget would
    /// leave four identical unbudgeted rows and a case that passes by measuring
    /// nothing. So the budget must reach a status against the paid payload, and
    /// must refuse one against the unpaid payload.
    @MainActor
    func testABudgetBlockArrivingCannotChangeARowsHeight() throws {
        let provider = try Self.connectedProvider()
        let budgets = BudgetStore(store: Self.scratchDefaults("budget-set"))
        let budget = Budget(amountMinor: 10_000, currency: "USD")
        budgets.setBudget(budget, for: provider.serviceID)
        // Measured rather than estimated, so the block is the track and the line
        // and nothing else: an estimate adds the "est." qualifier, which is width
        // on a line that already exists and could not move a height either way.
        let spend = SpendReport(
            amountMinor: 4_200, currency: "USD", period: .month, confidence: .measured
        )

        // The premise, both halves of it.
        XCTAssertNotNil(
            BudgetPolicy.status(spend: spend, budget: budgets.budget(for: provider.serviceID)),
            "the fixture stopped comparing a spend against a budget, so this case measures "
            + "four rows that all draw an empty block"
        )
        XCTAssertNil(
            BudgetPolicy.status(spend: nil, budget: budgets.budget(for: provider.serviceID)),
            "a payload with no spend in it produced a budget status, so this case has no control"
        )

        let states: [(name: String, result: Result<UsageData, ProviderError>?)] = [
            ("waiting", nil),
            ("failed", .failure(.parse("the provider answered with something this parser could not read"))),
            ("reporting, no spend", .success(Self.reading(0.42, provider: provider))),
            ("reporting, spend", .success(Self.reading(0.42, provider: provider, spend: spend)))
        ]

        try sweep("budget-arriving") { appearance, at in
            let heights = states.map { state in
                (state.name, Self.drawnHeight(
                    appearance: appearance,
                    provider: provider,
                    result: state.result,
                    budgets: budgets
                ))
            }
            let spread = (heights.map(\.1).max() ?? 0) - (heights.map(\.1).min() ?? 0)
            XCTAssertEqual(
                spread, 0,
                "\(at): the row drew "
                + heights.map { "\($0.0) \($0.1)pt" }.joined(separator: ", ")
            )
        }
    }

    /// And the block is really drawn, which is what makes the case above a claim
    /// about a row rather than about a block nobody places.
    ///
    /// The same shape as `testTheLadderDrawsEveryRungItReserved`: a budget set on
    /// the service makes the row taller by what `RowGeometry` reserves for it, and
    /// the step is measured between two rows differing in nothing but the store,
    /// so the title line, the meter block, the trace and the ladder all cancel.
    ///
    /// Measured off the *unpaid* payload, deliberately — that is the row that has
    /// to hold the block open, and a block that appeared only when there was a
    /// comparison to draw in it would pass the case above only by being absent
    /// from all four of its states.
    ///
    /// A point of tolerance, and it is the same point the ladder case takes and
    /// for the same measured reason: a hosted view reports whole points and a line
    /// of type rounds up to them, so at cozy/130% `lineBox(14.3)` is 17.3 where a
    /// drawn line is 18.0. The reservation runs under the drawing by that fraction
    /// in the one direction that cannot clip.
    @MainActor
    func testTheRowDrawsTheBudgetBlockItReserved() throws {
        let provider = try Self.connectedProvider()
        let appearance = settings("budget-drawn")
        let budgets = BudgetStore(store: Self.scratchDefaults("budget-drawn-set"))
        budgets.setBudget(Budget(amountMinor: 10_000, currency: "USD"), for: provider.serviceID)
        let result = Result<UsageData, ProviderError>.success(Self.reading(0.42, provider: provider))

        for density in Self.densities {
            for scale in Self.textScales {
                appearance.density = density
                appearance.textScale = scale
                let metrics = appearance.metrics
                let at = "\(density.rawValue)/\(Int(scale * 100))%"
                let reserved = metrics.contentSpacing
                    + metrics.secondaryBarHeight
                    + metrics.captionGap
                    + Tokens.lineBox(metrics.detailSize)

                let without = Self.drawnHeight(
                    appearance: appearance, provider: provider, result: result
                )
                let with = Self.drawnHeight(
                    appearance: appearance, provider: provider, result: result, budgets: budgets
                )
                XCTAssertEqual(
                    with - without, reserved, accuracy: 1.0,
                    "\(at): the budget block draws \(with - without)pt where the row reserved "
                    + "\(reserved)pt"
                )
            }
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
                        // cells for "$8,700.47" at the weight it draws the amount
                        // in, the gap, and three for the "est." qualifier at the
                        // weight it draws that in. Both weights are named for the
                        // reason the reservation names them — a cell is measured
                        // off the face now, and this face is wider at a heavier
                        // weight, so a model of the drawing that guesses the
                        // weight is a model of a different drawing.
                        let spend = carriesSpend
                            ? Tokens.figureWidth(size, digits: 9, weight: Tokens.Ramp.titleWeight)
                                + Tokens.Space.snug
                                + Tokens.figureWidth(size, digits: 3, weight: .regular)
                            : 0
                        // "+99", which `chipSplit` puts beside its one real chip
                        // rather than in place of it when the line holds one, and
                        // which `OverflowChip` draws at `.regular`.
                        let overflow = Tokens.figureWidth(size, digits: 3, weight: .regular)

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

    /// - Parameter windows: how many further windows the service reported. The
    ///   one part of a payload that used to reach the row's height, and the reason
    ///   this parameter exists: a case that varies it is varying what came back in
    ///   the fetch and nothing else. Defaulted to none, so every case written
    ///   before the ladder keeps measuring the row it was written about.
    /// - Parameter spend: the bill the payload carried, if any. The other part of
    ///   a payload that used to reach the row's height, by the same route and for
    ///   the same reason: a budget block drawn on `data.spend != nil` is a block
    ///   whose presence the fetch decides. Defaulted to none for the same reason
    ///   `windows` is.
    @MainActor
    private static func reading(
        _ percent: Double,
        provider: AnyUsageProvider,
        windows: Int = 0,
        spend: SpendReport? = nil
    ) -> UsageData {
        UsageData(
            providerID: provider.id,
            primary: UsageMetric(label: "5h", used: percent * 100, limit: 100, unit: "%"),
            // Distinct labels and distinct readings, because two windows sharing
            // either would let a row draw one of them and drop the rest and still
            // measure right — `ForEach` keyed on a repeated id is exactly that
            // failure, and it is a failure a height case cannot see.
            secondary: (0..<max(0, windows)).map { index in
                UsageMetric(
                    label: "Window \(index + 1)",
                    used: Double(10 * (index + 1)),
                    limit: 100,
                    unit: "%"
                )
            },
            spend: spend
        )
    }

    /// A trend store holding a ring the fit will answer for: five samples five
    /// minutes apart, rising, the last of them landing on `now` so the answer is
    /// not stale before it is read.
    ///
    /// Fed through `record`, which is what the refresh loop calls, rather than
    /// assembled behind it. Every refusal the store makes — the 30s gap rule, the
    /// six-hour trim, the staleness limit — therefore applies to this ring exactly
    /// as it applies to a real one, so a fixture that stops producing a projection
    /// is a fixture the app would also produce nothing for. `ForecastLineTests`
    /// builds its rings the same way for the same reason.
    @MainActor
    private static func risingTrend(
        for provider: AnyUsageProvider,
        now: Date
    ) throws -> UsageTrendStore {
        let store = UsageTrendStore(store: scratchDefaults("pace-rising"), now: { now })
        // 40% to 80% over twenty minutes: comfortably past the epsilon slope, and
        // an arrival inside the twelve-hour horizon, which are the two refusals a
        // rising ring can still hit.
        for (index, percent) in [0.40, 0.50, 0.60, 0.70, 0.80].enumerated() {
            let at = now.addingTimeInterval(-Double(4 - index) * 300)
            store.record(
                UsageData(
                    providerID: provider.id,
                    fetchedAt: at,
                    primary: UsageMetric(
                        label: "5h", used: percent * 100, limit: 100, unit: "%"
                    )
                ),
                for: provider.id
            )
        }
        return store
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

    /// All three stores empty and none of them the shared one: a budget on the
    /// service under test adds a meter to the row, a pace line adds a caption,
    /// and a trace adds ink to a slot — so whatever the machine running the suite
    /// has been collecting would decide what is being measured.
    ///
    /// The sparkline store is the one of the three that cannot move a height, and
    /// it is handed a fresh one anyway. A trace is drawn into a fixed box either
    /// way, so an empty store is not weaker here: it is the state a first launch
    /// is in, which is the state the reserved slot has to be honest in.
    /// - Parameter trend: the samples behind the row's pace claim. Empty by
    ///   default, which is the state every case here but the pace ones wants; the
    ///   pace cases hand in a loaded store and an empty one and compare the two
    ///   rows, which is the only way to ask whether a projection can move a row.
    /// - Parameter budgets: the user's caps. Empty by default for the reason
    ///   above, and handed in by the two budget cases the same way the pace cases
    ///   hand in a trend store — a budget is a setting, so the only way to ask
    ///   whether the block it reserves is honest is to build two rows that differ
    ///   in the store and nothing else.
    @MainActor
    private static func row(
        appearance: AppearanceSettings,
        provider: AnyUsageProvider,
        result: Result<UsageData, ProviderError>?,
        trend: UsageTrendStore? = nil,
        budgets: BudgetStore? = nil
    ) -> ProviderRow {
        ProviderRow(
            provider: provider,
            result: result,
            onSignIn: {},
            appearance: appearance,
            budgets: budgets ?? BudgetStore(store: scratchDefaults("budgets")),
            trend: trend ?? UsageTrendStore(store: scratchDefaults("trends")),
            sparklines: RowSparklineStore()
        )
    }

    /// `static`, so it cannot reach `XCTestCase.isolatedStore` — but the rule that
    /// helper exists for still applies, and the failure branch is where it used to
    /// be broken. This returned `.standard` when the suite could not be opened:
    /// the one case the `guard` is for, answered with the domain the whole fixture
    /// exists to stay out of, and answered silently on a green run. It fails
    /// outright now, because a reservation measured against the developer's own
    /// budgets and trends is not a weaker result — it is a different test.
    @MainActor
    private static func scratchDefaults(_ name: String) -> UserDefaults {
        let domain = "dev.aibars.test-scratch.row-reservation.\(name)"
        guard let store = UserDefaults(suiteName: domain) else {
            fatalError("could not open the scratch defaults domain \(domain)")
        }
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
        result: Result<UsageData, ProviderError>?,
        trend: UsageTrendStore? = nil,
        budgets: BudgetStore? = nil
    ) -> CGFloat {
        let hosted = row(
            appearance: appearance,
            provider: provider,
            result: result,
            trend: trend,
            budgets: budgets
        )
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
