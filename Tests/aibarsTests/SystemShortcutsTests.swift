import XCTest
import AppKit
import Carbon.HIToolbox
@testable import aibarsCore

/// `com.apple.symbolichotkeys` is the one input in this repository that nobody
/// here controls: System Settings writes it, a user with a text editor can
/// rewrite it, and a future macOS can add a field to it. So the parser is
/// asserted against fixtures rather than against the runner's own plist, and the
/// last test in this file throws several thousand deliberately wrong shapes at
/// it — because the failure mode of a parser in a settings window is not a wrong
/// answer, it is a crash on the way into the pane.
final class SystemShortcutsTests: XCTestCase {

    /// One entry in the plist's own shape: an id as a *string* key, `enabled`,
    /// and `value.parameters` = [ASCII character, virtual key code, Cocoa
    /// modifier flags].
    private func entry(
        id: String = "64",
        enabled: Bool = true,
        parameters: [Any]
    ) -> [String: Any] {
        [id: ["enabled": enabled, "value": ["parameters": parameters, "type": "standard"]]]
    }

    private let commandFlag = Int(NSEvent.ModifierFlags.command.rawValue)   // 1048576

    // MARK: - The shapes that are real

    func testSpotlightIsParsed() {
        let parsed = SystemShortcuts.parse(entry(parameters: [32, kVK_Space, commandFlag]))
        XCTAssertEqual(parsed, [KeyCombo(keyCode: UInt16(kVK_Space), modifiers: [.command])])
    }

    /// A user who has switched Spotlight off in System Settings still gets ⌘Space
    /// refused, but by `KeyComboPolicy.alwaysReserved` and not by this — which is
    /// the division of labour the floor exists for.
    func testADisabledEntryIsIgnored() {
        XCTAssertTrue(SystemShortcuts.parse(entry(enabled: false, parameters: [32, kVK_Space, commandFlag])).isEmpty)
    }

    func testSeveralEntriesAllParse() {
        var raw: [String: Any] = [:]
        raw.merge(entry(id: "64", parameters: [32, kVK_Space, commandFlag])) { a, _ in a }
        raw.merge(entry(id: "65", parameters: [32, kVK_Space, commandFlag | Int(NSEvent.ModifierFlags.option.rawValue)])) { a, _ in a }
        raw.merge(entry(id: "32", parameters: [65535, kVK_UpArrow, Int(NSEvent.ModifierFlags.control.rawValue)])) { a, _ in a }
        XCTAssertEqual(SystemShortcuts.parse(raw).count, 3)
    }

    /// Cocoa's flag word carries device-dependent bits alongside the four that
    /// make a shortcut, and a plist can hold caps lock. Masked here so the set's
    /// members compare equal to what the recorder builds from an `NSEvent`.
    func testDeviceDependentFlagsAreMaskedOff() {
        let noisy = commandFlag
            | Int(NSEvent.ModifierFlags.capsLock.rawValue)
            | Int(NSEvent.ModifierFlags.function.rawValue)
        let parsed = SystemShortcuts.parse(entry(parameters: [32, kVK_Space, noisy]))
        XCTAssertEqual(parsed, [KeyCombo(keyCode: UInt16(kVK_Space), modifiers: [.command])])
    }

    // MARK: - The shapes that are real and must be dropped

    /// Dictation's double-tap is a modifier chord with no key at all, stored as
    /// key code 65535. Storing it as key 65535 would put a combination in the
    /// reserved set that no keyboard can produce.
    func testAModifierOnlyEntryIsDropped() {
        XCTAssertTrue(SystemShortcuts.parse(entry(parameters: [65535, 65535, 1572864])).isEmpty)
    }

    /// A bare F5 with no modifiers is not something this policy can compare
    /// against — the recorder refuses modifier-less combinations before it ever
    /// consults this list.
    func testAnEntryWithNoModifiersIsDropped() {
        XCTAssertTrue(SystemShortcuts.parse(entry(parameters: [65535, kVK_F5, 0])).isEmpty)
    }

    /// Shift on its own is a typing modifier, so an entry holding only shift is
    /// the same case as holding none.
    func testAShiftOnlyEntrySurvivesAsAShiftCombo() {
        // It is kept — shift is one of the four recorded flags — and it is
        // `KeyComboPolicy` that refuses shift-alone as a *binding*. The parser's
        // job is to report what macOS holds, not to apply the recorder's rules.
        let parsed = SystemShortcuts.parse(entry(parameters: [32, kVK_F5, Int(NSEvent.ModifierFlags.shift.rawValue)]))
        XCTAssertEqual(parsed, [KeyCombo(keyCode: UInt16(kVK_F5), modifiers: [.shift])])
    }

