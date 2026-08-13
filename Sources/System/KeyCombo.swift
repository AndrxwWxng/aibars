import AppKit
import Carbon.HIToolbox

/// One recorded key combination: a virtual key code and the modifiers held with
/// it.
///
/// The modifiers are stored as a raw `UInt` and handed back as
/// `NSEvent.ModifierFlags`, because `ModifierFlags` is not `Sendable` and this
/// value crosses from a `@MainActor` recorder to a Carbon registration and into
/// a pure policy check. Only the four device-independent flags are ever kept:
/// caps lock, fn and the numeric pad are states of the keyboard rather than
/// parts of a shortcut, and a combination that compared them would never match
/// the same keystroke twice on a laptop with fn-key remapping on.
public struct KeyCombo: Equatable, Hashable, Sendable {
    /// A `kVK_*` virtual key code. Not a character: the character depends on the
    /// layout, and a shortcut recorded on QWERTY has to keep firing when the user
    /// switches to Dvorak for an afternoon.
    public let keyCode: UInt16
    private let modifierRawValue: UInt

    /// The four that make up a shortcut.
    public static let recordedFlags: NSEvent.ModifierFlags = [.shift, .control, .option, .command]
    /// At least one of these has to be present. Shift alone is a typing modifier,
    /// not a shortcut modifier — ⇧A is a capital A on every keyboard ever made.
    public static let requiredFlags: NSEvent.ModifierFlags = [.control, .option, .command]

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        // Masked at construction rather than at comparison. `Hashable` is
        // synthesised from the stored bits, so two combinations that differ only
        // in caps lock have to be the same value here or a `Set` of reserved
        // combinations would miss the one the user actually pressed.
        self.modifierRawValue = modifiers.intersection(Self.recordedFlags).rawValue
    }

    public var modifiers: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifierRawValue) }

    /// The same combination in Carbon's own modifier vocabulary, which
    /// `RegisterEventHotKey` takes and which shares no bit values with Cocoa's:
    /// ⌘ is 0x0100 here and 0x100000 there. Converted once, at the registration,
    /// rather than stored in both dialects — two representations of one
    /// combination is two things that can disagree.
    public var carbonModifiers: UInt32 {
        var mask: UInt32 = 0
        if modifiers.contains(.command) { mask |= UInt32(cmdKey) }      // 0x0100
        if modifiers.contains(.shift)   { mask |= UInt32(shiftKey) }    // 0x0200
        if modifiers.contains(.option)  { mask |= UInt32(optionKey) }   // 0x0800
        if modifiers.contains(.control) { mask |= UInt32(controlKey) }  // 0x1000
        return mask
    }

    /// What the recorder prints: modifiers in Apple's own order, then the key.
    ///
    /// ⌃⌥⇧⌘ is the order the Mac menu bar has drawn since 1984 and the order
    /// every other app's shortcut field uses. Sorting them any other way — by
    /// the order the user pressed them, say — makes one field in one settings
    /// window disagree with every menu in the system.
    public var glyphs: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option)  { text += "⌥" }
        if modifiers.contains(.shift)   { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        // The `?` is unreachable from the recorder, which rejects a key it cannot
        // name before it ever gets here — but `glyphs` is also how a combination
        // restored from the store is drawn, and a store can hold a key code that
        // the layout in force today has no legend for.
        return text + (KeyGlyphs.label(for: keyCode) ?? "?")
    }
}

/// Why a combination cannot be used, in the words the pane prints.
///
/// An enum rather than a Bool with a string beside it, for the reason
/// `LoginItemState` is one: each case has a different remedy, and a recorder
/// that says "that won't work" without saying which of the four things went
/// wrong teaches the user to try combinations at random.
public enum KeyComboRejection: Equatable, Sendable {
    case noModifier
    case commandAndCharacterAlone
    case escape
    case unsupportedKey
    /// Carries what macOS uses the combination for, when we can name it.
    case systemShortcut(String)

    public var note: String {
        switch self {
        case .noModifier:
            return "A global shortcut needs Control, Option or Command — otherwise it fires while you're typing."
        case .commandAndCharacterAlone:
            return "Command with a single letter or digit is a menu shortcut in every app. Add Control, Option or Shift."
        case .escape:
            return "Escape cancels the recorder, so it can't be recorded."
        case .unsupportedKey:
            return "aibars can't name that key, so it can't show you what you pressed."
        case .systemShortcut(let owner):
            return "macOS already uses that for \(owner)."
        }
    }
}

/// Which combinations the recorder will accept. Pure, and injectable, because
/// this is the half of the feature that can be asserted without a keyboard: the
/// system's own shortcut list comes in as a parameter rather than being read
/// from disk in here.
public enum KeyComboPolicy {

