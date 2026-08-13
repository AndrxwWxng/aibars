import XCTest
import AppKit
import Carbon.HIToolbox
@testable import aibarsCore

/// The half of the global shortcut that can be asserted without a keyboard.
///
/// `KeyComboPolicy` takes the system's shortcut list as a parameter rather than
/// reading it from disk, so everything here is a pure function of its inputs —
/// with one exception that is called out wherever it appears: `KeyGlyphs.label`
/// asks the *current keyboard layout* what a printing key is called, and it has
/// to, because a field that tells an AZERTY user to press ⌃⌥⌘Q when the key
/// under their finger says A has lied about the only thing it exists to say. The
/// assertions that depend on that answer are skipped off a US layout rather than
/// pinning the runner's keyboard.
final class KeyComboTests: XCTestCase {

    // MARK: - Fixtures

    private let a = UInt16(kVK_ANSI_A)
    private let one = UInt16(kVK_ANSI_1)
    private let space = UInt16(kVK_Space)
    private let f5 = UInt16(kVK_F5)
    private let f12 = UInt16(kVK_F12)

    /// Layout-independent keys only. Everything in `KeyGlyphs.named` answers the
    /// same on every keyboard in the world, which is what makes an assertion
    /// about it an assertion about this code.
    private func combo(_ keyCode: UInt16, _ modifiers: NSEvent.ModifierFlags) -> KeyCombo {
        KeyCombo(keyCode: keyCode, modifiers: modifiers)
    }

    /// True when the current input source is one of the two layouts whose
    /// legends this file may assume. Anything else — AZERTY, Dvorak, a Pinyin
    /// IME — has different and equally correct answers.
    private var isOnAnASCIILayout: Bool {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
        else { return false }
        let id = Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        return id == "com.apple.keylayout.ABC" || id == "com.apple.keylayout.US"
    }

    // MARK: - Carbon's dialect

    /// Cocoa's ⌘ is 0x100000 and Carbon's is 0x100. They share no bit values, so
    /// a conversion that silently passed the wrong dialect through would register
    /// a combination nobody pressed — and would do it without an error, because
    /// both numbers are valid modifier masks. Pinned as literals for that reason.
    func testCarbonModifiersUseCarbonsBitValues() {
        XCTAssertEqual(combo(a, [.command]).carbonModifiers, 0x0100)
        XCTAssertEqual(combo(a, [.shift]).carbonModifiers, 0x0200)
        XCTAssertEqual(combo(a, [.option]).carbonModifiers, 0x0800)
        XCTAssertEqual(combo(a, [.control]).carbonModifiers, 0x1000)
        XCTAssertEqual(combo(a, [.control, .option, .command]).carbonModifiers, 0x1900)
        XCTAssertEqual(combo(a, []).carbonModifiers, 0)
    }

    /// The Cocoa value must not leak through unconverted, which is the one way
    /// this can be wrong and still look plausible.
    func testCarbonModifiersAreNotTheCocoaOnes() {
        let cocoa = UInt32(NSEvent.ModifierFlags.command.rawValue)
        XCTAssertNotEqual(combo(a, [.command]).carbonModifiers, cocoa)
    }

    // MARK: - What the field prints

    /// ⌃⌥⇧⌘ is the order the Mac menu bar has drawn since 1984. Recording order
    /// must not survive into the string, or one field in one settings window
    /// disagrees with every menu in the system.
    func testGlyphsUseAppleOrder() {
        let orders: [NSEvent.ModifierFlags] = [
            [.command, .control, .shift, .option],
            [.shift, .command, .option, .control],
            [.option, .shift, .control, .command],
            [.control, .option, .shift, .command]
        ]
        for modifiers in orders {
            XCTAssertEqual(combo(space, modifiers).glyphs, "⌃⌥⇧⌘Space")
        }
    }

