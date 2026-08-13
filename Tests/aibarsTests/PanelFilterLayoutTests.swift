import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// **The panel must not jump while somebody is typing.**
///
/// `MenuBarExtra` sizes its window to its content, so a list that resizes on every
/// keystroke is a window that resizes on every keystroke — which is worse than no
/// filter at all, and is the one thing every other part of this panel reserves
/// space to avoid. The policy is that the list box is latched at its resting height
/// the moment filter mode opens and held for as long as filtering lasts; these
/// cases are that policy, measured.
///
/// The resting height is injected rather than measured here, and that is not a
/// convenience. In the app it is taken off a completed layout pass through a
/// preference; a test measuring with `fittingSize` gets one pass and no chance to
/// feed anything back. `restingListHeight:` on the initialiser is what makes the
/// claim assertable at all.
final class PanelFilterLayoutTests: XCTestCase {

    /// A scratch defaults domain per case, emptied on the way in.
    ///
    /// `AppearanceSettings` decodes in `init`, and several suites in this target
    /// walk the shared object's `panelWidth` and put it back in a `defer` — so a
    /// run interrupted inside one of those loops leaves the standard domain with
    /// somebody else's panel in it. Nothing here reads that domain.
    @MainActor
    private func appearance(_ name: String) throws -> AppearanceSettings {
        let domain = "aibars.panel-filter-layout.\(name)"
        let store = try XCTUnwrap(UserDefaults(suiteName: domain), "could not open a scratch domain")
        store.removePersistentDomain(forName: domain)
        return AppearanceSettings(store: store)
    }

    /// Six services connected and reporting, which is a panel with enough rows for
    /// a filter to have something to remove.
    @MainActor
    private func populatedState() -> AppState {
        let state = AppState()
        for (index, provider) in state.providers.prefix(6).enumerated() {
            provider.isAuthenticated = true
            state.snapshots[provider.id] = .success(UsageData(
                providerID: provider.id,
                planName: "Pro",
                primary: UsageMetric(
                    label: "5h window", used: Double(index * 12), limit: 100, unit: "%"
                ),
                secondary: [UsageMetric(label: "Weekly", used: 40, limit: 100, unit: "%")]
            ))
        }
        state.lastRefresh = Date().addingTimeInterval(-12)
        return state
    }

    @MainActor
    private func height(
        _ state: AppState,
        _ appearance: AppearanceSettings,
        keyboard: PanelKeyboardState,
        restingListHeight: CGFloat?
    ) -> CGFloat {
        let panel = MenuBarContentView(
            state: state,
            showSettings: .constant(false),
            appearance: appearance,
            keyboard: keyboard,
            restingListHeight: restingListHeight
        )
        return NSHostingView(rootView: AnyView(panel)).fittingSize.height
    }

    /// How many rows a query leaves on the panel, through the same call `body`
    /// makes — so the counts these cases state are the counts the panel drew.
    @MainActor
    private func matches(_ query: String, _ state: AppState, _ appearance: AppearanceSettings) -> Int {
        PanelFilter.apply(
            query: query,
            to: appearance.sections(from: state.rankedProviders, snapshots: state.snapshots),
            all: state.providers,
            snapshots: state.snapshots
        ).rows.count
    }

    // MARK: - The claim

    /// **The one this whole feature is judged on.**
    @MainActor
    func testAQueryThatRemovesRowsDoesNotChangeTheListBox() throws {
        let appearance = try appearance("box")
        let state = populatedState()

        // Stated rather than assumed: "cod" is Codex by prefix, Claude Code and
        // OpenCode by substring; "grok" is one row and nothing else.
        XCTAssertEqual(matches("cod", state, appearance), 3)
        XCTAssertEqual(matches("grok", state, appearance), 1)

        let three = height(state, appearance, keyboard: .filtering("cod"), restingListHeight: 400)
        let one = height(state, appearance, keyboard: .filtering("grok"), restingListHeight: 400)

        XCTAssertEqual(
            three, one, accuracy: 0.5,
            "three matches measured \(three)pt and one measured \(one)pt — the window resizes as you type"
        )
    }

    @MainActor
    func testAFilteredListHoldsTheHeightItWasLatchedAt() throws {
        let appearance = try appearance("latch")
        let state = populatedState()

        let short = height(state, appearance, keyboard: .filtering("cod"), restingListHeight: 400)
        let tall = height(state, appearance, keyboard: .filtering("cod"), restingListHeight: 500)

        XCTAssertEqual(
            tall - short, 100, accuracy: 0.5,
            "the latch is not being spent: 400 and 500 produced \(short)pt and \(tall)pt"
        )
    }

