import XCTest
import Combine
import ServiceManagement
@testable import aibarsCore

/// Launch at login is the one feature whose failure mode is a login item the
/// user never asked for.
///
/// `SMAppService.mainApp` registers whatever process is asking, so a test run
/// that reached it would add the xctest runner to the user's real Login Items
/// and leave it there long after the test passed. `LoginItem` short-circuits on
/// `isHostedInApp` for exactly that reason, and these tests hold that line:
/// nothing here may register anything, and the toggle must still answer for
/// itself while it refuses.
final class LoginItemTests: XCTestCase {
    /// Substrings unique to each of the two "unavailable" reasons. They are the
    /// only way from outside to tell which branch ran: one is produced before
    /// `SMAppService` is consulted, the other only after it answers `.notFound`.
    private let noBundleMarker = "app bundle"
    private let notFoundMarker = "can't find"

    // MARK: - The test bundle is not an app

    func testTheTestRunnerIsNotAnAppBundle() {
        XCTAssertFalse(
            LoginItem.isHostedInApp,
            "xctest looks like an app bundle to LoginItem, so every guard below is dead code"
        )
    }

    @MainActor
    func testRefreshUnderXCTestReportsUnavailableWithoutAskingTheSystem() {
        let item = LoginItem()
        item.refresh()

        guard case .unavailable(let reason) = item.state else {
            return XCTFail("state is \(item.state) — the runner was treated as a launchable app")
        }
        // The wording matters more than it looks: the notFound reason would mean
        // SMAppService was asked, which is what the guard exists to prevent.
        XCTAssertTrue(
            reason.contains(noBundleMarker),
            "expected the no-bundle reason, got \(reason)"
        )
        XCTAssertFalse(reason.contains(notFoundMarker), "SMAppService was consulted after all")
        XCTAssertFalse(item.state.isOn, "the toggle would show as on while nothing is registered")
    }

    /// Repeated refreshes are the normal case — the settings pane calls it every
    /// time its window opens — and each one must be idempotent.
    @MainActor
    func testRefreshIsIdempotent() {
        let item = LoginItem()
        let first = item.state
        for _ in 0..<5 { item.refresh() }
        XCTAssertEqual(item.state, first, "refreshing changed the answer without anything changing")
    }

    /// `apply` drops no-op assignments because the pane redraws on every
    /// publish. Under xctest the state can never legitimately change, so any
    /// publish at all is a spurious one.
    @MainActor
    func testRefreshDoesNotRepublishAnUnchangedState() {
        let item = LoginItem()
        var publishes = 0
        let token = item.objectWillChange.sink { _ in publishes += 1 }
        defer { token.cancel() }

        for _ in 0..<10 { item.refresh() }
        _ = item.setEnabled(true)
        _ = item.setEnabled(false)

        XCTAssertEqual(publishes, 0, "the pane would redraw \(publishes) times for no reason")
    }

    // MARK: - Toggling registers nothing

    @MainActor
    func testEnablingFromTheTestBundleRegistersNothing() {
        let item = LoginItem()
        let returned = item.setEnabled(true)

        guard case .unavailable(let reason) = returned else {
            return XCTFail("setEnabled(true) returned \(returned) — it tried to register the runner")
        }
        XCTAssertTrue(reason.contains(noBundleMarker), "expected the no-bundle reason, got \(reason)")
        XCTAssertEqual(returned, item.state, "the return value and the published state disagree")

        // The system's own view is the proof: if the guard had leaked, the test
        // runner would now be a login item on this machine.
        let status = SMAppService.mainApp.status
        XCTAssertNotEqual(status, .enabled, "the test runner was registered as a login item")
        XCTAssertNotEqual(status, .requiresApproval, "the test runner is awaiting login item approval")
    }

    /// Turning it off has the same guard in front of it, and `unregister()` on
    /// something never registered throws — so this is the call most likely to
    /// escape as an error if the swallow ever went away.
    @MainActor
    func testDisablingFromTheTestBundleIsEquallyInert() {
        let item = LoginItem()
        let returned = item.setEnabled(false)

        guard case .unavailable(let reason) = returned else {
            return XCTFail("setEnabled(false) returned \(returned)")
        }
        XCTAssertTrue(reason.contains(noBundleMarker), "expected the no-bundle reason, got \(reason)")
        XCTAssertFalse(returned.isOn)
    }

    /// Both directions, several times, in the order a user flicking a switch
    /// would produce. Nothing may throw, nothing may change, nothing may be
    /// registered.
    @MainActor
    func testFlickingTheToggleRepeatedlyChangesNothing() {
        let item = LoginItem()
        let start = item.state
        for enabled in [true, false, true, true, false, false] {
            XCTAssertEqual(item.setEnabled(enabled), start, "setEnabled(\(enabled)) moved the state")
        }
        XCTAssertNotEqual(SMAppService.mainApp.status, .enabled, "something got registered")
    }