    func testGlyphsPrintOnlyTheModifiersHeld() {
        XCTAssertEqual(combo(space, [.command]).glyphs, "⌘Space")
        XCTAssertEqual(combo(f12, [.control, .option]).glyphs, "⌃⌥F12")
        XCTAssertEqual(combo(UInt16(kVK_LeftArrow), [.command, .shift]).glyphs, "⇧⌘←")
    }

    /// Caps lock, fn and the numeric pad are states of the keyboard rather than
    /// parts of a shortcut. A combination that compared them would never match
    /// the same keystroke twice on a laptop with fn-key remapping on — and
    /// because `Hashable` is synthesised from the stored bits, it would also miss
    /// its own entry in `alwaysReserved`.
    func testCapsLockAndFunctionAreNotPartOfACombo() {
        let bare = combo(a, [.command])
        let noisy = combo(a, [.command, .capsLock, .function, .numericPad])
        XCTAssertEqual(bare, noisy)
        XCTAssertEqual(bare.hashValue, noisy.hashValue)
        XCTAssertEqual(noisy.modifiers, [.command])
        XCTAssertEqual(Set([bare, noisy]).count, 1, "a Set would hold both and the floor would miss one")
    }

    func testTheKeyCodeIsPartOfTheIdentity() {
        XCTAssertNotEqual(combo(a, [.command]), combo(one, [.command]))
    }

    // MARK: - The policy

    /// Shift alone is a typing modifier: ⇧A is a capital A on every keyboard ever
    /// made, and a global shortcut on it fires mid-sentence.
    func testShiftAloneIsRejected() {
        XCTAssertEqual(KeyComboPolicy.rejection(for: combo(space, [.shift]), systemShortcuts: []), .noModifier)
        XCTAssertEqual(KeyComboPolicy.rejection(for: combo(space, []), systemShortcuts: []), .noModifier)
        XCTAssertEqual(KeyComboPolicy.rejection(for: combo(f5, [.shift]), systemShortcuts: []), .noModifier)
    }

    /// ⌘ and one character is a menu shortcut in every app on the Mac, and a
    /// *global* one takes it from all of them at once.
    func testCommandPlusLetterOrDigitIsRejected() throws {
        try XCTSkipUnless(
            isOnAnASCIILayout,
            "the legend on these keys is the layout's answer, not this code's"
        )
        XCTAssertEqual(
            KeyComboPolicy.rejection(for: combo(a, [.command]), systemShortcuts: []),
            .commandAndCharacterAlone
        )
        XCTAssertEqual(
            KeyComboPolicy.rejection(for: combo(one, [.command]), systemShortcuts: []),
            .commandAndCharacterAlone
        )
    }

    /// The scoping proof for the rule above, and layout-independent because every
    /// key here takes its name from the table rather than from the keyboard.
    /// ⌘F12 and ⌘↑ are not menu shortcuts and must stay recordable, or the rule
    /// has quietly become "⌘ is banned".
    func testCommandPlusNonCharacterIsAccepted() {
        for keyCode in [f12, UInt16(kVK_UpArrow), UInt16(kVK_Return), UInt16(kVK_PageDown)] {
            XCTAssertNil(
                KeyComboPolicy.rejection(for: combo(keyCode, [.command]), systemShortcuts: []),
                "⌘ plus \(KeyGlyphs.label(for: keyCode) ?? "?") was refused"
            )
        }
    }

    /// A recorder with no way out traps the user in a field, so Escape cancels —
    /// which is exactly why it can never itself be recorded, with or without
    /// modifiers.
    func testEscapeIsNeverRecordable() {
        let escape = UInt16(kVK_Escape)
        XCTAssertEqual(KeyComboPolicy.rejection(for: combo(escape, []), systemShortcuts: []), .escape)
        XCTAssertEqual(
            KeyComboPolicy.rejection(for: combo(escape, [.control, .option, .command]), systemShortcuts: []),
            .escape
        )
    }

