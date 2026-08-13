import XCTest
import SwiftUI
import AppKit
import Combine
@testable import aibarsCore

/// Two things the settings window has to get right that nothing else can check.
///
/// The first is **which pane is on screen**. `SettingsView` keeps its pane in
/// `State`, so `SettingsWindowController` cannot read it and has to be told;
/// when it was told only at build time, one sidebar click put its record a pane
/// behind reality and `show(state:pane:)` then compared a request against a pane
/// nobody was on and skipped the rebuild. The panel's chart button goes through
/// that call, so "open the chart" did nothing at all for the rest of the session
/// — silently, with the window sitting there on the wrong pane.
///
/// The second is that **the Interval picker is a setting and not a restart**.
/// It used to call `state.stop()` then `state.start()`, and `start()` re-runs
/// the browser-cookie sweep and a full refresh over the top of the one still in
/// flight. That one is asserted with a witness beside it — see
/// `testChangingTheRefreshIntervalStartsNoSweep` — because a test that watches
/// for something to *not* happen passes just as happily when nothing is being
/// delivered at all.
///
/// Nothing here writes a setting that outlives it: the one test that moves
/// `refreshIntervalSeconds` puts it back, and no test touches
/// `AppState.shared`, `AlertCenter.shared` or `UsageTrendStore.shared`.
final class SettingsWindowTests: XCTestCase {

    /// Windows the suite has put on screen, kept alive for the length of a test.
    /// A hosting view in a window that ARC has already released stops receiving
    /// updates, and every measurement here is of a view being updated.
    private var windows: [NSWindow] = []

    @MainActor
    override func tearDown() {
        // The settings window is a static and outlives the test that opened it —
        // deliberately, that is what makes "reopen where you left off" work — so
        // it is put away rather than closed. `close()` is gone and there is
        // nothing here that should bring it back.
        SettingsWindowController.window?.orderOut(nil)
        windows.forEach { $0.orderOut(nil) }
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - Harness

    /// Long enough for SwiftUI to run an update pass and for a `Task` scheduled
    /// on the main actor to get to its first suspension point. `start()` sets
    /// `isAdopting` from inside such a task, which is the thing being watched
    /// for, so a pump that was too short would report an absence that is really
    /// a not-yet.
    @MainActor
    private func settle(_ seconds: TimeInterval = 0.3) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    @MainActor
    private func hosted<V: View>(_ view: V) -> NSView {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: 1060, height: 620)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        windows.append(window)
        settle()
        return host
    }

    // MARK: - The view says which pane it is on

    /// The report is the whole fix, so it is asserted on its own, on a view with
    /// no window controller anywhere near it — which is also the arrangement
    /// previews and snapshots build it in.
    @MainActor
    func testTheViewReportsThePaneItIsOn() throws {
        var reported: [SettingsView.Pane] = []
        _ = hosted(
            SettingsView(initialPane: .alerts, onPaneChange: { reported.append($0) })
                .environmentObject(AppState())
        )

        XCTAssertEqual(
            reported.last, .alerts,
            "the view never said which pane it opened on, so nothing outside it can know"
        )
    }

    /// A view built with nobody listening is still a view, and still the window's
    /// declared minimum wide. Previews and snapshots take this path — it is the
    /// reason the report is a defaulted closure rather than a required one.
    @MainActor
    func testAViewBuiltWithNoOneListeningStillBuilds() throws {
        let host = hosted(SettingsView(initialPane: .about).environmentObject(AppState()))
        XCTAssertGreaterThanOrEqual(
            host.fittingSize.width, SettingsView.minimumContentSize.width,
            "the window laid out narrower than the minimum it declares"
        )
    }

    // MARK: - One window

    @MainActor
    func testThereIsOnlyEverOneSettingsWindow() throws {
        let state = AppState()
        SettingsWindowController.show(state: state, pane: .services)
        let first = try XCTUnwrap(SettingsWindowController.window)

        SettingsWindowController.show(state: state, pane: .history)
        SettingsWindowController.show(state: state)
        let latest = try XCTUnwrap(SettingsWindowController.window)

        XCTAssertTrue(
            first === latest,
            "a second show built a second window; the first one's size, position and pane are gone"
        )
        XCTAssertEqual(
            NSApp.windows.filter { $0.title == "aibars Settings" }.count, 1,
            "more than one settings window is on the screen list"
        )
    }

    /// `show(state:)` with no pane is the gear item, and it should land the user
    /// where they left off — which means on the pane they navigated to, with the
    /// window they left there rather than a rebuilt one.
    @MainActor
    func testTheGearReturnsToThePaneOnScreen() throws {
        let state = AppState()
        SettingsWindowController.show(state: state, pane: .spend)
        SettingsWindowController.notePane(.appearance)
        let onAppearance = try XCTUnwrap(SettingsWindowController.window?.contentView)

        SettingsWindowController.show(state: state)

        XCTAssertEqual(
            SettingsWindowController.shownPane, .appearance,
            "the gear reopened on the pane the window was built with, not the one it was left on"
        )
        XCTAssertTrue(
            SettingsWindowController.window?.contentView === onAppearance,
            "the gear rebuilt a window that was already showing the right pane"
        )
    }