    /// A latch taken from a list that was already scrolling must not be allowed to
    /// grow the window past the screen. Mirrors `PanelLayoutTests.testHeightStaysOnScreen`.
    @MainActor
    func testTheLatchNeverExceedsTheScreenCap() throws {
        let appearance = try appearance("cap")
        let state = populatedState()
        let measured = height(state, appearance, keyboard: .filtering("cod"), restingListHeight: 10_000)
        XCTAssertLessThanOrEqual(measured, MenuBarContentView.panelScreenHeight - 60)
    }

    /// The new modifier is inert at rest. `frame(height:)` uses the child's own
    /// dimension for a nil axis, so a resting panel measures byte-for-byte what it
    /// did before the latch existed — even with a resting height already in hand.
    @MainActor
    func testAnUnfilteredPanelIsUnchanged() throws {
        let appearance = try appearance("inert")
        let state = populatedState()

        let plain = NSHostingView(rootView: AnyView(MenuBarContentView(
            state: state,
            showSettings: .constant(false),
            appearance: appearance
        ))).fittingSize.height
        let seeded = height(state, appearance, keyboard: .resting, restingListHeight: 400)

        XCTAssertEqual(
            seeded, plain, accuracy: 0.5,
            "a resting panel with a latch in hand measured \(seeded)pt against \(plain)pt"
        )
    }

    // MARK: - The header's own box

    /// The header cannot move either, and without the `lineBox` box it would: the
    /// slot would be as tall as whichever of a `Text` and an `Image`-plus-`Rectangle`
    /// is taller, so it would grow by about a point the instant you start typing.
    @MainActor
    func testTheHeaderIsTheSameHeightFilteringAndNot() throws {
        let appearance = try appearance("header")

        func measure(summary: String?, filter: String?, matchCount: Int) -> CGFloat {
            let header = PanelHeader(
                appearance: appearance,
                summary: summary,
                filter: filter,
                matchCount: matchCount
            ) {
                Image(systemName: "arrow.clockwise")
            }
            return NSHostingView(rootView: AnyView(header.frame(width: 356))).fittingSize.height
        }

        let summarised = measure(summary: "claude 92% · updated 12s ago", filter: nil, matchCount: 0)
        let filtering = measure(summary: nil, filter: "claude", matchCount: 2)
        XCTAssertEqual(
            filtering, summarised, accuracy: 0.5,
            "the header measured \(summarised)pt with a summary and \(filtering)pt with a query"
        )

        // And the empty query — ⌘F with nothing typed — is the same box again.
        let opened = measure(summary: nil, filter: "", matchCount: 6)
        XCTAssertEqual(opened, summarised, accuracy: 0.5)
    }

    /// The no-match block is a branch of the list's own content stack rather than a
    /// sibling of it, so it occupies the same latched box the results do.
    @MainActor
    func testTheNoMatchBlockFitsTheLatchedBox() throws {
        let appearance = try appearance("nomatch")
        let state = populatedState()
        XCTAssertEqual(matches("zzzz", state, appearance), 0)

        let nothing = height(state, appearance, keyboard: .filtering("zzzz"), restingListHeight: 400)
        let one = height(state, appearance, keyboard: .filtering("grok"), restingListHeight: 400)
        XCTAssertEqual(
            nothing, one, accuracy: 0.5,
            "the empty result measured \(nothing)pt against \(one)pt for a single row"
        )
    }

    // MARK: - The selection is not a measurement

    /// `isSelected` is a fill and an accessibility trait, and it must never become
    /// an input to `RowGeometry` — the moment it does, arrowing down a list resizes
    /// the window.
    @MainActor
    func testASelectionDoesNotChangeAnyHeight() throws {
        let appearance = try appearance("selection")
        let state = populatedState()
        let first = try XCTUnwrap(state.providers.first)

        let unselected = height(state, appearance, keyboard: .resting, restingListHeight: nil)
        let selected = height(
            state, appearance,
            keyboard: PanelKeyboardState(query: "", isFiltering: false, selection: first.id),
            restingListHeight: nil
        )
        XCTAssertEqual(selected, unselected, accuracy: 0.5)

        // And the row on its own, where a geometry change would show up undiluted.
        func rowHeight(isSelected: Bool) -> CGFloat {
            let row = ProviderRow(
                provider: first,
                result: state.snapshots[first.id],
                onSignIn: {},
                appearance: appearance,
                isSelected: isSelected
            )
            .frame(width: CGFloat(appearance.panelWidth))
            return NSHostingView(rootView: AnyView(row)).fittingSize.height
        }
        XCTAssertEqual(rowHeight(isSelected: true), rowHeight(isSelected: false), accuracy: 0.01)
    }
}