    /// The floor exists because the live plist is not the whole truth: ⌘⇥ is the
    /// WindowServer's and appears in `com.apple.symbolichotkeys` nowhere at all,
    /// and Spotlight's entry can be switched off by a user who will switch it
    /// back on next week. So every member has to reject against an *empty*
    /// system list.
    func testTheFloorIsRejectedWithAnEmptySystemList() {
        for reserved in KeyComboPolicy.alwaysReserved {
            let rejection = KeyComboPolicy.rejection(for: reserved, systemShortcuts: [])
            XCTAssertNotNil(rejection, "\(reserved.glyphs) is bindable with the plist empty")
            // Two of the nine (Q and `) take their legend from the layout. When
            // the layout can name the key the answer is `.systemShortcut`; when
            // it cannot, `.unsupportedKey` is the correct and equally firm
            // refusal. Asserting the pair keeps this honest on a Dvorak runner
            // without weakening it on a US one.
            if KeyGlyphs.label(for: reserved.keyCode) != nil {
                guard case .systemShortcut = rejection else {
                    return XCTFail("\(reserved.glyphs) was refused as \(String(describing: rejection))")
                }
            } else {
                XCTAssertEqual(rejection, .unsupportedKey, "\(reserved.keyCode) has no legend here")
            }
        }
    }

    /// The nine are not an accident of the set literal — the app switcher and
    /// Spotlight are the two the user is most likely to reach for first.
    func testTheFloorHoldsTheCombinationsTheUserWillTryFirst() {
        XCTAssertTrue(KeyComboPolicy.alwaysReserved.contains(combo(UInt16(kVK_Tab), [.command])))
        XCTAssertTrue(KeyComboPolicy.alwaysReserved.contains(combo(space, [.command])))
        XCTAssertEqual(KeyComboPolicy.alwaysReserved.count, 9)
    }

    func testAReservedComboIsNamedWhenWeCanNameIt() {
        let rejection = KeyComboPolicy.rejection(for: combo(space, [.command]), systemShortcuts: [])
        XCTAssertEqual(rejection, .systemShortcut("Spotlight"))
        XCTAssertTrue(rejection?.note.contains("Spotlight") ?? false)
    }

    /// A combination the plist reports and the table cannot name still rejects.
    /// The membership decides the refusal; `name(for:)` only decides how well the
    /// sentence reads.
    func testALiveSystemShortcutIsRejected() {
        let bound = combo(f5, [.control, .option, .command])
        XCTAssertNil(KeyComboPolicy.rejection(for: bound, systemShortcuts: []))
        XCTAssertEqual(
            KeyComboPolicy.rejection(for: bound, systemShortcuts: [bound]),
            .systemShortcut("a system shortcut")
        )
    }

    func testAnOrdinaryComboIsAccepted() {
        // ⇧⌘Space and not ⌘Space: the floor holds the second and not the first,
        // which is the difference between a reserved combination and one that
        // merely resembles it.
        XCTAssertNil(KeyComboPolicy.rejection(for: combo(space, [.command, .shift]), systemShortcuts: []))
        XCTAssertNil(KeyComboPolicy.rejection(for: combo(f5, [.control, .option, .command]), systemShortcuts: []))
        XCTAssertNil(KeyComboPolicy.rejection(for: combo(f12, [.control, .shift]), systemShortcuts: []))
    }

    func testAnOrdinaryLetterComboIsAccepted() throws {
        try XCTSkipUnless(isOnAnASCIILayout, "the legend on this key is the layout's answer")
        XCTAssertNil(KeyComboPolicy.rejection(for: combo(a, [.control, .option, .command]), systemShortcuts: []))
    }

    /// A key this app cannot name is a key the user cannot read back, and a
    /// shortcut you cannot read is one you cannot change.
    func testAKeyWithNoLegendIsRefused() {
        XCTAssertEqual(
            KeyComboPolicy.rejection(for: combo(200, [.control, .option, .command]), systemShortcuts: []),
            .unsupportedKey
        )
    }