    // MARK: - Asking for a pane

    /// The guard is worth keeping: rebuilding throws away every bit of `State`
    /// in the window — the browser sweep's results, a half-typed field — so a
    /// request for the pane already on screen must not do it.
    @MainActor
    func testAskingForThePaneOnScreenKeepsTheView() throws {
        let state = AppState()
        SettingsWindowController.show(state: state, pane: .history)
        let content = try XCTUnwrap(SettingsWindowController.window?.contentView)

        SettingsWindowController.show(state: state, pane: .history)

        XCTAssertTrue(
            SettingsWindowController.window?.contentView === content,
            "a request for the pane already on screen rebuilt the window and reset every form in it"
        )
    }

    /// The defect, in the order it happened: the panel's chart button, a sidebar
    /// click, the chart button again.
    ///
    /// The middle step is the call `SettingsView` makes when the user picks a row
    /// — it is what `hostingView` hands the view as `onPaneChange`. Before the
    /// view reported anything there was no such call, the record stayed on
    /// `.history` while the window showed Appearance, and the third step matched
    /// the guard and did nothing.
    @MainActor
    func testAskingAgainAfterTheUserNavigatesAwayIsHonoured() throws {
        let state = AppState()
        SettingsWindowController.show(state: state, pane: .history)
        let onHistory = try XCTUnwrap(SettingsWindowController.window?.contentView)

        SettingsWindowController.notePane(.appearance)
        XCTAssertEqual(
            SettingsWindowController.shownPane, .appearance,
            "the record ignored the view and stayed on the pane the window was built with"
        )

        SettingsWindowController.show(state: state, pane: .history)

        XCTAssertEqual(
            SettingsWindowController.shownPane, .history,
            "the window was asked for History and reports Appearance"
        )
        XCTAssertFalse(
            SettingsWindowController.window?.contentView === onHistory,
            "the content view was not rebuilt, so the request was skipped — the chart button did nothing"
        )
    }

    // MARK: - The refresh interval

    /// What the deleted `.onChange` did, kept as an instrument.
    ///
    /// The real assertion below is that nothing happens, and the failure mode of
    /// such a test is that nothing *could* have happened: a hosted view that is
    /// never updated hears no change and starts no sweep whatever its code says.
    /// This witness watches the same value on the same object through the same
    /// mechanism, so if SwiftUI stops delivering `onChange` in a headless host
    /// the suite says so instead of going quietly green.
    private struct IntervalWitness: View {
        @ObservedObject var state: AppState
        let onChanged: () -> Void

        var body: some View {
            Text(verbatim: "\(state.refreshIntervalSeconds)")
                .onChange(of: state.refreshIntervalSeconds) { _ in onChanged() }
        }
    }

    @MainActor
    func testChangingTheRefreshIntervalStartsNoSweep() throws {
        let state = AppState()
        let original = state.refreshIntervalSeconds
        defer { state.refreshIntervalSeconds = original }

        var witnessed = 0
        _ = hosted(IntervalWitness(state: state, onChanged: { witnessed += 1 }))
        _ = hosted(SettingsView(initialPane: .general).environmentObject(state))

        // Every adoption there is: `start()` raises this flag before the cookie
        // sweep and lowers it after, so counting its rising edge counts sweeps
        // whether or not one is still running when the pump ends.
        var adoptions = 0
        let counter = state.$isAdopting.sink { if $0 { adoptions += 1 } }
        defer { counter.cancel() }

        // The write the Interval picker's binding makes. The control itself
        // cannot be driven here — a SwiftUI `Picker` is an `NSPopUpButton` whose
        // menu is built when it is clicked, so in a headless host it has no items
        // to select — but `$state.refreshIntervalSeconds` is the binding, and
        // this is the same mutation through the same publisher.
        state.refreshIntervalSeconds = original == 300 ? 900 : 300
        settle()

        XCTAssertEqual(
            witnessed, 1,
            "the harness delivered no change at all, so this test could not have seen a sweep either"
        )
        XCTAssertEqual(
            adoptions, 0,
            "changing the interval re-ran the browser-cookie sweep \(adoptions) time(s)"
        )
        XCTAssertFalse(
            state.isRefreshing,
            "changing the interval started a refresh nobody asked for"
        )
        XCTAssertNil(
            state.lastRefresh,
            "changing the interval fetched every service; a picker is not a refresh button"
        )
    }
}
