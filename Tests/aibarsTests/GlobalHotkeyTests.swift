import XCTest
import AppKit
import Carbon.HIToolbox
@testable import aibarsCore

/// A scratch domain per test. Nothing in this file may read or write the
/// shortcut the person running the suite actually uses.
private func scratch(_ name: String) -> UserDefaults {
    let domain = "aibars.hotkey-registration-tests.\(name)"
    guard let store = UserDefaults(suiteName: domain) else {
        XCTFail("could not open a scratch defaults domain")
        return .standard
    }
    store.removePersistentDomain(forName: domain)
    return store
}

/// Mirrors `LoginItemTests`, including its opening argument.
///
/// `RegisterEventHotKey` is process-wide and system-visible: a test run that
/// reached it would take a key combination off the machine running CI for as
/// long as the runner lived, and — unlike a login item — there is no API to ask
/// the system whether it happened, so the damage would be invisible. `apply`
/// therefore checks `isInstallable` *before* it installs a handler or asks
/// Carbon for anything, and the whole of this file exists to prove that guard
/// ran first. The evidence is the marker text in the failure reason: the
/// no-bundle sentence can only be produced above the Carbon call.
final class GlobalHotkeyTests: XCTestCase {

    /// Substrings unique to each reason. They are the only way from outside to
    /// tell which branch ran, exactly as `LoginItemTests` uses its own pair.
    private let noBundleMarker = "app bundle"
    private let refusedMarker = "refused"