    /// Combinations rejected whatever the system's shortcut list says.
    ///
    /// Two reasons a floor is needed on top of the live list. ⌘⇥ and ⌘⇧⇥ are the
    /// application switcher, which the WindowServer owns directly and which does
    /// not appear in `com.apple.symbolichotkeys` at all — reading the plist
    /// alone would happily let the user bind it and then wonder why aibars never
    /// opens. And Spotlight, the input-source switchers, ⇧⌘Q and ⌃⌘Q *are* in
    /// the plist but can be switched off there: a user who has disabled Spotlight
    /// today can re-enable it tomorrow, and the shortcut they bound in between
    /// would stop working with no message. A Mac where ⌘Space is not Spotlight
    /// is still a Mac where ⌘Space belongs to Spotlight.
    public static let alwaysReserved: Set<KeyCombo> = [
        KeyCombo(keyCode: UInt16(kVK_Tab), modifiers: [.command]),
        KeyCombo(keyCode: UInt16(kVK_Tab), modifiers: [.command, .shift]),
        KeyCombo(keyCode: UInt16(kVK_Space), modifiers: [.command]),
        KeyCombo(keyCode: UInt16(kVK_Space), modifiers: [.command, .option]),
        KeyCombo(keyCode: UInt16(kVK_Space), modifiers: [.control]),
        KeyCombo(keyCode: UInt16(kVK_Space), modifiers: [.control, .option]),
        KeyCombo(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.command, .shift]),
        KeyCombo(keyCode: UInt16(kVK_ANSI_Q), modifiers: [.command, .control]),
        KeyCombo(keyCode: UInt16(kVK_ANSI_Grave), modifiers: [.command])
    ]

    /// Nil when the combination is usable.
    ///
    /// Ordered cheapest and most specific first, so the note the user reads names
    /// the thing they can most easily change: "add another modifier" is a better
    /// first answer than "macOS uses that", even for a combination that is both.
    public static func rejection(
        for combo: KeyCombo,
        systemShortcuts: Set<KeyCombo>
    ) -> KeyComboRejection? {
        if combo.keyCode == UInt16(kVK_Escape) { return .escape }
        guard let label = KeyGlyphs.label(for: combo.keyCode) else { return .unsupportedKey }
        if combo.modifiers.intersection(KeyCombo.requiredFlags).isEmpty { return .noModifier }
        // ⌘ and one character, with nothing else held: ⌘S, ⌘W, ⌘1. Every app on
        // the Mac has one of these in a menu, and a *global* one takes it from
        // all of them at once. Scoped to single characters on purpose — ⌘F12 and
        // ⌘↑ are not menu shortcuts and are fine.
        if combo.modifiers == [.command], label.count == 1,
           let scalar = label.unicodeScalars.first,
           CharacterSet.alphanumerics.contains(scalar) {
            return .commandAndCharacterAlone
        }
        // The live list first and the floor second, so a combination in both is
        // reported from the source that can actually change. `name(for:)` is only
        // ever how well the sentence reads: the rejection itself is decided by
        // membership, and an unnamed owner still rejects.
        if systemShortcuts.contains(combo) || alwaysReserved.contains(combo) {
            return .systemShortcut(SystemShortcuts.name(for: combo) ?? "a system shortcut")
        }
        return nil
    }
}

/// What to print for a virtual key code.
///
/// Nil means "this app can't name that key", which is a rejection rather than a
/// fallback: a recorder that shows `?` has recorded something the user cannot
/// read back, and a shortcut you cannot read is one you cannot change.
public enum KeyGlyphs {

    /// The keys that have no character to translate. Written out rather than
    /// derived, because there is nothing to derive them from — `UCKeyTranslate`
    /// answers Return with a carriage return and Space with a space, neither of
    /// which is printable in a settings field.
    ///
    /// The arrows, Return and Tab take their Apple glyphs, which is what the
    /// menu bar draws two rows above this window. The rest take words, because
    /// there is no established glyph for Page Down that anyone reads faster than
    /// the words.
    private static let named: [Int: String] = [
        kVK_Return: "↩", kVK_ANSI_KeypadEnter: "⌤", kVK_Tab: "⇥",
        kVK_Space: "Space", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦",
        kVK_Escape: "⎋", kVK_Home: "↖", kVK_End: "↘",
        kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_Help: "Help",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5",
        kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10",
        kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13", kVK_F14: "F14",
        kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18",
        kVK_F19: "F19", kVK_F20: "F20"
    ]

    public static func label(for keyCode: UInt16) -> String? {
        if let name = named[Int(keyCode)] { return name }
        return character(for: keyCode)
    }

    /// The character this key produces on the layout the user is typing on now.
    ///
    /// Not a QWERTY table. A shortcut is stored as a key *code*, so on an AZERTY
    /// keyboard the code a QWERTY table calls `Q` is the key printed `A` — and a
    /// field that tells a French user to press ⌃⌥⌘Q when the key says A is a
    /// field that has lied about the only thing it exists to say.
    ///
    /// `kUCKeyActionDisplay` with an empty modifier state is what asks for the
    /// key's own legend rather than for what it types under the modifiers being
    /// held: ⌥1 is `¡` on a US layout, and the field must say 1.
    private static func character(for keyCode: UInt16) -> String? {
        // An input source with no Unicode layout is the ordinary case for an IME
        // — a Pinyin or Kotoeri source carries no `kTISPropertyUnicodeKeyLayoutData`
        // at all. The ASCII-capable source behind it is the keyboard the user is
        // physically typing on, which is the one whose legends they can read.
        let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
        let layoutSource: TISInputSource? = {
            if let source, TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) != nil {
                return source
            }
            return TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()
        }()
        guard let layoutSource,
              let raw = TISGetInputSourceProperty(layoutSource, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        // Untyped on purpose. Apple's documentation calls both of the length
        // arguments `UniCharCount`, but the Clang importer does not surface that
        // alias under its own name — it arrives as whatever the SDK's underlying
        // integer is — so inference here is the one spelling that cannot be
        // wrong when the SDK moves.
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(-50) // paramErr
            }
            return UCKeyTranslate(
                layout,
                keyCode,
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                OptionBits(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: characters, count: Int(length))
        // A control character means the table above should have covered this key
        // and didn't. Answering nil sends it to `.unsupportedKey`, which is a
        // rejection the user can act on; a field printing U+0003 is not.
        guard !text.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            return nil
        }
        return text.uppercased()
    }
}
