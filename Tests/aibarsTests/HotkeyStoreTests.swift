import XCTest
import AppKit
import Carbon.HIToolbox
@testable import aibarsCore

/// A scratch domain per test, so one test's writes cannot decide another's
/// starting state — and, more importantly here, so nothing in this file can
/// reach the shortcut the person running the suite actually uses. The pattern is
/// the one `AppearanceMetricsTests` established.
private func scratch(_ name: String, seed: [String: Any] = [:]) -> UserDefaults {
    let domain = "dev.aibars.test-scratch.hotkey-store.\(name)"
    // `fatalError`, not `XCTFail` and then `.standard`. Failing the case and
    // *then* handing back the shared domain still performs the write the guard
    // exists to prevent — on this file that is the user's own keyboard shortcut.
    // The branch is unreachable: `UserDefaults(suiteName:)` answers nil only for
    // an empty name, `NSGlobalDomain` or the current bundle id, and this is none
    // of the three.
    guard let store = UserDefaults(suiteName: domain) else {
        fatalError("could not open the scratch defaults domain \(domain)")
    }
    store.removePersistentDomain(forName: domain)
    for (key, value) in seed { store.set(value, forKey: key) }
    return store
}

/// Persistence for the panel's shortcut.
///
/// Two things are being held here. The first is that a fresh install has no
/// shortcut — the whole feature is opt-in, and a menu bar app that claims a
/// system-wide combination before anyone asked is the same imposition as
/// prompting for notifications at launch. The second is that the three keys live
/// outside `aibars.appearance.*`, which is the namespace `adoptCurrentLook`
/// empties once per look generation; a binding stored there would be silently
/// unbound by a build that only moved a default colour.
final class HotkeyStoreTests: XCTestCase {