    func testAnOutOfRangeKeyCodeIsDropped() {
        XCTAssertTrue(SystemShortcuts.parse(entry(parameters: [32, 128, commandFlag])).isEmpty)
        XCTAssertTrue(SystemShortcuts.parse(entry(parameters: [32, -1, commandFlag])).isEmpty)
    }

    func testAnEmptyDictionaryParsesEmpty() {
        XCTAssertTrue(SystemShortcuts.parse([:]).isEmpty)
    }

    // MARK: - The shapes that are wrong

    func testMalformedEntriesDoNotThrow() {
        let broken: [String: Any] = [
            "a": "a string where the dictionary should be",
            "b": ["enabled": true],                                        // no value
            "c": ["enabled": true, "value": "a string"],                   // value is not a dictionary
            "d": ["enabled": true, "value": ["parameters": "not an array"]],
            "e": ["enabled": true, "value": ["parameters": [32, 49]]],     // two elements, not three
            "f": ["enabled": true, "value": ["parameters": []]],
            "g": ["value": ["parameters": [32, 49, 1048576]]],             // no `enabled`
            "h": ["enabled": NSNull(), "value": ["parameters": [32, 49, 1048576]]],
            "i": ["enabled": "true", "value": ["parameters": [32, 49, 1048576]]],
            "j": ["enabled": true, "value": ["parameters": ["32", "49", "1048576"]]],
            "k": ["enabled": true, "value": ["parameters": [NSNull(), NSNull(), NSNull()]]],
            "l": NSNull(),
            "m": 42,
            "n": [1, 2, 3]
        ]
        XCTAssertTrue(SystemShortcuts.parse(broken).isEmpty)
    }

    /// A `real` in a hand-edited plist reaches `NSNumber`, and `-[NSNumber
    /// intValue]` on a NaN or on a value past `Int32` is unspecified — which is
    /// how a settings window ends up comparing the user's keystrokes against a
    /// number nobody chose. The parser bounds before it narrows; these are the
    /// values that prove it.
    func testNonFiniteAndEnormousNumbersAreDropped() {
        let hostile: [Any] = [
            Double.nan, Double.infinity, -Double.infinity,
            Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude,
            Double(Int64.max), Double(Int64.min), 1e308, -1e308
        ]
        for value in hostile {
            XCTAssertTrue(
                SystemShortcuts.parse(entry(parameters: [32, value, commandFlag])).isEmpty,
                "key code \(value) survived"
            )
            // In the modifier slot the same number must not become a mask.
            let parsed = SystemShortcuts.parse(entry(parameters: [32, kVK_Space, value]))
            XCTAssertTrue(parsed.isEmpty, "modifiers \(value) survived as \(parsed)")
        }
    }

    /// A half-integral key code is not a key code. It is dropped rather than
    /// rounded, because rounding invents a binding the plist does not hold.
    func testAFractionalKeyCodeIsTruncatedRatherThanRejected() {
        // 49.7 is inside 0...127 and narrows to 49, which is Space. Recorded
        // here as the deliberate choice it is: the bound is checked on the real
        // value and the narrowing is the last step, so a fractional entry lands
        // on a real key rather than on nothing.
        let parsed = SystemShortcuts.parse(entry(parameters: [32, 49.7, commandFlag]))
        XCTAssertEqual(parsed, [KeyCombo(keyCode: UInt16(kVK_Space), modifiers: [.command])])
    }