    /// The app delegate reads the singleton at launch, so it must be inert here
    /// too — and reading it must not be what registers the runner.
    @MainActor
    func testTheSharedInstanceIsUnavailableToo() {
        guard case .unavailable(let reason) = LoginItem.shared.state else {
            return XCTFail("shared state is \(LoginItem.shared.state)")
        }
        XCTAssertTrue(reason.contains(noBundleMarker), "expected the no-bundle reason, got \(reason)")
        XCTAssertNotEqual(SMAppService.mainApp.status, .enabled)
    }

    // MARK: - What each state tells the user

    /// The two states that need no explanation must not invent one, and the two
    /// that do must not come back blank — a nil note hides the only instruction
    /// the user has.
    func testOnlySettledStatesHaveNoNote() {
        XCTAssertNil(LoginItemState.enabled.note)
        XCTAssertNil(LoginItemState.disabled.note)

        let speaking: [LoginItemState] = [
            .requiresApproval,
            .unavailable("macOS refused"),
        ]
        for state in speaking {
            let note = state.note
            XCTAssertNotNil(note, "\(state) has nothing to say")
            XCTAssertFalse(note?.isEmpty ?? true, "\(state) has an empty note")
        }
    }

    /// The approval note has to name the destination, since the switch stays on
    /// and nothing else tells the user there is anything left to do.
    func testTheApprovalNoteNamesWhereToGo() {
        let note = LoginItemState.requiresApproval.note ?? ""
        XCTAssertTrue(note.contains("Login Items"), "the approval note doesn't say where: \(note)")
    }

    /// `unavailable` carries text from the caller, and the enum passes it
    /// straight back rather than tidying it. Degenerate reasons therefore reach
    /// the pane intact — which is the pane's problem to render, not something
    /// this type quietly papers over.
    func testAnUnavailableReasonComesBackVerbatim() {
        let reasons = [
            "",
            " ",
            "\n",
            "macOS refused to add aibars to login items.",
            "line one\nline two",
            String(repeating: "unavailable ", count: 500),
        ]
        for reason in reasons {
            XCTAssertEqual(
                LoginItemState.unavailable(reason).note, reason,
                "the reason was altered on its way out"
            )
        }
    }

    /// A blank reason is still not the same as having nothing to say: it is a
    /// non-nil note, so a pane that checks for nil alone gets an empty line
    /// rather than no line. Pinned because the difference is invisible on
    /// screen.
    func testABlankReasonIsStillANote() {
        XCTAssertNotNil(LoginItemState.unavailable("").note)
        XCTAssertEqual(LoginItemState.unavailable("").note, "")
    }

    // MARK: - Where the toggle sits

    func testTheToggleIsOnOnlyWhenSomethingIsRegistered() {
        XCTAssertTrue(LoginItemState.enabled.isOn)
        // Registered but unapproved counts as on: unticking it would hide the
        // one thing the user has to act on.
        XCTAssertTrue(LoginItemState.requiresApproval.isOn)
        XCTAssertFalse(LoginItemState.disabled.isOn)
        XCTAssertFalse(LoginItemState.unavailable("anything").isOn)
        XCTAssertFalse(LoginItemState.unavailable("").isOn, "an empty reason is still unavailable")
    }

    // MARK: - Equality, as the pane relies on it

    /// The pane republishes on inequality, so two unavailable states with
    /// different reasons must not compare equal — otherwise a switch that fails
    /// for a new reason keeps showing the old one.
    func testUnavailableReasonsAreNotInterchangeable() {
        XCTAssertNotEqual(
            LoginItemState.unavailable("macOS refused"),
            LoginItemState.unavailable("macOS can't find this copy")
        )
        XCTAssertEqual(
            LoginItemState.unavailable("same reason"),
            LoginItemState.unavailable("same reason")
        )
        // Whitespace is not noise here — it is a different string, and treating
        // it as equal would suppress a genuine change.
        XCTAssertNotEqual(LoginItemState.unavailable(""), LoginItemState.unavailable(" "))
    }

    func testTheFourStatesAreAllDistinct() {
        let states: [LoginItemState] = [
            .enabled, .disabled, .requiresApproval, .unavailable("a reason"),
        ]
        for (i, left) in states.enumerated() {
            for (j, right) in states.enumerated() where i != j {
                XCTAssertNotEqual(left, right, "\(left) and \(right) compare equal")
            }
            XCTAssertEqual(left, states[i], "\(left) is not equal to itself")
        }
    }

    /// Sharing `isOn` is not the same as being the same state, and the pane
    /// distinguishes them by the note.
    func testStatesSharingATogglePositionStillDiffer() {
        XCTAssertNotEqual(LoginItemState.enabled, .requiresApproval)
        XCTAssertNotEqual(LoginItemState.disabled, .unavailable("a reason"))
    }
}