    private let combo = KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [.control, .option, .command])

    // MARK: - The shipped default

    func testAFreshDomainHasNoCombo() {
        let store = scratch(#function)
        XCTAssertNil(HotkeyStore.combo(in: store))
    }

    /// `object(forKey:)` and not `bool(forKey:)`, for the reason
    /// `AppearanceSettings.readBool` gives: `bool(forKey:)` answers false for a
    /// key nobody ever wrote, which is indistinguishable from the user having
    /// switched the shortcut off.
    func testEnabledDefaultsToTrueWhenAbsent() {
        XCTAssertTrue(HotkeyStore.isEnabled(in: scratch(#function)))
    }

    // MARK: - Round trip

    func testRoundTrip() {
        let store = scratch(#function)
        HotkeyStore.setCombo(combo, in: store)
        XCTAssertEqual(HotkeyStore.combo(in: store), combo)
    }

    /// Every modifier subset that could be recorded, through the store and back.
    /// The two dialects share no bit values, so a write that stored Carbon's mask
    /// would read back as a different combination entirely.
    func testEveryRecordableModifierSetSurvivesTheRoundTrip() {
        let store = scratch(#function)
        let sets: [NSEvent.ModifierFlags] = [
            [.control], [.option], [.command],
            [.control, .option], [.control, .command], [.option, .command],
            [.command, .shift], [.control, .shift], [.option, .shift],
            [.control, .option, .command], KeyCombo.recordedFlags
        ]
        for modifiers in sets {
            let recorded = KeyCombo(keyCode: UInt16(kVK_F5), modifiers: modifiers)
            HotkeyStore.setCombo(recorded, in: store)
            XCTAssertEqual(HotkeyStore.combo(in: store), recorded, "\(recorded.glyphs) did not survive")
        }
    }

    func testEveryValidKeyCodeSurvivesTheRoundTrip() {
        let store = scratch(#function)
        for keyCode in UInt16(0)...UInt16(127) {
            let recorded = KeyCombo(keyCode: keyCode, modifiers: [.command, .option])
            HotkeyStore.setCombo(recorded, in: store)
            XCTAssertEqual(HotkeyStore.combo(in: store)?.keyCode, keyCode)
        }
    }

    // MARK: - Repair on read

    /// A half-written pair can only come from a crash between the two `set`
    /// calls or from a hand-edited plist. It is deleted rather than tolerated,
    /// because otherwise the same broken value is re-read at every launch for the
    /// life of the install.
    func testAHalfWrittenPairIsRepairedOnRead() {
        let onlyKey = scratch("\(#function).key", seed: [HotkeyStore.keyCodeKey: 0])
        XCTAssertNil(HotkeyStore.combo(in: onlyKey))
        XCTAssertNil(onlyKey.object(forKey: HotkeyStore.keyCodeKey), "the broken half was left behind")

        let onlyModifiers = scratch("\(#function).mods", seed: [HotkeyStore.modifiersKey: 1048576])
        XCTAssertNil(HotkeyStore.combo(in: onlyModifiers))
        XCTAssertNil(onlyModifiers.object(forKey: HotkeyStore.modifiersKey), "the broken half was left behind")
    }

    func testAnImpossibleKeyCodeIsRepaired() {
        for keyCode in [9000, 128, -1, Int.max] {
            let store = scratch("\(#function).\(keyCode)", seed: [
                HotkeyStore.keyCodeKey: keyCode,
                HotkeyStore.modifiersKey: 1048576
            ])
            XCTAssertNil(HotkeyStore.combo(in: store), "key code \(keyCode) was honoured")
            XCTAssertNil(store.object(forKey: HotkeyStore.keyCodeKey))
            XCTAssertNil(store.object(forKey: HotkeyStore.modifiersKey))
        }
    }

    /// A value that could never have been recorded did not come from this app.
    /// Shift alone is the case that matters: the recorder refuses it, so finding
    /// it in the store means something else wrote it.
    func testAModifierlessPairIsRepaired() {
        for modifiers in [0, Int(NSEvent.ModifierFlags.shift.rawValue), Int(NSEvent.ModifierFlags.capsLock.rawValue)] {
            let store = scratch("\(#function).\(modifiers)", seed: [
                HotkeyStore.keyCodeKey: Int(kVK_ANSI_A),
                HotkeyStore.modifiersKey: modifiers
            ])
            XCTAssertNil(HotkeyStore.combo(in: store), "modifiers \(modifiers) were honoured")
            XCTAssertNil(store.object(forKey: HotkeyStore.keyCodeKey))
            XCTAssertNil(store.object(forKey: HotkeyStore.modifiersKey))
        }
    }

    func testUnknownFlagsAreMaskedOff() {
        let noisy = Int(NSEvent.ModifierFlags.command.rawValue)
            | Int(NSEvent.ModifierFlags.capsLock.rawValue)
            | Int(NSEvent.ModifierFlags.function.rawValue)
        let store = scratch(#function, seed: [
            HotkeyStore.keyCodeKey: Int(kVK_ANSI_A),
            HotkeyStore.modifiersKey: noisy
        ])
        XCTAssertEqual(HotkeyStore.combo(in: store)?.modifiers, [.command])
    }

    /// The stored pair is deliberately *not* re-run through `KeyComboPolicy` on
    /// load. If macOS assigns Spotlight to a combination the user bound last
    /// year, the honest behaviour is to keep the binding and let the registration
    /// fail visibly — not to erase a setting because the system moved underneath
    /// it.
    func testAComboTheRecorderWouldRefuseIsStillHonoured() {
        let store = scratch(#function)
        let spotlight = KeyCombo(keyCode: UInt16(kVK_Space), modifiers: [.command])
        HotkeyStore.setCombo(spotlight, in: store)
        XCTAssertEqual(HotkeyStore.combo(in: store), spotlight)
        XCTAssertNotNil(KeyComboPolicy.rejection(for: spotlight, systemShortcuts: []),
                        "the premise is gone: the recorder would now accept this")
    }

    /// Values of the wrong type are the other thing a hand-edited plist produces,
    /// and `object(forKey:) as? Int` has to answer nil for all of them rather
    /// than coercing.
    func testValuesOfTheWrongTypeAreNotHonoured() {
        let store = scratch(#function, seed: [
            HotkeyStore.keyCodeKey: "49",
            HotkeyStore.modifiersKey: "1048576"
        ])
        XCTAssertNil(HotkeyStore.combo(in: store))
    }

    // MARK: - The off switch

    func testDisablingKeepsTheCombination() {
        let store = scratch(#function)
        HotkeyStore.setCombo(combo, in: store)
        HotkeyStore.setEnabled(false, in: store)
        XCTAssertFalse(HotkeyStore.isEnabled(in: store))
        XCTAssertEqual(HotkeyStore.combo(in: store), combo, "turning it off threw the binding away")
    }

    /// Off is stored, on is the absence of off — so re-enabling leaves no key
    /// behind for a later read to trip over.
    func testEnablingRemovesTheKeyRatherThanWritingTrue() {
        let store = scratch(#function)
        HotkeyStore.setEnabled(false, in: store)
        HotkeyStore.setEnabled(true, in: store)
        XCTAssertNil(store.object(forKey: HotkeyStore.enabledKey))
        XCTAssertTrue(HotkeyStore.isEnabled(in: store))
    }

    /// Leaving `enabled = false` behind a cleared combination means the next
    /// combination the user records arrives switched off, which reads as the
    /// recorder having failed.
    func testClearRemovesTheOffSwitchToo() {
        let store = scratch(#function)
        HotkeyStore.setCombo(combo, in: store)
        HotkeyStore.setEnabled(false, in: store)
        HotkeyStore.clear(in: store)
        XCTAssertTrue(HotkeyStore.isEnabled(in: store))
        XCTAssertNil(HotkeyStore.combo(in: store))
    }

    func testSettingANilComboClearsEverything() {
        let store = scratch(#function)
        HotkeyStore.setCombo(combo, in: store)
        HotkeyStore.setEnabled(false, in: store)
        HotkeyStore.setCombo(nil, in: store)
        for key in [HotkeyStore.keyCodeKey, HotkeyStore.modifiersKey, HotkeyStore.enabledKey] {
            XCTAssertNil(store.object(forKey: key), "\(key) survived")
        }
    }

    // MARK: - Out of the appearance wipe's reach

    /// The regression test for the reason this store exists.
    ///
    /// `AppearanceSettings.adoptCurrentLook` empties its own key domain once per
    /// look generation, and it is scoped by that domain's prefix: every case of
    /// its `Key` enum is an `aibars.appearance.*` string. A hotkey key carrying
    /// that prefix would be inside the wipe, and the only symptom the user would
    /// ever see is a keystroke that stops doing anything after an update.
    ///
    /// The prefix half. It is the property that actually holds the line, and it
    /// holds it for every case at once: no key can be inside the wipe without
    /// first being inside the namespace, which this proves none of these is.
    func testTheAppearanceWipeCannotReachThese() {
        let appearancePrefix = "aibars.appearance."
        for key in [HotkeyStore.keyCodeKey, HotkeyStore.modifiersKey, HotkeyStore.enabledKey] {
            XCTAssertFalse(
                key.hasPrefix(appearancePrefix),
                "\(key) is inside the domain adoptCurrentLook empties once a generation"
            )
            XCTAssertTrue(key.hasPrefix("aibars.hotkey."), "\(key) is not in the hotkey namespace")
        }
    }

    /// And the direct half, over the set the wipe actually iterates.
    ///
    /// This could not be written while `AppearanceSettings.Key` was `private`:
    /// `@testable` raises internal to public and leaves private alone, so the
    /// enum was not nameable here and the case above had to stand in for it. The
    /// two are not the same claim. The prefix test says these three keys are
    /// outside a namespace; this one says they are not in the collection
    /// `adoptCurrentLook` loops over — which stays true if a future appearance
    /// key is filed somewhere other than `aibars.appearance.*`, and the prefix
    /// test would not notice.
    ///
    /// The exemption list is asserted too, and it is the sharper end: a key that
    /// survives the wipe is one `adoptCurrentLook` deliberately skips, so a
    /// hotkey key appearing there would be inside the enum and outside the
    /// deletion at the same time — which reads as safe and is not.
    func testNoAppearanceKeyCollidesWithTheBinding() {
        let binding = Set([HotkeyStore.keyCodeKey, HotkeyStore.modifiersKey, HotkeyStore.enabledKey])
        let appearance = Set(AppearanceSettings.Key.allCases.map(\.rawValue))
        XCTAssertTrue(
            appearance.isDisjoint(with: binding),
            "these keys are in both stores: \(appearance.intersection(binding).sorted())"
        )
        XCTAssertFalse(appearance.isEmpty, "the enum came back empty, so the assertion measured nothing")
    }

    /// And the same thing driven rather than asserted: a domain holding both an
    /// appearance value and the three hotkey keys, put through a wipe of exactly
    /// the scope `adoptCurrentLook` documents for itself. The appearance value
    /// goes, the binding stays.
    func testAWipeOfTheAppearanceNamespaceLeavesTheBinding() {
        let store = scratch(#function, seed: ["aibars.appearance.density": "cozy"])
        HotkeyStore.setCombo(combo, in: store)
        HotkeyStore.setEnabled(false, in: store)

        for key in store.dictionaryRepresentation().keys where key.hasPrefix("aibars.appearance.") {
            store.removeObject(forKey: key)
        }

        XCTAssertNil(store.object(forKey: "aibars.appearance.density"), "the fixture's wipe did nothing")
        XCTAssertEqual(HotkeyStore.combo(in: store), combo)
        XCTAssertFalse(HotkeyStore.isEnabled(in: store))
    }

    /// Constructing the real settings object over the same scratch domain must
    /// not disturb the binding either. It exercises the whole `init` — migration,
    /// normalisation and the thirty `didSet` writes — rather than the wipe alone.
    @MainActor
    func testBuildingAppearanceSettingsOverTheSameDomainLeavesTheBinding() {
        let store = scratch(#function)
        HotkeyStore.setCombo(combo, in: store)
        _ = AppearanceSettings(store: store)
        XCTAssertEqual(HotkeyStore.combo(in: store), combo)
    }

    /// The three keys are distinct strings. Two of them colliding would make the
    /// modifiers overwrite the key code, and the pair would read back as a
    /// combination the user never recorded.
    func testTheThreeKeysAreDistinct() {
        XCTAssertEqual(Set([HotkeyStore.keyCodeKey, HotkeyStore.modifiersKey, HotkeyStore.enabledKey]).count, 3)
    }
}