    private let combo = KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [.control, .option, .command])

    // MARK: - The test bundle is not an app

    /// Without this, every guard below is dead code — the same first test
    /// `LoginItemTests` opens with.
    func testTheTestRunnerIsNotAnAppBundle() {
        XCTAssertFalse(
            GlobalHotkey.isInstallable,
            "xctest looks like an app bundle, so nothing below is actually being prevented"
        )
    }

    /// Pins the delegation: `LoginItem` no longer carries its own copy of the
    /// predicate, and if the two ever answer differently one of the two features
    /// has lost its guard.
    func testHostProcessAndLoginItemAgree() {
        XCTAssertEqual(HostProcess.isAppBundle, LoginItem.isHostedInApp)
        XCTAssertEqual(HostProcess.isAppBundle, GlobalHotkey.isInstallable)
    }

    // MARK: - Starting

    @MainActor
    func testAFreshInstanceIsNone() {
        let hotkey = GlobalHotkey(store: scratch(#function))
        XCTAssertEqual(hotkey.state, .none)
        XCTAssertNil(hotkey.state.combo)
        XCTAssertFalse(hotkey.state.isOn)
        XCTAssertFalse(hotkey.didFailToOpen)
    }

    @MainActor
    func testStartWithNoStoredComboStaysNone() {
        let hotkey = GlobalHotkey(store: scratch(#function))
        hotkey.start()
        XCTAssertEqual(hotkey.state, .none)
    }

    /// The load-bearing test of the whole file. A seeded combination, `start()`,
    /// and a failure whose reason carries the no-bundle marker — which cannot be
    /// produced anywhere below the `isInstallable` guard, so reading it back is
    /// proof that Carbon was never asked.
    @MainActor
    func testStartWithAStoredComboIsUnavailableHere() {
        let store = scratch(#function)
        HotkeyStore.setCombo(combo, in: store)
        let hotkey = GlobalHotkey(store: store)
        hotkey.start()

        guard case .unavailable(let recorded, let reason) = hotkey.state else {
            return XCTFail("state is \(hotkey.state) — the runner was treated as a registrable app")
        }
        XCTAssertEqual(recorded, combo)
        XCTAssertTrue(reason.contains(noBundleMarker), "expected the no-bundle reason, got \(reason)")
        XCTAssertFalse(reason.contains(refusedMarker), "Carbon was consulted after all")
    }

    /// The switch still reads as on. The user asked for it, it is recorded, and
    /// unticking it would hide the note explaining what went wrong — the same
    /// rule `LoginItemState.requiresApproval` follows.
    @MainActor
    func testAnUnavailableShortcutStillReadsAsOn() {
        let store = scratch(#function)
        HotkeyStore.setCombo(combo, in: store)
        let hotkey = GlobalHotkey(store: store)
        hotkey.start()
        XCTAssertTrue(hotkey.state.isOn)
        XCTAssertNotNil(hotkey.state.note)
    }

    @MainActor
    func testStartIsIdempotent() {
        let store = scratch(#function)
        HotkeyStore.setCombo(combo, in: store)
        let hotkey = GlobalHotkey(store: store)
        hotkey.start()
        let first = hotkey.state
        for _ in 0..<5 { hotkey.start() }
        XCTAssertEqual(hotkey.state, first)
    }

    // MARK: - Recording

    /// The binding is the user's; the registration is macOS's. Recording has to
    /// survive a machine where registration cannot happen, or the setting is lost
    /// every time the system says no.
    @MainActor
    func testSetComboPersistsEvenWhenItCannotRegister() {
        let store = scratch(#function)
        let hotkey = GlobalHotkey(store: store)
        hotkey.setCombo(combo)

        XCTAssertEqual(HotkeyStore.combo(in: store), combo)
        guard case .unavailable(_, let reason) = hotkey.state else {
            return XCTFail("state is \(hotkey.state)")
        }
        XCTAssertTrue(reason.contains(noBundleMarker), "expected the no-bundle reason, got \(reason)")
    }

    @MainActor
    func testSetComboNilClears() {
        let store = scratch(#function)
        let hotkey = GlobalHotkey(store: store)
        hotkey.setCombo(combo)
        hotkey.setCombo(nil)

        XCTAssertEqual(hotkey.state, .none)
        for key in [HotkeyStore.keyCodeKey, HotkeyStore.modifiersKey, HotkeyStore.enabledKey] {
            XCTAssertNil(store.object(forKey: key), "\(key) survived")
        }
    }

    /// Off keeps the combination, so turning it back on returns the user to their
    /// own binding rather than to an empty field.
    @MainActor
    func testDisablingReportsOffAndKeepsTheCombination() {
        let store = scratch(#function)
        let hotkey = GlobalHotkey(store: store)
        hotkey.setCombo(combo)
        hotkey.setEnabled(false)

        XCTAssertEqual(hotkey.state, .off(combo))
        XCTAssertFalse(hotkey.state.isOn)
        XCTAssertNil(hotkey.state.note, "`off` is not a failure and has nothing to explain")
        XCTAssertEqual(HotkeyStore.combo(in: store), combo)

        hotkey.setEnabled(true)
        XCTAssertEqual(hotkey.state.combo, combo)
        XCTAssertTrue(hotkey.state.isOn)
    }

    // MARK: - Suspending

    /// Depth, not a Bool. The recorder suspends while it is open, and a second
    /// suspend arriving from anywhere else must not be undone by the recorder's
    /// own resume.
    @MainActor
    func testSuspendResumeIsBalanced() {
        let store = scratch(#function)
        HotkeyStore.setCombo(combo, in: store)
        let hotkey = GlobalHotkey(store: store)
        hotkey.start()
        let settled = hotkey.state

        hotkey.suspend()
        hotkey.suspend()
        hotkey.resume()
        XCTAssertEqual(hotkey.state, settled, "the first resume undid two suspends")
        hotkey.resume()
        XCTAssertEqual(hotkey.state, settled)
    }

    /// A resume with nothing outstanding must not drive the depth negative, or
    /// the next suspend would not reach the unregister.
    @MainActor
    func testResumingMoreThanSuspendingDoesNotGoNegative() {
        let store = scratch(#function)
        HotkeyStore.setCombo(combo, in: store)
        let hotkey = GlobalHotkey(store: store)
        hotkey.start()
        for _ in 0..<5 { hotkey.resume() }
        hotkey.suspend()
        hotkey.resume()
        XCTAssertEqual(hotkey.state.combo, combo)
    }

    /// The published state deliberately does not move while suspended. A field
    /// reporting "not registered" for the two seconds the recorder is open would
    /// be telling the user their shortcut had broken at the exact moment they
    /// were looking at it.
    @MainActor
    func testSuspendingDoesNotChangeWhatThePaneShows() {
        let store = scratch(#function)
        HotkeyStore.setCombo(combo, in: store)
        let hotkey = GlobalHotkey(store: store)
        hotkey.start()
        let settled = hotkey.state
        hotkey.suspend()
        XCTAssertEqual(hotkey.state, settled)
    }

    // MARK: - Stopping

    @MainActor
    func testStopIsIdempotent() {
        let store = scratch(#function)
        HotkeyStore.setCombo(combo, in: store)
        let hotkey = GlobalHotkey(store: store)
        hotkey.start()
        for _ in 0..<5 { hotkey.stop() }
        XCTAssertEqual(hotkey.state, .none)
    }

    /// Stopping releases what Carbon holds; it does not unbind the user. The next
    /// launch reads the same combination back.
    @MainActor
    func testStopLeavesTheStoredBindingAlone() {
        let store = scratch(#function)
        let hotkey = GlobalHotkey(store: store)
        hotkey.setCombo(combo)
        hotkey.stop()
        XCTAssertEqual(HotkeyStore.combo(in: store), combo)
    }

    // MARK: - Publishing

    /// `apply` drops no-op assignments because the pane redraws on every publish,
    /// and `resume` runs the whole of `apply` every time the recorder closes.
    /// Matches `LoginItemTests`' publish-count test.
    @MainActor
    func testNoRepublishOnAnUnchangedState() {
        let store = scratch(#function)
        HotkeyStore.setCombo(combo, in: store)
        let hotkey = GlobalHotkey(store: store)
        hotkey.start()   // the one legitimate transition, .none → .unavailable

        var publishes = 0
        let token = hotkey.objectWillChange.sink { _ in publishes += 1 }
        defer { token.cancel() }

        for _ in 0..<10 { hotkey.start() }
        for _ in 0..<10 { hotkey.suspend(); hotkey.resume() }

        XCTAssertEqual(publishes, 0, "the pane would redraw \(publishes) times for no reason")
    }

    // MARK: - What each state tells the user

    /// A note is for the one state the user can act on. The other three inventing
    /// one would put a red line under a control that is working.
    func testStateNotesOnlyWhereThereIsSomethingToSay() {
        XCTAssertNil(GlobalHotkeyState.none.note)
        XCTAssertNil(GlobalHotkeyState.off(combo).note)
        XCTAssertNil(GlobalHotkeyState.registered(combo).note)

        let note = GlobalHotkeyState.unavailable(combo, "macOS refused").note
        XCTAssertEqual(note, "macOS refused")
        XCTAssertFalse(note?.isEmpty ?? true)
    }

    func testIsOnMatchesTheSwitchPosition() {
        XCTAssertFalse(GlobalHotkeyState.none.isOn)
        XCTAssertFalse(GlobalHotkeyState.off(combo).isOn)
        XCTAssertTrue(GlobalHotkeyState.registered(combo).isOn)
        // On for the reason `LoginItemState.requiresApproval` is: unticking it
        // would hide the note explaining what went wrong.
        XCTAssertTrue(GlobalHotkeyState.unavailable(combo, "anything").isOn)
        XCTAssertTrue(GlobalHotkeyState.unavailable(combo, "").isOn, "an empty reason is still unavailable")
    }

    /// Three of the four states carry the combination, because the field keeps
    /// printing it while the shortcut is off or broken. Losing it there would
    /// empty the recorder the moment anything went wrong.
    func testEveryStateThatHasACombinationHandsItBack() {
        XCTAssertNil(GlobalHotkeyState.none.combo)
        XCTAssertEqual(GlobalHotkeyState.off(combo).combo, combo)
        XCTAssertEqual(GlobalHotkeyState.registered(combo).combo, combo)
        XCTAssertEqual(GlobalHotkeyState.unavailable(combo, "why").combo, combo)
    }

    /// The pane republishes on inequality, so two failures with different reasons
    /// must not compare equal — otherwise a new fault keeps showing the old
    /// sentence.
    func testUnavailableReasonsAreNotInterchangeable() {
        XCTAssertNotEqual(
            GlobalHotkeyState.unavailable(combo, "macOS refused that combination"),
            GlobalHotkeyState.unavailable(combo, "aibars already holds that combination")
        )
        XCTAssertEqual(
            GlobalHotkeyState.unavailable(combo, "same reason"),
            GlobalHotkeyState.unavailable(combo, "same reason")
        )
        XCTAssertNotEqual(GlobalHotkeyState.unavailable(combo, ""), GlobalHotkeyState.unavailable(combo, " "))
    }

    /// Same reason, different combination, is also a different state — the field
    /// beside the note prints the combination.
    func testTheCombinationIsPartOfTheState() {
        let other = KeyCombo(keyCode: UInt16(kVK_F5), modifiers: [.control, .option, .command])
        XCTAssertNotEqual(GlobalHotkeyState.unavailable(combo, "why"), .unavailable(other, "why"))
        XCTAssertNotEqual(GlobalHotkeyState.registered(combo), .registered(other))
        XCTAssertNotEqual(GlobalHotkeyState.off(combo), .registered(combo))
    }

    func testTheFourStatesAreAllDistinct() {
        let states: [GlobalHotkeyState] = [.none, .off(combo), .registered(combo), .unavailable(combo, "a reason")]
        for (i, left) in states.enumerated() {
            for (j, right) in states.enumerated() where i != j {
                XCTAssertNotEqual(left, right, "\(left) and \(right) compare equal")
            }
            XCTAssertEqual(left, states[i], "\(left) is not equal to itself")
        }
    }

    // MARK: - The shared instance

    /// The app delegate reads the singleton at launch, and merely *reaching* for
    /// it must not be what registers anything — `init` stores a `UserDefaults`
    /// and does nothing else, so the state is `.none` until somebody calls
    /// `start()`.
    ///
    /// Deliberately not calling `start()` on it. The singleton is backed by
    /// `UserDefaults.standard`, and `HotkeyStore.combo` repairs what it reads —
    /// so starting the shared instance from a test would reach into the real
    /// defaults domain of whoever is running the suite. The guard that matters is
    /// already proved above, on an instance with a scratch domain.
    @MainActor
    func testTheSharedInstanceRegistersNothingByExisting() {
        XCTAssertEqual(GlobalHotkey.shared.state, .none)
        XCTAssertFalse(GlobalHotkey.shared.state.isOn)
    }
}
