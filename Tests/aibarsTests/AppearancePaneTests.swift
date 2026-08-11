import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// The Appearance pane is a Form of controls next to a live preview. A snapshot
/// of it came out blank, which is either a broken pane or a harness that cannot
/// draw a Form nested in a VStack — so this counts the AppKit controls SwiftUI
/// actually instantiated instead of looking at pixels.
///
/// The preview is measured rather than counted, because counting says nothing
/// about the one property that matters: a sample row and a real `ProviderRow`
/// at the same settings and the same width have to come out the same height.
/// That is not a property anyone can check by looking at the pane — the two are
/// never on screen together — and it is exactly the property that broke last
/// time, when the sample inserted its hover buttons instead of reserving them.
///
/// Height alone is not enough, though, and that is the second lesson of the
/// same bug: two stacks can agree on a height while disagreeing about the
/// figure rail, the card's corner and whether the row carries a spine, and a
/// preview wrong about any of those is describing a panel the app does not
/// draw. Each of the three is asserted at the seam where it can be: the corner
/// follows from the measured height, the spine is a decision `RowSpine` makes
/// out loud, and the rail — a reserved width, invisible in any measurement of a
/// row by construction — is pinned to the number `RowGeometry` hands both rows
/// and to the widest reading either of them can print.
///
/// Nothing here uses `AppearanceSettings.shared`: it persists to
/// `UserDefaults.standard`, and a pane test that reached it would rewrite the
/// settings of whoever ran the suite.
final class AppearancePaneTests: XCTestCase {
    @MainActor
    private func hosted<V: View>(_ view: V, height: CGFloat = 520) -> NSView {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: 660, height: height)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return host
    }

    private func controls(in view: NSView) -> [NSControl] {
        var found: [NSControl] = []
        if let control = view as? NSControl { found.append(control) }
        for subview in view.subviews { found.append(contentsOf: controls(in: subview)) }
        return found
    }

    /// What a view asks for when nothing constrains it. `fittingSize` rather than
    /// a rendered frame: the view is asked what it wants, which is the number
    /// `MenuBarExtra` sizes its window from and the number the status item
    /// reserves in the bar.
    @MainActor
    private func fittingSize<V: View>(_ view: V) -> CGSize {
        let host = NSHostingView(rootView: AnyView(view))
        host.layoutSubtreeIfNeeded()
        return host.fittingSize
    }

    /// The height a view settles at when it is given exactly the width the panel
    /// would give it.
    @MainActor
    private func fittingHeight<V: View>(_ view: V, width: CGFloat) -> CGFloat {
        fittingSize(view.frame(width: width)).height
    }

    @MainActor
    private func settings(_ suite: String) -> AppearanceSettings {
        let store = UserDefaults(suiteName: suite) ?? .standard
        store.removePersistentDomain(forName: suite)
        return AppearanceSettings(store: store)
    }

    /// The measurement a row is built from, assembled out of settings exactly as
    /// `ProviderRow` assembles it. Every input is a setting, so two rows drawn
    /// under one `AppearanceSettings` — the panel's and the preview's — are
    /// handed the same rails whatever else differs between them.
    @MainActor
    private func geometry(
        _ appearance: AppearanceSettings,
        lines: RowGeometry.Lines
    ) -> RowGeometry {
        RowGeometry(
            metrics: appearance.metrics,
            showsPercentage: appearance.showsPercentage,
            meterStyle: appearance.meterStyle,
            logoStyle: appearance.logoStyle,
            logoSize: CGFloat(appearance.logoSize),
            panelWidth: CGFloat(appearance.panelWidth),
            lines: lines
        )
    }

    /// A run set in the face the figures are actually set in, measured rather
    /// than derived: `Tokens.figureWidth` reserves its cells from an advance
    /// ratio written down once, and this is the only thing in the suite that asks
    /// the font whether that ratio is still true.
    ///
    /// At the alert weight, which is the heaviest a figure goes. SF Mono's
    /// advance does not move with weight, so the answer is the same at
    /// `emphasisWeight` — asking at the heavier one just means the test cannot be
    /// wrong in the direction that matters.
    private func monoWidth(_ run: String, size: CGFloat) -> CGFloat {
        let font = NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
        return (run as NSString).size(withAttributes: [.font: font]).width
    }

    // MARK: - The form

    @MainActor
    func testThePaneInstantiatesItsControls() {
        let appearance = settings("pane-tests")
        let host = hosted(AppearancePane(appearance: appearance))
        let found = controls(in: host)
        XCTAssertGreaterThan(
            found.count, 8,
            "only \(found.count) controls — the options form is not being built"
        )
    }

    /// The pane has to survive being short. Squeezed between a preview strip and
    /// a small window, the form must still scroll rather than vanish.
    @MainActor
    func testThePaneSurvivesAShortWindow() {
        let appearance = settings("pane-tests-short")
        let host = hosted(AppearancePane(appearance: appearance), height: 300)
        XCTAssertGreaterThan(controls(in: host).count, 4, "the form collapsed in a short window")
    }

    /// Every preset has to build the whole pane, preview included. A preset that
    /// hides the meter, the logos or the extra windows takes whole branches of
    /// the sample with it, and those branches are only ever exercised here.
    @MainActor
    func testThePaneBuildsForEveryPreset() {
        let appearance = settings("pane-presets-build")
        for preset in AppearanceSettings.Preset.allCases {
            appearance.apply(preset)
            let host = hosted(AppearancePane(appearance: appearance))
            XCTAssertGreaterThan(
                controls(in: host).count, 6,
                "\(preset.id) builds only \(controls(in: host).count) controls"
            )
        }
    }

    // MARK: - Presets

    /// Every preset must resolve to a usable panel: a width that fits a menu bar
    /// dropdown and metrics that are not degenerate.
    @MainActor
    func testEveryPresetIsUsable() {
        let appearance = settings("preset-sanity")
        for preset in AppearanceSettings.Preset.allCases {
            appearance.apply(preset)
            XCTAssertGreaterThanOrEqual(appearance.panelWidth, 240, "\(preset.id) is too narrow")
            XCTAssertLessThanOrEqual(appearance.panelWidth, 600, "\(preset.id) is too wide")
            let metrics = appearance.metrics
            XCTAssertGreaterThan(metrics.titleSize, 8, "\(preset.id) title type is unreadable")
            XCTAssertGreaterThan(metrics.rowVerticalPadding, 0, "\(preset.id) has no row padding")
            XCTAssertGreaterThan(metrics.barHeight, 0, "\(preset.id) draws a zero-height bar")
        }
    }

    /// Applying a preset then reading it back has to name the same preset, or the
    /// settings pane cannot show which one is selected.
    @MainActor
    func testPresetsRoundTrip() {
        let appearance = settings("preset-roundtrip")
        for preset in AppearanceSettings.Preset.allCases {
            appearance.apply(preset)
            XCTAssertEqual(appearance.matchingPreset, preset, "\(preset.id) does not match itself")
        }
    }

    @MainActor
    func testResetReturnsToTheShippedConfiguration() {
        let appearance = settings("preset-reset")
        appearance.apply(.dashboard)
        appearance.resetToDefaults()
        XCTAssertEqual(appearance.panelWidth, 356, "reset must restore the shipped panel width")
    }

    // MARK: - The sample row against a real one

    /// A `ProviderRow` carrying the same account, plan, metrics and settings as
    /// the sample row beside it.
    ///
    /// `isAuthenticated` is set on the wrapper rather than reached for through a
    /// credential: the row's whole layout hangs off that flag, and a test that
    /// needed a real session in the Keychain would be a test that only runs on
    /// the author's machine.
    @MainActor
    private func realRow(
        _ appearance: AppearanceSettings,
        from sample: SampleService
    ) -> ProviderRow {
        // A made-up account id, so nothing in `UsageTrendStore` or the sign-out
        // marks answers for it and the row draws exactly what it is handed.
        let provider = AnyUsageProvider(ClaudeProvider(accountID: "appearance-sample"))
        provider.isAuthenticated = true
        let data = UsageData(
            providerID: provider.id,
            // The raw tier, because `ProviderRow` prettifies it and the sample
            // carries the prettified form: "Default_Claude_Max_20X" → "Max 20×".
            planName: "Default_Claude_Max_20X",
            primary: sample.primary,
            secondary: sample.secondary,
            accountLabel: sample.account
        )
        return ProviderRow(
            provider: provider,
            result: .success(data),
            onSignIn: {},
            appearance: appearance
        )
    }

    /// The Claude sample with its headline reading rewritten and every other
    /// field carried across untouched, so a case can walk a row over the warning
    /// threshold without also changing its shape.
    private func claudeSample(headline percent: Double) -> SampleService {
        let base = SampleService.claude
        let metric = base.primary
        return SampleService(
            serviceID: base.serviceID,
            displayName: base.displayName,
            accent: base.accent,
            account: base.account,
            plan: base.plan,
            primary: UsageMetric(
                label: metric.label,
                used: metric.limit * percent,
                limit: metric.limit,
                unit: metric.unit,
                resetDate: metric.resetDate,
                windowLabel: metric.windowLabel,
                windowDuration: metric.windowDuration,
                windowKey: metric.windowKey
            ),
            secondary: base.secondary
        )
    }

    /// The preview-disagreement bug, asserted.
    ///
    /// The sample row is not a `ProviderRow` — that one needs an
    /// `AnyUsageProvider`, which only exists wrapped around a Keychain lookup and
    /// a network fetch — so it is assembled from the same shared views. If it
    /// ever stops being assembled from them, this is where it shows: the two
    /// stacks come out different heights and the preview quietly starts
    /// describing a panel the app does not draw.
    @MainActor
    func testTheSampleRowIsTheHeightOfARealRow() {
        let appearance = settings("sample-row-height")
        for preset in AppearanceSettings.Preset.allCases {
            appearance.apply(preset)
            let sample = SampleService.claude
            let width = CGFloat(appearance.panelWidth)

            let previewed = fittingHeight(
                SampleRow(appearance: appearance, service: sample),
                width: width
            )
            let real = fittingHeight(realRow(appearance, from: sample), width: width)

            XCTAssertEqual(
                previewed, real, accuracy: 0.5,
                "\(preset.id): the preview draws a \(previewed)pt row for a \(real)pt one"
            )
        }
    }

    /// The invariant the panel has, demonstrated by the thing that previews it.
    ///
    /// `MenuBarExtra` sizes its window to its content, so a row that grows when
    /// the pointer crosses it resizes the whole panel under the cursor. The
    /// buttons are reserved and only their opacity changes — which means "on
    /// hover" and "always" have to be the same height, and so does hovering.
    @MainActor
    func testTheSampleRowHoldsItsHeightWhateverTheButtonsDo() {
        let appearance = settings("sample-row-actions")
        let width = CGFloat(appearance.panelWidth)
        let sample = SampleService.claude

        appearance.rowActions = .onHover
        let onHover = fittingHeight(SampleRow(appearance: appearance, service: sample), width: width)
        appearance.rowActions = .always
        let always = fittingHeight(SampleRow(appearance: appearance, service: sample), width: width)

        XCTAssertEqual(
            onHover, always, accuracy: 0.5,
            "the sample row is \(onHover)pt on hover and \(always)pt always — it is inserting the buttons, not reserving them"
        )
    }

    // MARK: - What agreeing on a height does not say

    /// The card's corner, which the height alone does not settle.
    ///
    /// A row draws its card at `min(Radius.row, height / 3)` rather than at
    /// `Radius.row`, because 8pt is right for a 49pt comfortable row and eats the
    /// corners of a short one. So the corner is a reading of the height, and two
    /// rows that agree on the height to half a point agree on the corner to a
    /// sixth of one — the tolerance here is the height's own, divided by the three
    /// the clamp divides by, and not a stricter claim smuggled in behind a
    /// rounder number.
    ///
    /// The second assertion records that the clamp is dormant at every shipped
    /// preset: the shortest row any density draws is a title line and its padding,
    /// which is over 24pt, so both rows take the full radius today. It is here so
    /// that a future density which does produce a short row fails this test in the
    /// pane as well as in `RowGeometryTests` — the preview is where a clamped
    /// corner would first be seen and first be wrong.
    @MainActor
    func testTheSampleRowAndARealRowDrawTheSameCardCorner() {
        let appearance = settings("sample-row-corner")
        for preset in AppearanceSettings.Preset.allCases {
            appearance.apply(preset)
            let sample = SampleService.claude
            let width = CGFloat(appearance.panelWidth)

            let previewed = fittingHeight(
                SampleRow(appearance: appearance, service: sample),
                width: width
            )
            let real = fittingHeight(realRow(appearance, from: sample), width: width)

            XCTAssertEqual(
                cardRadius(of: previewed), cardRadius(of: real), accuracy: 0.5 / 3,
                "\(preset.id): the preview rounds its card at \(cardRadius(of: previewed))pt and the panel at \(cardRadius(of: real))pt"
            )
            XCTAssertEqual(
                cardRadius(of: real), Tokens.Radius.row,
                "\(preset.id) draws a row short enough to clamp its corners — the preview has to clamp with it"
            )
        }
    }

    /// The corner a row of this height draws its card at. `RowGeometry.cardRadius`
    /// restated against a measured height rather than a computed one, which is the
    /// only form of it available out here.
    private func cardRadius(of height: CGFloat) -> CGFloat {
        min(Tokens.Radius.row, height / 3)
    }

    /// The figure rail, which is the one thing about a row that cannot be seen
    /// from outside it.
    ///
    /// A rail is a reservation. It leaves no trace in a height, and none in a
    /// width either: the title line spans the whole text column, so the figure's
    /// trailing edge is the meter's trailing edge whether the column reserved for
    /// it is 28pt or 35pt. There is no measurement of a rendered row that can tell
    /// the two apart, which is exactly why the preview was able to keep its own
    /// copy of the arithmetic and be a point out for as long as it liked.
    ///
    /// So it is pinned at the seam instead: the rail is a function of the settings
    /// alone, both rows are built under one `AppearanceSettings`, and the number
    /// that comes out holds the widest reading either of them can print — "100%",
    /// measured in SF Mono at the sizes each preset sets it in rather than trusted
    /// to an advance ratio written down once in `Tokens`.
    @MainActor
    func testTheFigureRailHoldsTheWidestReadingEitherRowCanPrint() {
        let appearance = settings("sample-row-rail")
        for preset in AppearanceSettings.Preset.allCases {
            appearance.apply(preset)
            let metrics = appearance.metrics

            // Two rows of different shapes: the preview's, drawing everything, and
            // a row still waiting on its first fetch. The rail is the panel's
            // column and not the row's, so the two are the same number.
            let full = geometry(appearance, lines: [.meter, .window, .forecast])
            let loading = geometry(appearance, lines: .window)
            XCTAssertEqual(
                full.headlineRail, loading.headlineRail,
                "\(preset.id) reserves a different figure column for a row that is still loading"
            )
            XCTAssertEqual(
                full.headlineRail, metrics.headlineRail,
                "\(preset.id) hands a row a rail that is not the panel's own"
            )

            let widest = monoWidth("100", size: metrics.figureSize)
                + monoWidth("%", size: metrics.unitSize)
            XCTAssertGreaterThanOrEqual(
                full.headlineRail, widest,
                "\(preset.id) reserves \(full.headlineRail)pt for a reading that measures \(widest)pt — 100% is drawn outside its own column"
            )
        }
    }

    /// The preview has to carry a row that wants the user and a row that does not,
    /// because the spine is the app's silhouette and a preview showing neither
    /// state cannot show what the panel looks like.
    ///
    /// Asserted against each preset's own `warningThreshold` rather than against
    /// the shipped one. The sample's headline reading is a fixed 412 of 450, so a
    /// preset that moved its warning above that — or an edit that eased the sample
    /// down to something comfortable — would leave the preview with nothing spined
    /// and no way to notice.
    ///
    /// Both rows reach the decision through `RowSpine` from inputs they already
    /// have, so what is checked here is that they are handed the same ones: the
    /// reading the preview draws and the reading inside the `UsageData` a real row
    /// is given are the same reading, and both are connected with nothing failed.
    @MainActor
    func testThePreviewCarriesARowThatSpinesAndARowThatDoesNot() {
        let appearance = settings("sample-row-spine")
        for preset in AppearanceSettings.Preset.allCases {
            appearance.apply(preset)
            let warning = appearance.warningThreshold

            for (sample, expected) in [
                (SampleService.claude, SpineReason.nearCap),
                (SampleService.chatgpt, nil)
            ] as [(SampleService, SpineReason?)] {
                let previewed = RowSpine.reason(
                    percent: sample.primary.percent,
                    warningThreshold: warning,
                    error: nil,
                    isConnected: true
                )
                XCTAssertEqual(
                    previewed, expected,
                    "\(preset.id): at a warning of \(warning) the preview's \(sample.displayName) row spines \(String(describing: previewed)) rather than \(String(describing: expected))"
                )

                // The same question, off the row the panel would draw from this
                // service: a `UsageData` carrying the sample's own metric, on a
                // provider with a credential and no failure.
                let real = realRow(appearance, from: sample)
                guard case .success(let data)? = real.result else {
                    XCTFail("the real row was not handed a reading")
                    continue
                }
                XCTAssertEqual(
                    RowSpine.reason(
                        percent: data.primary.percent,
                        warningThreshold: warning,
                        error: nil,
                        isConnected: real.provider.isAuthenticated
                    ),
                    previewed,
                    "\(preset.id): the panel and the preview disagree about whether \(sample.displayName) wants the user"
                )
            }
        }
    }

    /// The spine is a bookmark laid on the card, not a thing the card makes room
    /// for. A row that grew by drawing one would resize the panel the moment a
    /// service crossed its warning — under the pointer, on the row the user is
    /// reaching for.
    ///
    /// Asserted on both rows, and the two readings are chosen two digits wide on
    /// purpose: 46% and 92% differ in every near-cap channel there is — the fill's
    /// trailing end, the figure's weight, the spine, the colour — and in nothing
    /// else, so a height that moves between them moved because of one of those.
    @MainActor
    func testASpineCostsARowNoHeight() {
        let appearance = settings("sample-row-spine-height")
        let width = CGFloat(appearance.panelWidth)
        let quiet = claudeSample(headline: 0.46)
        let spined = claudeSample(headline: 0.92)

        XCTAssertEqual(
            fittingHeight(SampleRow(appearance: appearance, service: quiet), width: width),
            fittingHeight(SampleRow(appearance: appearance, service: spined), width: width),
            accuracy: 0.5,
            "the sample row changes height when it crosses the warning threshold"
        )
        XCTAssertEqual(
            fittingHeight(realRow(appearance, from: quiet), width: width),
            fittingHeight(realRow(appearance, from: spined), width: width),
            accuracy: 0.5,
            "a real row changes height when it crosses the warning threshold"
        )
    }

    // MARK: - The menu bar strip

    /// The strip has to build at every count the stepper offers, and the pane
    /// with it. One is a real choice for someone with one subscription.
    @MainActor
    func testTheMenuBarSampleBuildsAtEveryServiceCount() {
        let appearance = settings("menu-bar-sample")
        for count in MenuBarStripContent.range {
            appearance.menuBarServiceCount = count
            let host = hosted(AppearancePane(appearance: appearance))
            XCTAssertGreaterThan(
                controls(in: host).count, 6,
                "the pane does not build with \(count) service(s) in the strip"
            )

            let entries = MenuBarStripContent.entries(from: SampleService.stripEntries, limit: count)
            XCTAssertEqual(entries.count, count, "the sample strip drew \(entries.count) of \(count)")
        }
    }

    /// The strip itself, at every count the stepper offers and at both ends of the
    /// glyph height it can be set to.
    ///
    /// The test above hosts the whole pane and counts controls, which says the
    /// preview was built and nothing about what it came out as. This measures the
    /// strip, because the preview's job in the Appearance pane is to be true about
    /// a width: the status item shares a 22pt bar with everyone else's, and a pane
    /// that promises three services the bar will only draw two of is a pane the
    /// user cannot set the count from.
    ///
    /// Measured against `StripFit`, which is what the status item reserves, and
    /// against the drawn segments rather than the requested ones — at the largest
    /// glyph three marks and three figures are wider than the budget, and dropping
    /// the least urgent is the behaviour rather than a failure.
    @MainActor
    func testTheStripSampleBuildsAtEveryServiceCount() {
        let appearance = settings("strip-sample")
        // The two ends of the range `menuBarGlyphHeight` clamps to, and the shipped
        // value between them: the bounds are where a width contract that has
        // quietly stopped holding shows up first.
        for glyph in [10.0, 13.0, 16.0] {
            appearance.menuBarGlyphHeight = glyph
            let height = CGFloat(appearance.menuBarGlyphHeight)

            for count in MenuBarStripContent.range {
                appearance.menuBarServiceCount = count
                let entries = MenuBarStripContent.entries(
                    from: SampleService.stripEntries,
                    limit: appearance.menuBarServiceCount
                )
                // The pane's own preview call, restated because `MenuBarSample` is
                // private to it. Everything the view needs is a setting, so there
                // is nothing here the pane could be passing differently.
                let size = fittingSize(
                    MenuBarStripView(
                        entries: entries,
                        height: height,
                        colour: appearance.menuBarColour,
                        warningThreshold: appearance.warningThreshold
                    )
                )
                let drawn = StripFit.fit(entries, limit: entries.count, height: height)
                let context = "\(count) service(s) at a \(glyph)pt glyph"

                XCTAssertGreaterThanOrEqual(
                    drawn.count, 1,
                    "\(context): the preview drew an empty strip"
                )
                XCTAssertEqual(
                    size.width, StripFit.width(segments: drawn.count, height: height),
                    accuracy: 0.5,
                    "\(context): the preview measures \(size.width)pt against the \(StripFit.width(segments: drawn.count, height: height))pt the status item reserves"
                )
                XCTAssertEqual(
                    size.height, height, accuracy: 0.5,
                    "\(context): the strip is \(size.height)pt tall in a bar that gave it \(height)"
                )
                XCTAssertLessThanOrEqual(
                    size.width, Tokens.Strip.maxWidth,
                    "\(context): the preview is wider than the budget the item is allowed"
                )
            }
        }
    }

    /// The sample carries a status-only service so the preview can show what a
    /// service with no quota looks like: a dash, never a number.
    ///
    /// It arrives last, and that is the behaviour rather than an accident —
    /// something reporting no figure can never displace something reporting one.
    @MainActor
    func testTheSampleStripShowsTheDashRatherThanAFakeNumber() {
        let full = MenuBarStripContent.entries(
            from: SampleService.stripEntries,
            limit: MenuBarStripContent.range.upperBound
        )
        let statusOnly = full.filter { $0.percent == nil }
        XCTAssertEqual(
            statusOnly.count, 1,
            "the menu bar preview has no status-only service, so it cannot show the case it exists to show"
        )
        XCTAssertEqual(statusOnly.first?.figure, MenuBarEntry.noFigure)
        XCTAssertEqual(
            full.last?.percent, nil,
            "a service reporting no quota sorted above one that reports a figure"
        )
    }

    // MARK: - What the pane no longer has

    /// The gradient toggle is gone, and with it the last reader of
    /// `usesGradientFill`. The meter fill is flat now: a gradient over a fill
    /// whose colour is the reading makes the reading a different colour at each
    /// end of the same bar.
    ///
    /// Asserted by count rather than by name, because a `Toggle` in a Form is an
    /// `NSSwitch` with no title to look for. The toggle was the only control the
    /// meter section drew for `.bar` and not for `.ring`, so the two counts
    /// agreeing is the toggle being absent — and the counts diverging again is
    /// the toggle, or something like it, coming back.
    @MainActor
    func testTheGradientControlIsGone() {
        let appearance = settings("meter-gradient-gone")

        appearance.meterStyle = .bar
        let bar = controls(in: hosted(AppearancePane(appearance: appearance))).count
        appearance.meterStyle = .ring
        let ring = controls(in: hosted(AppearancePane(appearance: appearance))).count

        XCTAssertEqual(
            bar, ring,
            "the bar meter draws \(bar) controls and the ring \(ring) — the gradient toggle is still there"
        )
    }
}
