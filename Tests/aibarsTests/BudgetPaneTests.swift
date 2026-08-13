import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// The Spend pane is a Form over two untrusted inputs: what a provider says it
/// has spent, and what the user typed into a cap field and then left in
/// UserDefaults for a later build to read back.
///
/// It is measured the way `AlertsPaneTests` and `HistoryPaneTests` measure
/// theirs — by counting the AppKit controls SwiftUI actually instantiated, and
/// by the height the Form reports — with one addition they do not need: the cap
/// fields are real `NSTextField`s, so what the pane seeded them with can be read
/// back, and text can be typed into them through the field editor exactly as a
/// person types it. That is the only way the write-through is reachable at all;
/// setting `stringValue` moves the text and tells nobody.
///
/// What is *not* reachable, stated once so no later reader assumes it was
/// forgotten. A `Text` inside an `NSHostingView` is neither an `NSTextField`
/// nor an accessibility element in this harness, and a Form snapshots blank
/// through `ImageRenderer` whether or not it drew anything — both were measured
/// rather than guessed. So none of the pane's prose can be asserted as a
/// string: not "estimated", not "over by $12.30", not "does not bill in USD".
/// Where a sentence has to be shown to exist, it is shown by the view that
/// carries it — a note is a whole extra `Text` and the Form gets taller — and
/// where it cannot, the fact underneath it is asserted instead and the test says
/// so.
///
/// What *is* reachable, and is the whole of how the two claims about drawing are
/// made. `NSView.cacheDisplay(in:to:)` puts the pane's pixels somewhere a test
/// can read them, which `ImageRenderer` does not — also measured. That still
/// yields no strings, because a raster cannot be read back as text, but two
/// panes differing in exactly one thing can be subtracted from each other, and
/// *where* the difference lands is a fact about the layout rather than about the
/// wording: what moves when only the amount changes has to fit inside the money
/// rail, and what moves when only the confidence changes has to reach it.
///
/// Nothing here touches `BudgetStore.shared`, `AppState.shared` or
/// `AppearanceSettings.shared`. All three persist to `UserDefaults.standard`,
/// and a pane test that reached one would edit the settings of whoever ran it —
/// which is also why `BudgetPane()` with no arguments is never called: its whole
/// job is to reach for those three.
final class BudgetPaneTests: XCTestCase {

    // MARK: - Harness

    /// The windows the harness built, kept alive for the length of the test.
    ///
    /// Not a local inside `hosted`: a text field only has a field editor while
    /// it sits in a live window, and typing is how half of this file works. A
    /// window nobody retains is gone the moment `hosted` returns, and
    /// `makeFirstResponder` then has nowhere to send the keystrokes.
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    /// Fixed so a row's figures do not depend on when the suite ran.
    private static let fixedNow = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// Where `BudgetStore` keeps its blob. Written out rather than reached for,
    /// because the store's own key is private and this file has to be able to
    /// put malformed bytes under it.
    private static let budgetsKey = "aibars.spend.budgets"

    /// A scratch domain, emptied first and removed after. `BudgetStore` decodes
    /// in `init`, so a domain left behind by an earlier run would hand the next
    /// one somebody else's caps.
    private func scratch(_ name: String) throws -> UserDefaults {
        // Stable, not a UUID. `TestDomain` in `TestIsolation.swift` has the
        // measurement: `removePersistentDomain` empties a domain and does not
        // delete its file, so a fresh name per run left a plist behind every time.
        let suite = TestDomain.stable("\(TestDomain.prefix).budget-pane.\(name)")
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return defaults
    }

    /// One pane and everything it was built against, so a test can assert on the
    /// store the pane is writing to rather than on a store that merely looks
    /// like it.
    private struct Bench {
        let pane: BudgetPane
        let store: BudgetStore
        let state: AppState
        let defaults: UserDefaults
    }

    /// `reports` is keyed by provider id — "claude", "claude#2" — because that
    /// is how a snapshot is filed. The pane groups them by service itself, which
    /// is the thing several of these tests are about.
    @MainActor
    private func bench(
        _ name: String = #function,
        budgets: [String: Budget] = [:],
        reports: [String: SpendReport] = [:],
        accounts: [AnyUsageProvider] = [],
        stored: Data? = nil
    ) throws -> Bench {
        let defaults = try scratch(name)
        if let stored { defaults.set(stored, forKey: Self.budgetsKey) }

        let store = BudgetStore(store: defaults)
        if !budgets.isEmpty { store.budgets = budgets }

        let state = AppState()
        state.providers.append(contentsOf: accounts)
        for provider in state.providers {
            guard let report = reports[provider.id] else { continue }
            state.snapshots[provider.id] = .success(snapshot(provider.id, spend: report))
        }

        return Bench(
            pane: BudgetPane(
                store: store,
                state: state,
                appearance: AppearanceSettings(store: try scratch(name + ".appearance"))
            ),
            store: store,
            state: state,
            defaults: defaults
        )
    }

    /// A reading with a spend figure hung off it, which is how the pane gets one:
    /// it does no fetching, it reads what the last refresh already recorded.
    private func snapshot(_ providerID: String, spend: SpendReport?) -> UsageData {
        UsageData(
            providerID: providerID,
            fetchedAt: Self.fixedNow,
            planName: "Pro",
            primary: UsageMetric(label: "5h window", used: 40, limit: 100, unit: "%"),
            spend: spend
        )
    }

    /// One account's figure. `exponent` is a parameter rather than a constant
    /// because it is the whole of what a cap means: a provider billing in
    /// micro-units gets a cap in micro-units, and nothing anywhere converts.
    private func report(
        _ providerID: String,
        minor: Int,
        currency: String = "USD",
        exponent: Int = 2,
        period: SpendReport.Period = .month,
        confidence: SpendReport.Confidence = .measured
    ) -> SpendReport {
        SpendReport(
            amountMinor: minor,
            currency: currency,
            exponent: exponent,
            period: period,
            confidence: confidence
        )
    }