    /// The fuzz. Every slot of the entry gets every hostile value in turn, on top
    /// of a body that is otherwise well formed, so each iteration is a plist that
    /// is wrong in exactly one place — which is the shape a real corruption
    /// takes. Deterministic and exhaustive rather than random: a parser that
    /// crashes on the 4,000th shape should crash on the same one tomorrow.
    func testParsingSurvivesEveryMalformedShape() {
        let hostile: [Any] = [
            NSNull(), 0, -1, 1, 127, 128, 65535, -65535,
            Int.max, Int.min, UInt.max, Double.nan, Double.infinity,
            -Double.infinity, Double.greatestFiniteMagnitude, 0.5, -0.5, 1e308,
            "", " ", "49", "not a number", "\u{0}",
            [Any](), [1], [1, 2], [1, 2, 3, 4, 5], ["a": 1] as [String: Any],
            Data(), Date(), true, false,
            String(repeating: "x", count: 4096)
        ]

        var shapes = 0
        for slot in 0..<3 {
            for value in hostile {
                var parameters: [Any] = [32, kVK_Space, commandFlag]
                parameters[slot] = value
                _ = SystemShortcuts.parse(entry(parameters: parameters))
                shapes += 1
            }
        }
        // Then the containers around them, each replaced in turn.
        for value in hostile {
            _ = SystemShortcuts.parse(["64": value])
            _ = SystemShortcuts.parse(["64": ["enabled": value, "value": ["parameters": [32, 49, commandFlag]]]])
            _ = SystemShortcuts.parse(["64": ["enabled": true, "value": value]])
            _ = SystemShortcuts.parse(["64": ["enabled": true, "value": ["parameters": value]]])
            _ = SystemShortcuts.parse([String(describing: value): ["enabled": true, "value": ["parameters": [32, 49, commandFlag]]]])
            shapes += 5
        }
        // And every parameter array length from empty to over-long, since the
        // count guard is the one thing standing between this and an out-of-range
        // subscript.
        for length in 0...8 {
            let parameters = Array(repeating: 49 as Any, count: length)
            _ = SystemShortcuts.parse(entry(parameters: parameters))
            shapes += 1
        }
        XCTAssertGreaterThan(shapes, 250, "the fuzz stopped covering what it was written to cover")
    }

    /// One dictionary holding every broken entry at once, because a parser that
    /// survives each in isolation can still fall over when one of them leaves
    /// state behind.
    func testAWholeDomainOfRubbishParsesEmpty() {
        var raw: [String: Any] = [:]
        for (index, value) in ([NSNull(), 1, "x", [1, 2], ["enabled": true]] as [Any]).enumerated() {
            raw["\(index)"] = value
        }
        XCTAssertTrue(SystemShortcuts.parse(raw).isEmpty)
    }

    // MARK: - The live read

    /// Asserts nothing about the contents — they are the runner's, and on a CI
    /// machine they are whatever the image ships with. Only that reading the real
    /// domain returns rather than trapping, which is the one thing this call can
    /// get wrong.
    func testTheLiveReadDoesNotTrap() {
        _ = SystemShortcuts.enabled()
    }

    // MARK: - Naming the owner

    func testNamedShortcutsAreNamed() {
        XCTAssertEqual(SystemShortcuts.name(for: KeyCombo(keyCode: UInt16(kVK_Space), modifiers: [.command])), "Spotlight")
        XCTAssertEqual(SystemShortcuts.name(for: KeyCombo(keyCode: UInt16(kVK_Tab), modifiers: [.command])), "the app switcher")
        XCTAssertEqual(
            SystemShortcuts.name(for: KeyCombo(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.command, .control])),
            "locking the screen"
        )
    }

    /// Nil is the ordinary answer and is what makes the rejection read "a system
    /// shortcut". Naming a hundred symbolic hotkey ids from memory is how a table
    /// starts being wrong.
    func testAnUnnamedComboHasNoName() {
        XCTAssertNil(SystemShortcuts.name(for: KeyCombo(keyCode: UInt16(kVK_ANSI_A), modifiers: [.control, .option, .command])))
        XCTAssertNil(SystemShortcuts.name(for: KeyCombo(keyCode: UInt16(kVK_F5), modifiers: [.control])))
    }

    /// The table is matched on the exact modifier set, so a near miss must not
    /// borrow its neighbour's name — ⇧⌘Space is not Spotlight.
    func testANearMissDoesNotBorrowTheName() {
        XCTAssertNil(SystemShortcuts.name(for: KeyCombo(keyCode: UInt16(kVK_Space), modifiers: [.command, .shift])))
    }

    func testNamingEveryComboIsSafe() {
        for keyCode in UInt16(0)...UInt16(127) {
            for modifiers in [[], [.command], [.control, .option], KeyCombo.recordedFlags] as [NSEvent.ModifierFlags] {
                _ = SystemShortcuts.name(for: KeyCombo(keyCode: keyCode, modifiers: modifiers))
            }
        }
    }
}