    /// Mirrors `LoginItemTests.testOnlySettledStatesHaveNoNote`: a rejection that
    /// says nothing teaches the user to try combinations at random.
    func testEveryRejectionHasSomethingToSay() {
        let all: [KeyComboRejection] = [
            .noModifier, .commandAndCharacterAlone, .escape, .unsupportedKey,
            .systemShortcut("Spotlight"), .systemShortcut("a system shortcut")
        ]
        for rejection in all {
            XCTAssertFalse(rejection.note.isEmpty, "\(rejection) has nothing to say")
        }
    }

    /// The pane prints the owner into the sentence, so two owners must not
    /// compare equal — a new conflict showing the old app's name is worse than
    /// no name at all.
    func testSystemShortcutOwnersAreNotInterchangeable() {
        XCTAssertNotEqual(KeyComboRejection.systemShortcut("Spotlight"), .systemShortcut("the app switcher"))
        XCTAssertEqual(KeyComboRejection.systemShortcut("Spotlight"), .systemShortcut("Spotlight"))
    }

    // MARK: - KeyGlyphs

    /// Layout-independent, so unconditional. These are the keys `UCKeyTranslate`
    /// answers with a control character or a space, which is why they come from a
    /// table at all.
    func testNonPrintingKeysComeFromTheTable() {
        XCTAssertEqual(KeyGlyphs.label(for: UInt16(kVK_Space)), "Space")
        XCTAssertEqual(KeyGlyphs.label(for: UInt16(kVK_Return)), "↩")
        XCTAssertEqual(KeyGlyphs.label(for: UInt16(kVK_Tab)), "⇥")
        XCTAssertEqual(KeyGlyphs.label(for: UInt16(kVK_Delete)), "⌫")
        XCTAssertEqual(KeyGlyphs.label(for: UInt16(kVK_Escape)), "⎋")
        XCTAssertEqual(KeyGlyphs.label(for: UInt16(kVK_F12)), "F12")
        XCTAssertEqual(KeyGlyphs.label(for: UInt16(kVK_LeftArrow)), "←")
        XCTAssertEqual(KeyGlyphs.label(for: UInt16(kVK_DownArrow)), "↓")
    }

    /// No entry in the table may be blank: the field prints it, and an empty
    /// legend is a recorded shortcut the user cannot see.
    func testNoTableEntryIsBlank() {
        for keyCode in UInt16(0)...UInt16(127) {
            guard let label = KeyGlyphs.label(for: keyCode) else { continue }
            XCTAssertFalse(label.isEmpty, "key \(keyCode) has an empty legend")
        }
    }

    func testALetterKeyPrintsItsOwnLegend() throws {
        try XCTSkipUnless(
            isOnAnASCIILayout,
            "on any other layout the correct answer is not \"A\", and asserting it would pin the runner's keyboard"
        )
        XCTAssertEqual(KeyGlyphs.label(for: UInt16(kVK_ANSI_A)), "A")
        XCTAssertEqual(KeyGlyphs.label(for: UInt16(kVK_ANSI_1)), "1")
    }

    /// Virtual key codes run 0…127, so 200 came from a corrupted store rather
    /// than from a keyboard. Answering nil is what routes it to
    /// `.unsupportedKey` instead of printing a replacement character.
    func testAnImpossibleKeyCodeHasNoName() {
        XCTAssertNil(KeyGlyphs.label(for: 200))
        XCTAssertNil(KeyGlyphs.label(for: 255))
    }

    /// Every key code a stored combination could hold, asked for its name. None
    /// of them may trap, whatever the layout is.
    func testNamingEveryKeyCodeIsSafe() {
        for keyCode in UInt16(0)...UInt16(255) {
            _ = KeyGlyphs.label(for: keyCode)
            _ = KeyCombo(keyCode: keyCode, modifiers: [.command]).glyphs
        }
    }
}