    @MainActor
    private func hosted<V: View>(_ view: V, height: CGFloat = 620) -> NSView {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: 660, height: height)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        windows.append(window)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        settle()
        return host
    }

    /// Long enough for SwiftUI to run the pending updates a keystroke or a click
    /// queues. Everything here is synchronous otherwise.
    private func settle(_ seconds: TimeInterval = 0.25) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private func controls(in view: NSView) -> [NSControl] {
        var found: [NSControl] = []
        if let control = view as? NSControl { found.append(control) }
        for subview in view.subviews { found.append(contentsOf: controls(in: subview)) }
        return found
    }

    /// The cap fields, and only those, in the order they are read down the pane.
    ///
    /// Identified by their prompt rather than by class or position: on a recent
    /// macOS a `Stepper` instantiates a text field of its own for its readout,
    /// and which controls a stepper builds has moved between OS versions before.
    /// "No cap" is the pane's own string and is the one thing about the field
    /// that cannot drift underneath the test.
    ///
    /// Sorted by where they sit rather than by the order the view tree happens
    /// to hold them, because a test that types into "the total's field" means
    /// the one at the bottom of the pane and nothing else.
    private func capFields(in view: NSView) -> [NSTextField] {
        controls(in: view)
            .compactMap { $0 as? NSTextField }
            .filter { $0.isEditable && $0.placeholderString == "No cap" }
            .sorted { lhs, rhs in
                let first = view.convert(lhs.bounds, from: lhs).midY
                let second = view.convert(rhs.bounds, from: rhs).midY
                return view.isFlipped ? first < second : first > second
            }
    }

    private func steppers(in view: NSView) -> [NSStepper] {
        controls(in: view).compactMap { $0 as? NSStepper }
    }

    /// The money rail, in the host's own points: `Tokens.moneyWidth` of ground
    /// ending a gutter before the column the cap field is trailing-aligned in.
    ///
    /// Anchored to the field's own trailing edge, which is the row's, and stepped
    /// back through two tokens rather than through the field's width — the field
    /// is as wide as the rail by construction, and a test that used that to find
    /// the rail would be assuming what it is about to measure.
    ///
    /// Written down rather than found in the pixels, because "the rail is
    /// reserved" is the claim under test: a range derived from wherever the ink
    /// landed could not fail.
    @MainActor
    private func moneyRail(in host: NSView) throws -> ClosedRange<CGFloat> {
        let field = try XCTUnwrap(
            capFields(in: host).first,
            "the pane drew no cap field, so there is no row to find the rail in"
        )
        let trailing = host.convert(field.bounds, from: field).maxX
            - Tokens.Control.actionColumn
            - Tokens.Space.gutter
        return (trailing - Tokens.moneyWidth(Tokens.Ramp.title))...trailing
    }

    /// The pane as pixels.
    ///
    /// `cacheDisplay` has to run while the view is still in its window, so the
    /// bytes are copied out here rather than a rep being handed back: a test that
    /// compared two reps later would be measuring whatever the windows had done
    /// since.
    @MainActor
    private func raster(_ host: NSView) throws -> Raster {
        let rep = try XCTUnwrap(
            host.bitmapImageRepForCachingDisplay(in: host.bounds),
            "the host would not hand out a bitmap to draw itself into"
        )
        host.cacheDisplay(in: host.bounds, to: rep)
        let pixels = try XCTUnwrap(rep.bitmapData, "the raster came back with no pixels in it")
        return Raster(
            width: rep.pixelsWide,
            height: rep.pixelsHigh,
            bytesPerRow: rep.bytesPerRow,
            bytesPerPixel: rep.bitsPerPixel / 8,
            scale: CGFloat(rep.pixelsWide) / max(host.bounds.width, 1),
            bytes: [UInt8](UnsafeBufferPointer(start: pixels, count: rep.bytesPerRow * rep.pixelsHigh))
        )
    }

    /// What one pane drew, as bytes, with the scale it drew at — so a range stated
    /// in the host's own points means the same thing on a Retina display as on a
    /// 1x one, and a comparison is arithmetic over two arrays.
    private struct Raster {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let bytesPerPixel: Int
        let scale: CGFloat
        let bytes: [UInt8]

        /// Pixels that are not the colour of the top-left corner, which is the
        /// pane's own ground.
        ///
        /// Zero means the raster is blank. `ImageRenderer` hands back a blank one
        /// for a Form whether or not it drew anything, so before any two rasters
        /// are subtracted, one of them has to be shown to contain a pane.
        var painted: Int {
            let ground = pixel(at: 0)
            var count = 0
            for y in 0..<height {
                for x in 0..<width where pixel(at: offset(x, y)) != ground { count += 1 }
            }
            return count
        }

        /// The strip of the host every difference from `other` falls in, stated in
        /// the host's own points and covering whole pixels: from the leading edge
        /// of the leftmost pixel that changed to the trailing edge of the
        /// rightmost. `nil` when nothing changed, or when the two rasters are not
        /// the same shape and so cannot be compared.
        ///
        /// One measurement, and both halves of what a column is are read off it:
        /// how wide the difference is needs no anchor at all, and where it sits is
        /// then held against the rail `moneyRail(in:)` writes down.
        func changedExtent(from other: Raster) -> ClosedRange<CGFloat>? {
            guard width == other.width, height == other.height,
                  bytesPerRow == other.bytesPerRow, bytesPerPixel == other.bytesPerPixel,
                  scale == other.scale else { return nil }

            var leftmost = width
            var rightmost = -1
            for y in 0..<height {
                for x in 0..<width where pixel(at: offset(x, y)) != other.pixel(at: offset(x, y)) {
                    leftmost = min(leftmost, x)
                    rightmost = max(rightmost, x)
                }
            }
            guard rightmost >= leftmost else { return nil }
            return (CGFloat(leftmost) / scale)...(CGFloat(rightmost + 1) / scale)
        }

        private func offset(_ x: Int, _ y: Int) -> Int { y * bytesPerRow + x * bytesPerPixel }

        private func pixel(at offset: Int) -> ArraySlice<UInt8> {
            bytes[offset..<(offset + bytesPerPixel)]
        }
    }

    /// Types the way a person does — through the field editor, so the binding's
    /// `onChange` fires and the pane writes through. An empty string means the
    /// field was cleared, which is the only way to remove a cap.
    @MainActor
    private func type(_ text: String, into field: NSTextField) throws {
        let window = try XCTUnwrap(field.window, "the cap field is not in a window, so it has no field editor")
        XCTAssertTrue(window.makeFirstResponder(field), "the cap field refused to take focus")
        let editor = try XCTUnwrap(field.currentEditor(), "the cap field has no field editor to type into")
        editor.selectAll(nil)
        if text.isEmpty {
            editor.delete(nil)
        } else {
            editor.insertText(text)
        }
        settle()
    }

    /// One click of the warning-level stepper.
    ///
    /// An `NSStepper` under SwiftUI reports the change rather than the value —
    /// its own `integerValue` is a running delta and the binding moves by one
    /// `step` per click — so this nudges it and sends the action, which is what
    /// the arrow key and the mouse both end up doing.
    @MainActor
    private func clickStepper(_ direction: Int, in host: NSView) throws {
        let stepper = try XCTUnwrap(steppers(in: host).first, "the warning level has no stepper")
        stepper.integerValue = stepper.integerValue + direction
        _ = stepper.sendAction(stepper.action, to: stepper.target)
        settle()
    }

    /// The "warn me again at the cap itself" switch. Matched as either an
    /// `NSSwitch` or an `NSButton`, because which one a `Toggle` becomes is the
    /// style's business and has changed with the OS; this pane has no other
    /// button, so there is nothing else the match could catch.
    @MainActor
    private func setWarnsAtCap(_ on: Bool, in host: NSView) throws {
        let control = try XCTUnwrap(
            controls(in: host).first { $0 is NSSwitch || $0 is NSButton },
            "the cap warning has no switch"
        )
        if let toggle = control as? NSSwitch {
            toggle.state = on ? .on : .off
        } else if let button = control as? NSButton {
            button.state = on ? .on : .off
        }
        _ = control.sendAction(control.action, to: control.target)
        settle()
    }

    /// The levels every budget in the store is carrying, which is what
    /// `writeLevels` is supposed to make identical.
    @MainActor
    private func levels(_ store: BudgetStore) -> [[Double]] {
        store.budgets.keys.sorted().compactMap { store.budgets[$0]?.alertsAt }
    }

    // MARK: - The pane builds

    /// Nothing reported, nothing capped. The pane has to say why it is empty
    /// rather than draw nothing, and it must not invent a field to type into for
    /// a service that reports no figure to measure against.
    @MainActor
    func testThePaneBuildsWithNoBudgetsAndNoSpend() throws {
        let bench = try bench()
        let host = hosted(bench.pane)

        XCTAssertGreaterThan(host.fittingSize.height, 0, "the empty pane collapsed")
        XCTAssertGreaterThanOrEqual(
            controls(in: host).count, 2,
            "the stepper and the switch are not being built"
        )
        XCTAssertTrue(
            capFields(in: host).isEmpty,
            "a pane with nothing to cap drew \(capFields(in: host).count) cap fields"
        )
        XCTAssertTrue(bench.store.budgets.isEmpty, "drawing the pane invented a budget")
        XCTAssertNil(
            bench.defaults.data(forKey: Self.budgetsKey),
            "opening the pane persisted budgets nobody set"
        )
    }

    /// Short windows are the ordinary case for a settings sheet on a laptop. The
    /// Form has to scroll rather than collapse, and the rows have to survive it.
    @MainActor
    func testThePaneSurvivesAShortWindow() throws {
        let bench = try bench(reports: ["claude": report("claude", minor: 3284)])
        let host = hosted(bench.pane, height: 300)
        XCTAssertGreaterThan(controls(in: host).count, 1, "the form collapsed in a 300pt window")
    }

    /// A refresh that failed, and one that succeeded without a spend figure.
    /// Neither is a row: the pane lists services that reported a figure, and an
    /// error is not a figure.
    @MainActor
    func testAFailedOrSilentSnapshotIsNotARow() throws {
        let bench = try bench()
        bench.state.snapshots["claude"] = .failure(.sessionExpired)
        bench.state.snapshots["grok"] = .success(snapshot("grok", spend: nil))

        let host = hosted(bench.pane)
        XCTAssertTrue(
            capFields(in: host).isEmpty,
            "a failed refresh and a reading with no spend drew a cap field between them"
        )
    }

    /// Every span a provider can bill on has to draw. `Period` is a switch in
    /// the pane's own extension, so a case added without a title would not
    /// compile — but a case added with an empty one would, and this is what
    /// notices the row went blank.
    @MainActor
    func testEveryBillingPeriodBuildsARow() throws {
        let periods: [SpendReport.Period] = [.rollingHours(24), .day, .week, .month, .lifetime]
        for (index, period) in periods.enumerated() {
            let bench = try bench(
                "period-\(index)",
                reports: ["claude": report("claude", minor: 1234, period: period)]
            )
            let host = hosted(bench.pane)
            XCTAssertEqual(
                capFields(in: host).count, 2,
                "a \(period) report did not draw its row and the total"
            )
        }
    }

    // MARK: - Which services get a row

    /// A service reporting a figure with no cap set gets a row with an empty
    /// field, and so does the total under it.
    ///
    /// The figure itself is a `Text` and cannot be read back here; what can be
    /// read is that the field beside it is empty rather than seeded with a zero,
    /// which is the same distinction the pane draws with an em dash — "no cap"
    /// and "a cap of nothing" are different states.
    @MainActor
    func testAServiceReportingSpendWithNoBudgetShowsAnEmptyCapField() throws {
        let bench = try bench(reports: ["claude": report("claude", minor: 3284)])
        let host = hosted(bench.pane)

        let fields = capFields(in: host)
        XCTAssertEqual(fields.count, 2, "one reporting service is its own row and the total")
        for field in fields {
            XCTAssertEqual(field.stringValue, "", "an uncapped service opened with something in its field")
        }
        XCTAssertTrue(bench.store.budgets.isEmpty, "drawing an uncapped row created a budget")
    }

    /// Two accounts of one service are one row, because they are one
    /// subscription and one bill. If they ever became two, the cap would split
    /// itself the moment somebody signed in twice.
    @MainActor
    func testTwoAccountsOfOneServiceShareOneRow() throws {
        let second = AnyUsageProvider(ClaudeProvider(accountID: "2"))
        XCTAssertEqual(second.id, "claude#2")
        XCTAssertEqual(second.serviceID, "claude", "the second account must stay in the same service")

        let bench = try bench(
            reports: [
                "claude": report("claude", minor: 1000),
                "claude#2": report("claude#2", minor: 2000)
            ],
            accounts: [second]
        )
        let host = hosted(bench.pane)
        XCTAssertEqual(
            capFields(in: host).count, 2,
            "two accounts of one service drew \(capFields(in: host).count) fields instead of one row and the total"
        )
    }

    /// A budget outlives the service reporting: signed out, disabled, or simply
    /// answering an error this refresh. The row has to stay, or the cap is one
    /// the user can neither see nor clear.
    @MainActor
    func testABudgetOnAServiceThatStoppedReportingKeepsItsRow() throws {
        let bench = try bench(budgets: ["claude": Budget(amountMinor: 5000)])
        let host = hosted(bench.pane)

        let fields = capFields(in: host)
        XCTAssertEqual(fields.count, 1, "the orphaned budget lost its row, or gained a total to sit under")
        XCTAssertEqual(
            fields.first?.stringValue, "50",
            "the field did not open on the cap that is actually stored"
        )
    }

    /// The overall budget is not a service and must not be listed as one. With
    /// nothing reported there is nothing to add up, so the only row is the one
    /// holding the orphaned cap.
    @MainActor
    func testTheOverallBudgetIsNotDrawnAsAService() throws {
        let bench = try bench(budgets: [BudgetStore.overallKey: Budget(amountMinor: 10_000)])
        let host = hosted(bench.pane)
        XCTAssertTrue(
            capFields(in: host).isEmpty,
            "the overall cap was drawn as a service row with nothing to total"
        )
    }

    // MARK: - What the field opens on

    /// A cap is stored in the minor unit the service reports in, so a provider
    /// billing in micro-units gets a cap in micro-units — and the field still
    /// has to open on the number the user typed, not on ten thousand times it.
    @MainActor
    func testACapIsShownInTheUnitTheServiceReportsIn() throws {
        let bench = try bench(
            budgets: ["claude": Budget(amountMinor: 50_000_000)],
            reports: ["claude": report("claude", minor: 1_234_567, exponent: 6)]
        )
        let host = hosted(bench.pane)
        XCTAssertEqual(
            capFields(in: host).first?.stringValue, "50",
            "a micro-billed cap opened at the wrong scale"
        )
    }

    /// Either side of the only boundary the field has: a cap of nothing is no
    /// cap, and one minor unit is a cap.
    @MainActor
    func testAZeroCapOpensEmptyAndTheSmallestCapDoesNot() throws {
        let zero = try bench("zero-cap", budgets: ["claude": Budget(amountMinor: 0)])
        XCTAssertEqual(
            capFields(in: hosted(zero.pane)).first?.stringValue, "",
            "a cap of zero opened as a cap rather than as none"
        )

        let smallest = try bench("smallest-cap", budgets: ["claude": Budget(amountMinor: 1)])
        let shown = try XCTUnwrap(capFields(in: hosted(smallest.pane)).first?.stringValue)
        XCTAssertFalse(shown.isEmpty, "one cent of cap read as no cap at all")
        XCTAssertEqual(
            shown,
            (Decimal(1) / 100).formatted(.number.precision(.fractionLength(0...2))),
            "the smallest cap is not being written in the reader's own locale"
        )
    }

    /// Opening the pane must not move the number in it. Every field writes
    /// through as it is seeded, so a round trip that lost a digit would edit the
    /// user's caps by being looked at.
    @MainActor
    func testOpeningThePaneLeavesAStoredCapWhereItWas() throws {
        let bench = try bench(
            budgets: ["claude": Budget(amountMinor: 4999), BudgetStore.overallKey: Budget(amountMinor: 25_000)],
            reports: ["claude": report("claude", minor: 3284)]
        )
        _ = hosted(bench.pane)

        XCTAssertEqual(bench.store.budget(for: "claude")?.amountMinor, 4999)
        XCTAssertEqual(bench.store.budget(for: BudgetStore.overallKey)?.amountMinor, 25_000)
        XCTAssertEqual(bench.store.budgets.count, 2, "drawing the pane added or dropped a budget")
    }

    // MARK: - Typing

    /// The pane is modeless: there is no save button, so a cap has to land as it
    /// is typed or it lands never.
    @MainActor
    func testTypingAnAmountWritesItThroughToTheStore() throws {
        let bench = try bench(reports: ["claude": report("claude", minor: 3284)])
        let host = hosted(bench.pane)
        let field = try XCTUnwrap(capFields(in: host).first)

        try type("50", into: field)

        let budget = try XCTUnwrap(bench.store.budget(for: "claude"), "the cap was not written through")
        XCTAssertEqual(budget.amountMinor, 5000, "fifty dollars is five thousand cents")
        XCTAssertEqual(
            budget.currency, "USD",
            "a new cap must be stated in the currency the service bills in"
        )
        XCTAssertEqual(
            budget.alertsAt, Budget.defaultAlerts,
            "the first cap set must inherit the levels the pane is already showing"
        )
        XCTAssertNotNil(
            bench.defaults.data(forKey: Self.budgetsKey),
            "the cap was never persisted to the store the pane was given"
        )
    }

    /// A fraction has to survive the field, and it has to survive it in the
    /// reader's own locale — a decimal comma is a decimal comma.
    @MainActor
    func testTypingAFractionalAmountKeepsItsMinorUnits() throws {
        let bench = try bench(reports: ["claude": report("claude", minor: 100)])
        let host = hosted(bench.pane)
        let typed = (Decimal(1250) / 100).formatted(.number.precision(.fractionLength(0...2)))

        try type(typed, into: try XCTUnwrap(capFields(in: host).first))

        XCTAssertEqual(
            bench.store.budget(for: "claude")?.amountMinor, 1250,
            "typing \(typed) did not come back as 1250 minor units"
        )
    }

    /// The same keystrokes on a micro-billed service mean a different number of
    /// minor units, because the cap is compared against that provider's own
    /// figure and nothing anywhere converts between scales.
    @MainActor
    func testTypingOnAMicroBilledServiceWritesMicroUnits() throws {
        let bench = try bench(reports: ["claude": report("claude", minor: 1_234_567, exponent: 6)])
        let host = hosted(bench.pane)

        try type("50", into: try XCTUnwrap(capFields(in: host).first))

        XCTAssertEqual(
            bench.store.budget(for: "claude")?.amountMinor, 50_000_000,
            "fifty dollars of a micro-billed service is fifty million micro-units"
        )
    }

    /// Clearing is the only way to remove a cap, and it has to remove it rather
    /// than set one of zero — a cap of zero is a cap every spend is already over.
    @MainActor
    func testClearingAnAmountRemovesTheBudgetRatherThanSettingZero() throws {
        let bench = try bench(
            budgets: ["claude": Budget(amountMinor: 5000)],
            reports: ["claude": report("claude", minor: 3284)]
        )
        let host = hosted(bench.pane)
        let field = try XCTUnwrap(capFields(in: host).first)
        XCTAssertEqual(field.stringValue, "50", "the field did not open on the stored cap")

        try type("", into: field)

        XCTAssertNil(bench.store.budget(for: "claude"), "clearing the field left the budget behind")
        XCTAssertFalse(
            bench.store.budgets.keys.contains("claude"),
            "clearing the field stored a cap of zero instead of removing it"
        )
    }

    /// What is typed into a currency field is not always an amount. None of
    /// these is a cap, and none of them is a reason for the pane to hold one.
    @MainActor
    func testTypingSomethingThatIsNotAnAmountLeavesNoCap() throws {
        let nonsense = ["abc", "-50", "0", " ", "--", "cap"]
        for (index, typed) in nonsense.enumerated() {
            let bench = try bench(
                "nonsense-\(index)",
                reports: ["claude": report("claude", minor: 3284)]
            )
            let host = hosted(bench.pane)
            try type(typed, into: try XCTUnwrap(capFields(in: host).first))

            XCTAssertNil(
                bench.store.budget(for: "claude"),
                "\(typed.debugDescription) was accepted as a spending cap"
            )
        }
    }

    /// A cap nobody could spend is a typo. It is clamped rather than scaled up
    /// into an overflow, which is what would happen to a micro-unit exponent
    /// times twelve digits.
    @MainActor
    func testAnAbsurdAmountIsClampedRatherThanOverflowing() throws {
        let bench = try bench(reports: ["claude": report("claude", minor: 100, exponent: 6)])
        let host = hosted(bench.pane)

        try type("999999999999999", into: try XCTUnwrap(capFields(in: host).first))

        let budget = try XCTUnwrap(bench.store.budget(for: "claude"))
        XCTAssertEqual(
            budget.amountMinor, 1_000_000_000 * 1_000_000,
            "the ceiling is not being applied before the amount is scaled"
        )
        XCTAssertGreaterThan(budget.amountMinor, 0, "an absurd cap came back negative, so it overflowed")
    }

    /// The total's cap lives under its own key, not under a service. If it ever
    /// landed on a service id, one row would silently be capping everything.
    @MainActor
    func testTheTotalsCapIsWrittenUnderTheOverallKey() throws {
        let bench = try bench(reports: ["claude": report("claude", minor: 3284)])
        let host = hosted(bench.pane)
        let fields = capFields(in: host)
        XCTAssertEqual(fields.count, 2)

        try type("500", into: fields[1])

        XCTAssertEqual(
            bench.store.budget(for: BudgetStore.overallKey)?.amountMinor, 50_000,
            "the overall cap was not written under the overall key"
        )
        XCTAssertNil(bench.store.budget(for: "claude"), "the overall cap was written onto a service")
    }

    // MARK: - Currencies

    /// Nothing in this app converts between currencies, so a figure in another
    /// one is named rather than folded into the total. The sentence saying so is
    /// a `Text` this harness cannot read, but it is a whole extra view: the same
    /// two services in one currency draw a shorter form than in two.
    @MainActor
    func testAReportInAnotherCurrencyIsExcludedFromTheTotalRatherThanFoldedIn() throws {
        let overall = [BudgetStore.overallKey: Budget(amountMinor: 10_000, currency: "EUR")]

        let matched = try bench(
            "currency-matched",
            budgets: overall,
            reports: [
                "claude": report("claude", minor: 3284, currency: "EUR"),
                "cursor": report("cursor", minor: 1200, currency: "EUR")
            ]
        )
        let mixed = try bench(
            "currency-mixed",
            budgets: overall,
            reports: [
                "claude": report("claude", minor: 3284, currency: "EUR"),
                "cursor": report("cursor", minor: 1200, currency: "USD")
            ]
        )

        let same = hosted(matched.pane)
        let split = hosted(mixed.pane)

        XCTAssertEqual(capFields(in: same).count, 3, "two services and the total is three fields")
        XCTAssertEqual(
            capFields(in: split).count, capFields(in: same).count,
            "the excluded service lost its own row, which is where its figure is stated"
        )
        XCTAssertGreaterThan(
            split.fittingSize.height, same.fittingSize.height,
            "the pane is \(split.fittingSize.height)pt with a currency left out against "
                + "\(same.fittingSize.height)pt with none — nothing is being said about the omission"
        )
    }

    /// The total is stated in the currency the overall cap was set in, so long
    /// as something is actually billed in it — that is the currency the cap
    /// field on the total row has to be taken in, and typing into it must not
    /// restate the cap in somebody else's.
    @MainActor
    func testTheTotalKeepsTheCurrencyItsCapWasSetIn() throws {
        let bench = try bench(
            budgets: [BudgetStore.overallKey: Budget(amountMinor: 10_000, currency: "EUR")],
            reports: [
                "claude": report("claude", minor: 3284, currency: "EUR"),
                "cursor": report("cursor", minor: 1200, currency: "USD")
            ]
        )
        let host = hosted(bench.pane)
        let fields = capFields(in: host)
        XCTAssertEqual(fields.count, 3)

        try type("250", into: fields[2])

        let overall = try XCTUnwrap(bench.store.budget(for: BudgetStore.overallKey))
        XCTAssertEqual(overall.amountMinor, 25_000)
        XCTAssertEqual(
            overall.currency, "EUR",
            "retyping the total's cap moved it into a currency the user never chose"
        )
    }

    // MARK: - Figures that are not readings

    /// Nothing a provider can put in an amount is a reason for the settings
    /// window not to open: a refund, a zero, and both ends of the integers a
    /// saturating total can produce.
    @MainActor
    func testExtremeAmountsStillBuildThePane() throws {
        let amounts = [0, -1, -100_000, Int.max, Int.min, 1]
        for (index, minor) in amounts.enumerated() {
            let bench = try bench(
                "extreme-\(index)",
                budgets: [
                    "claude": Budget(amountMinor: 5000),
                    BudgetStore.overallKey: Budget(amountMinor: 10_000)
                ],
                reports: ["claude": report("claude", minor: minor)]
            )
            let host = hosted(bench.pane)
            XCTAssertEqual(
                capFields(in: host).count, 2,
                "a spend of \(minor) did not draw its row and the total"
            )
            XCTAssertGreaterThan(host.fittingSize.height, 0, "a spend of \(minor) collapsed the pane")
        }
    }

    /// A cap and a spend can sit either side of each other or exactly on top,
    /// and the row past the cap is drawn differently from the row on it — "over
    /// by" is not "left". The wording is out of reach here; that all three
    /// build, and that the boundary is where the policy says it is, is not.
    @MainActor
    func testEitherSideOfTheCapBuildsAndTheBoundaryIsWhereThePolicySaysItIs() throws {
        let cases: [(name: String, minor: Int, isOver: Bool)] = [
            ("under", 4999, false),
            ("exactly on the cap", 5000, false),
            ("over", 5001, true)
        ]
        for testCase in cases {
            let bench = try bench(
                "cap-\(testCase.minor)",
                budgets: ["claude": Budget(amountMinor: 5000)],
                reports: ["claude": report("claude", minor: testCase.minor)]
            )
            let host = hosted(bench.pane)
            XCTAssertEqual(
                capFields(in: host).count, 2,
                "\(testCase.name) did not draw its row and the total"
            )

            let status = BudgetPolicy.status(
                spend: report("claude", minor: testCase.minor),
                budget: Budget(amountMinor: 5000)
            )
            XCTAssertEqual(
                status?.isOver, testCase.isOver,
                "\(testCase.name) is on the wrong side of the boundary the row's wording turns on"
            )
        }
    }

    /// The qualifier on a figure the app priced up itself rather than read off
    /// an invoice. Its sentence cannot be read back from a hosted Form, so what
    /// is pinned here is the flag the sentence is switched on by, plus that both
    /// kinds of report draw the same row — if an estimate ever stopped building,
    /// the pane would be hiding the guess rather than qualifying it.
    ///
    /// That the *figure* is drawn differently, and not only the prose under it,
    /// is a separate claim and is pinned under "How a figure is drawn" below.
    @MainActor
    func testAnEstimatedFigureBuildsAndCarriesTheFlagTheQualifierRestsOn() throws {
        XCTAssertTrue(
            report("claude", minor: 100, confidence: .estimated).isEstimate,
            "an estimated report must say so, or the row's qualifier can never appear"
        )
        XCTAssertFalse(
            report("claude", minor: 100, confidence: .measured).isEstimate,
            "a measured report must not be qualified as a guess"
        )

        for (index, confidence) in [SpendReport.Confidence.measured, .estimated].enumerated() {
            let bench = try bench(
                "confidence-\(index)",
                reports: ["claude": report("claude", minor: 3284, confidence: confidence)]
            )
            XCTAssertEqual(
                capFields(in: hosted(bench.pane)).count, 2,
                "a \(confidence.rawValue) figure did not draw its row and the total"
            )
        }
    }

    // MARK: - How a figure is drawn

    /// The guard the two tests under this one rest on: the same pane, built twice
    /// over two stores, comes back as the same raster to the byte.
    ///
    /// Without it a pixel comparison is unattributable — a difference could be a
    /// caret, an animation that had not settled, or a scratch domain — and with
    /// it a difference is the pane. The blank check is here for the same reason:
    /// two blank rasters are identical too, and a test that subtracted them would
    /// pass while measuring nothing at all.
    @MainActor
    func testTheSamePaneRastersToTheSamePixels() throws {
        let first = try bench("raster-control-first", reports: ["claude": report("claude", minor: 3284)])
        let second = try bench("raster-control-second", reports: ["claude": report("claude", minor: 3284)])

        let control = try raster(hosted(first.pane))
        XCTAssertGreaterThan(
            control.painted, 0,
            "the raster came back a single flat colour, so cacheDisplay is no longer drawing the Form"
        )

        let repeated = try raster(hosted(second.pane))
        XCTAssertNil(
            repeated.changedExtent(from: control),
            "one pane drew itself two ways, so a difference between two rasters proves nothing"
        )
    }

    /// Every money figure occupies `Tokens.moneyWidth`, and the column is constant
    /// from `$0.00` to `$1,234.56`.
    ///
    /// Money is the one rail in this app allowed its decimals, and the decimals
    /// are the digits that tick: a bill crossing $9.99 to $10.00 would otherwise
    /// take a cell of width with it and drag the field beside it sideways. So the
    /// claim is not about the amount at all — it is that *everything else* is
    /// where it was. Two panes differing only in what was spent are subtracted,
    /// and everything that moved has to fit inside the rail: the figure changes in
    /// its own eight cells, and nothing else in the pane moves at all.
    ///
    /// The last two amounts are the ones that catch a column that is merely wide
    /// enough today. `$1,234.56` is nine cells once the reader's locale has put
    /// its grouping separator in, and the one after it is fifteen; both have to
    /// stay inside the eight the rail reserves — scaled down or truncated,
    /// whichever the row chose — because immediately before the rail is the
    /// service's own prose, and a figure drawn over prose is a fault rather than a
    /// decision.
    @MainActor
    func testEveryMoneyFigureOccupiesTheMoneyRailAndTheColumnIsConstant() throws {
        let ground = try bench("money-rail-ground", reports: ["claude": report("claude", minor: 0)])
        let groundHost = hosted(ground.pane)
        let rail = try moneyRail(in: groundHost)
        let base = try raster(groundHost)

        // An amount scaled down to fit its rail can lay antialiasing on the pixel
        // either side of it, and a raster is read in whole pixels. The rail is a
        // claim about the layout rather than about which pixels the rasteriser
        // touched, so it is allowed a hairline at each edge — a hairline against
        // the eight points a further cell would cost, so nothing this test is
        // looking for can hide inside the allowance.
        let allowance = Tokens.Space.hairline
        let permitted = (rail.lowerBound - allowance)...(rail.upperBound + allowance)

        // Cents, three figures, four figures and the point, and an amount far past
        // anything eight cells were sized for.
        for minor in [999, 99_999, 123_456, 99_999_999_999] {
            let other = try bench("money-rail-\(minor)", reports: ["claude": report("claude", minor: minor)])
            let host = hosted(other.pane)

            XCTAssertEqual(
                host.fittingSize.height, groundHost.fittingSize.height,
                "a spend of \(minor) minor units changed the pane's height, so its rows are no "
                    + "longer where the pane it is being compared against left them"
            )
            XCTAssertEqual(
                try moneyRail(in: host), rail,
                "a spend of \(minor) minor units moved the row's trailing edge, so the amount is "
                    + "pushing the cap field rather than sitting in a rail"
            )

            let moved = try XCTUnwrap(
                try raster(host).changedExtent(from: base),
                "a spend of \(minor) minor units drew the pane exactly as a spend of nothing did, "
                    + "so nothing here is measuring the figure"
            )
            XCTAssertLessThanOrEqual(
                moved.upperBound - moved.lowerBound,
                Tokens.moneyWidth(Tokens.Ramp.title) + 2 * allowance,
                "\(minor) minor units moved \(moved.upperBound - moved.lowerBound)pt of the pane, "
                    + "which is wider than the \(Tokens.moneyWidth(Tokens.Ramp.title))pt rail money "
                    + "is allowed"
            )
            XCTAssertTrue(
                permitted.contains(moved.lowerBound) && permitted.contains(moved.upperBound),
                "\(minor) minor units changed the pane over \(moved), outside the rail at \(rail) — "
                    + "the figure is either being drawn in a column of its own width or spilling "
                    + "out of the one it shares with the rows above and below it"
            )
        }
    }

    /// An estimated figure is drawn differently from a measured one at the same
    /// value, and the difference reaches the figure rather than only the sentence
    /// under it.
    ///
    /// The row's prose already differs — `detail` appends "estimated" — so
    /// subtracting two whole rasters would pass on that word alone, and a pane
    /// that qualified its guesses only in prose would satisfy it while a reader
    /// scanning the column of amounts still could not tell a priced-up token count
    /// from an invoice. So what is asserted is *where* the difference reaches:
    /// past the point where the prose stops.
    ///
    /// That point is structural rather than measured, and it does not depend on
    /// how wide a lane the pane reserves for the qualifier. Whatever that lane is,
    /// it sits immediately ahead of the rail and the prose stops a gutter before
    /// it, so the prose's own trailing edge is a whole lane earlier than a gutter
    /// before the rail. A difference reaching that far is the figure or the
    /// qualifier standing beside it, and cannot be the sentence.
    @MainActor
    func testAnEstimatedFigureIsDrawnDifferentlyFromAMeasuredOneAtTheSameValue() throws {
        let measured = try bench(
            "drawn-measured",
            reports: ["claude": report("claude", minor: 3284, confidence: .measured)]
        )
        let estimated = try bench(
            "drawn-estimated",
            reports: ["claude": report("claude", minor: 3284, confidence: .estimated)]
        )

        let measuredHost = hosted(measured.pane)
        let estimatedHost = hosted(estimated.pane)
        let rail = try moneyRail(in: measuredHost)

        // Both hold, or the two rasters are of two different layouts and the
        // difference between them says nothing about how a figure was drawn.
        // They are worth having on their own as well: a row that changes height or
        // moves its controls when a figure gains a qualifier is exactly the reflow
        // the reserved columns exist to prevent.
        XCTAssertEqual(
            estimatedHost.fittingSize.height, measuredHost.fittingSize.height,
            "qualifying a figure as an estimate took the pane's height with it"
        )
        XCTAssertEqual(
            try moneyRail(in: estimatedHost), rail,
            "qualifying a figure as an estimate moved the row's trailing edge"
        )

        let moved = try XCTUnwrap(
            try raster(estimatedHost).changedExtent(from: try raster(measuredHost)),
            "an estimated $32.84 and a measured one drew the same pane pixel for pixel, so nothing "
                + "on the row says which of them is a guess"
        )
        XCTAssertGreaterThan(
            moved.upperBound, rail.lowerBound - Tokens.Space.gutter,
            "the difference between an estimated $32.84 and a measured one stops at "
                + "\(moved.upperBound)pt, short of the figure at \(rail) and its lane — the "
                + "qualifier is in the prose only, and the column of amounts a reader scans reads "
                + "a priced-up token count exactly like a bill"
        )
    }

    // MARK: - The levels

    /// Nothing to set levels on, so the controls are dimmed rather than hidden:
    /// somebody deciding whether to set a cap can see what setting one would do.
    /// Both states have to build the same controls, or the section is appearing
    /// on the first cap rather than greying out.
    @MainActor
    func testTheLevelsAreDimmedUntilThereIsACapToApplyThemTo() throws {
        let empty = hosted(try bench("levels-empty").pane)
        let capped = hosted(try bench("levels-capped", budgets: ["claude": Budget(amountMinor: 5000)]).pane)

        let idle = try XCTUnwrap(steppers(in: empty).first, "the stepper is not built with no budgets")
        let live = try XCTUnwrap(steppers(in: capped).first, "the stepper is not built with a budget")
        XCTAssertFalse(idle.isEnabled, "the levels are live with nothing to apply them to")
        XCTAssertTrue(live.isEnabled, "the levels stayed dimmed after a cap was set")
    }

    /// One set of levels for every budget, written in one assignment. Eleven
    /// budgets must not become eleven trips to disk, and none of them may be
    /// left on the old level.
    @MainActor
    func testMovingTheWarningLevelWritesToEveryBudget() throws {
        let bench = try bench(budgets: [
            "claude": Budget(amountMinor: 5000, alertsAt: [0.80, 1.0]),
            "cursor": Budget(amountMinor: 2000, alertsAt: [0.80, 1.0]),
            BudgetStore.overallKey: Budget(amountMinor: 10_000, alertsAt: [0.80, 1.0])
        ])
        let host = hosted(bench.pane)

        try clickStepper(1, in: host)

        for stored in levels(bench.store) {
            XCTAssertEqual(stored, [0.85, 1.0], "a budget was left on the old warning level")
        }
        XCTAssertEqual(bench.store.budgets.count, 3, "moving a level added or dropped a budget")
        XCTAssertEqual(
            bench.store.budget(for: "claude")?.amountMinor, 5000,
            "moving a level rewrote an amount"
        )
    }

    /// The levels shown are the overall budget's, so the section cannot show a
    /// different answer depending on which service redrew last.
    @MainActor
    func testTheLevelsShownAreTheOverallBudgetsWhenThereIsOne() throws {
        let bench = try bench(budgets: [
            "claude": Budget(amountMinor: 5000, alertsAt: [0.90]),
            BudgetStore.overallKey: Budget(amountMinor: 10_000, alertsAt: [0.50, 1.0])
        ])
        let host = hosted(bench.pane)

        try clickStepper(1, in: host)

        for stored in levels(bench.store) {
            XCTAssertEqual(
                stored, [0.55, 1.0],
                "the stepper started from a service's levels rather than the overall budget's"
            )
        }
    }

    /// With no overall budget it is the first service in id order, for the same
    /// reason: a dictionary has no order, and a stepper that starts somewhere
    /// different on each redraw is unusable.
    @MainActor
    func testWithNoOverallBudgetTheLevelsComeFromTheFirstServiceInIdOrder() throws {
        let bench = try bench(budgets: [
            "claude": Budget(amountMinor: 5000, alertsAt: [0.30]),
            "cursor": Budget(amountMinor: 2000, alertsAt: [0.90])
        ])
        let host = hosted(bench.pane)

        try clickStepper(1, in: host)

        for stored in levels(bench.store) {
            XCTAssertEqual(stored, [0.35], "the stepper did not start from the first budget in id order")
        }
    }

    /// The warning at the cap itself is a level like any other, and turning it
    /// off has to leave the early one behind rather than clear both.
    @MainActor
    func testTurningOffTheWarningAtTheCapLeavesTheEarlyOne() throws {
        let bench = try bench(budgets: [
            "claude": Budget(amountMinor: 5000, alertsAt: [0.80, 1.0]),
            BudgetStore.overallKey: Budget(amountMinor: 10_000, alertsAt: [0.80, 1.0])
        ])
        let host = hosted(bench.pane)

        try setWarnsAtCap(false, in: host)
        for stored in levels(bench.store) {
            XCTAssertEqual(stored, [0.80], "turning the cap warning off took the early warning with it")
        }

        try setWarnsAtCap(true, in: host)
        for stored in levels(bench.store) {
            XCTAssertEqual(stored, [0.80, 1.0], "the cap warning did not come back")
        }
    }

    /// The stepper is held inside 25...95, from either end and from outside.
    /// A stored level above the range is not a reason to refuse the click — it
    /// is pulled into the range, which is the only way back for a preference an
    /// older build wrote.
    @MainActor
    func testTheWarningLevelIsHeldInsideItsRange() throws {
        let cases: [(name: String, stored: [Double], direction: Int, expected: [Double]?)] = [
            ("on the floor, downwards", [0.25], -1, [0.25]),
            ("just above the floor", [0.30], -1, [0.25]),
            ("on the ceiling, upwards", [0.95], 1, [0.95]),
            ("just below the ceiling", [0.90], 1, [0.95]),
            // Above the range the pane offers, which a stored preference can be.
            // Where it lands is the platform's business; that it lands inside
            // the range is not, so this one only asserts the bound.
            ("above the ceiling", [0.97], -1, nil),
            ("at the cap only", [1.0], 1, nil)
        ]

        for (index, testCase) in cases.enumerated() {
            let bench = try bench(
                "range-\(index)",
                budgets: ["claude": Budget(amountMinor: 5000, alertsAt: testCase.stored)]
            )
            let host = hosted(bench.pane)
            try clickStepper(testCase.direction, in: host)

            let written = try XCTUnwrap(bench.store.budget(for: "claude")?.alertsAt)
            if let expected = testCase.expected {
                XCTAssertEqual(written, expected, "\(testCase.name) did not land where the range says")
            }
            let early = try XCTUnwrap(
                written.first { $0 < 1 },
                "\(testCase.name) left no warning below the cap"
            )
            XCTAssertTrue(
                (0.25...0.95).contains(early),
                "\(testCase.name) left the level at \(early), outside the range the stepper offers"
            )
        }
    }

    // MARK: - What a stored blob can contain

    /// A blob that no longer decodes is discarded rather than repaired, and the
    /// pane opens on no budgets. The settings window not opening is the failure
    /// mode being avoided here.
    @MainActor
    func testAMalformedBlobIsDiscardedAndThePaneStillBuilds() throws {
        let blobs: [(name: String, data: Data)] = [
            ("not json", Data("{ not json".utf8)),
            ("empty", Data()),
            ("an array", Data("[]".utf8)),
            ("a bare number", Data("7".utf8)),
            ("a budget that is a string", Data(#"{"claude":"50"}"#.utf8)),
            ("a budget with no fields", Data(#"{"claude":{}}"#.utf8)),
            ("a budget with the wrong types", Data(#"{"claude":{"amountMinor":"lots"}}"#.utf8))
        ]

        for blob in blobs {
            let bench = try bench("blob-\(blob.name)", stored: blob.data)
            let host = hosted(bench.pane)
            XCTAssertGreaterThan(host.fittingSize.height, 0, "\(blob.name) collapsed the pane")
            XCTAssertGreaterThanOrEqual(
                controls(in: host).count, 2,
                "\(blob.name) took the form with it"
            )
        }
    }

    /// A blob that decodes but says something the editor never could. Every one
    /// of these has to come back cleaned and draw a field, because the pane is
    /// where the user goes to fix them.
    @MainActor
    func testDegenerateStoredBudgetsAreCleanedAndStillBuildThePane() throws {
        let cases: [(name: String, json: String, amount: Int, currency: String)] = [
            ("negative amount", #"{"amountMinor":-5000,"currency":"USD","alertsAt":[0.8]}"#, 0, "USD"),
            ("no currency", #"{"amountMinor":5000,"alertsAt":[0.8]}"#, 5000, "USD"),
            ("blank currency", #"{"amountMinor":5000,"currency":"   ","alertsAt":[0.8]}"#, 5000, "USD"),
            ("lower case currency", #"{"amountMinor":5000,"currency":" eur ","alertsAt":[0.8]}"#, 5000, "EUR"),
            ("no levels", #"{"amountMinor":5000,"currency":"USD","alertsAt":[]}"#, 5000, "USD"),
            ("levels at zero", #"{"amountMinor":5000,"currency":"USD","alertsAt":[0,0]}"#, 5000, "USD"),
            ("negative levels", #"{"amountMinor":5000,"currency":"USD","alertsAt":[-1,-0.5]}"#, 5000, "USD"),
            ("levels past the cap", #"{"amountMinor":5000,"currency":"USD","alertsAt":[1.5,9]}"#, 5000, "USD"),
            ("eight levels", #"{"amountMinor":5000,"currency":"USD","alertsAt":[0.1,0.2,0.3,0.4,0.5,0.6,0.7,0.8]}"#, 5000, "USD"),
            ("levels out of order", #"{"amountMinor":5000,"currency":"USD","alertsAt":[1.0,0.4]}"#, 5000, "USD"),
            ("an enormous amount", #"{"amountMinor":9223372036854775807,"currency":"USD","alertsAt":[0.8]}"#, .max, "USD")
        ]

        for testCase in cases {
            let bench = try bench(
                "degenerate-\(testCase.name)",
                stored: Data(#"{"claude":\#(testCase.json)}"#.utf8)
            )
            let stored = try XCTUnwrap(
                bench.store.budget(for: "claude"),
                "\(testCase.name) was thrown away rather than cleaned"
            )
            XCTAssertEqual(stored.amountMinor, testCase.amount, "\(testCase.name) kept a bad amount")
            XCTAssertEqual(stored.currency, testCase.currency, "\(testCase.name) kept a bad currency")
            XCTAssertTrue(
                stored.alertsAt.allSatisfy { $0.isFinite && $0 > 0 && $0 <= 1 },
                "\(testCase.name) kept a level the pane would have to convert to an Int"
            )
            XCTAssertLessThanOrEqual(stored.alertsAt.count, 4, "\(testCase.name) kept more levels than four")

            let host = hosted(bench.pane)
            XCTAssertEqual(
                capFields(in: host).count, 1,
                "\(testCase.name) did not draw the row its cap is fixed from"
            )
            XCTAssertGreaterThanOrEqual(
                controls(in: host).count, 2,
                "\(testCase.name) took the levels section with it"
            )
        }
    }

    /// The pane converts a level with `Int((level * 100).rounded())`, which traps
    /// on a NaN or an infinity rather than drawing anything. What keeps that
    /// unreachable is the storage rather than the pane: JSON has no spelling for
    /// either, so a level that survived a launch is finite by construction — and
    /// `Budget` drops them on the way in as well, so neither route reaches it.
    ///
    /// Pinned here because it is the whole argument for that conversion being
    /// safe, and nothing in the pane restates it.
    @MainActor
    func testNonFiniteLevelsCannotReachThePane() throws {
        let budget = Budget(amountMinor: 5000, alertsAt: [.nan, .infinity, -.infinity, 0.8])
        XCTAssertEqual(budget.alertsAt, [0.8], "a non-finite level survived the initialiser")

        XCTAssertThrowsError(
            try JSONEncoder().encode([Double.nan]),
            "JSON has gained a spelling for NaN, so one can now reach the pane"
        )
        let roundTripped = try JSONDecoder().decode(
            [String: Budget].self,
            from: try JSONEncoder().encode([
                "claude": Budget(amountMinor: 5000, alertsAt: [.nan, .infinity])
            ])
        )
        XCTAssertEqual(
            roundTripped["claude"]?.alertsAt, [],
            "a non-finite level survived a round trip through the store"
        )

        let bench = try bench(
            stored: Data(#"{"claude":{"amountMinor":5000,"currency":"USD","alertsAt":[0.8]}}"#.utf8)
        )
        let stored = try XCTUnwrap(bench.store.budget(for: "claude"))
        XCTAssertTrue(
            stored.alertsAt.allSatisfy(\.isFinite),
            "a stored level is not finite, and the pane multiplies it by a hundred and rounds"
        )
        XCTAssertGreaterThan(hosted(bench.pane).fittingSize.height, 0)
    }
}
