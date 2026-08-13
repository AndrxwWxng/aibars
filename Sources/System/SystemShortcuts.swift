import AppKit
import Carbon.HIToolbox

/// What macOS itself has bound, read from the same place System Settings writes
/// it.
///
/// `com.apple.symbolichotkeys` is a plain defaults domain and the app is not
/// sandboxed, so this is a read of a preference file rather than a peek into
/// another process. The alternative — `CGSGetSymbolicHotKeyValue` — is private
/// SPI, and the alternative to *that* is a hardcoded list that is wrong the
/// moment anyone changes a shortcut in System Settings.
///
/// The parse is separated from the read so it can be asserted against a fixture:
/// this is the one part of the feature whose input is a plist nobody in this
/// repository controls, so every branch of it is written to answer "not a
/// combination" rather than to trust its input.
public enum SystemShortcuts {

    /// Every enabled system shortcut, live.
    public static func enabled() -> Set<KeyCombo> {
        guard let defaults = UserDefaults(suiteName: "com.apple.symbolichotkeys"),
              let raw = defaults.dictionary(forKey: "AppleSymbolicHotKeys")
        else { return [] }
        return parse(raw)
    }

    /// The plist's shape, and every place it can be malformed.
    ///
    /// Each entry is keyed by a numeric id as a *string*, and holds `enabled`
    /// plus `value.parameters`, an array of three numbers: the ASCII character,
    /// the virtual key code, and the modifiers as Cocoa flags. The key code is
    /// 65535 for the entries that are bound to a modifier chord with no key
    /// (Dictation's double-tap, for one), which is not a combination this app can
    /// ever record and is therefore dropped rather than stored as key 65535.
    ///
    /// Nothing in here force-unwraps, subscripts past a checked count, or
    /// narrows a number without bounding it first — see `whole(_:in:)`. A user
    /// who has hand-edited this plist, or a future macOS that adds a field, gets
    /// a shorter set and not a crashed settings window.
    public static func parse(_ raw: [String: Any]) -> Set<KeyCombo> {
        var combos: Set<KeyCombo> = []
        for (_, entry) in raw {
            guard let entry = entry as? [String: Any],
                  entry["enabled"] as? Bool == true,
                  let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [Any],
                  parameters.count >= 3,
                  let keyCode = whole(parameters[1], in: 0...127),
                  let modifiers = whole(parameters[2], in: 0...Double(UInt32.max))
            else { continue }
            let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
                .intersection(KeyCombo.recordedFlags)
            guard !flags.isEmpty else { continue }
            combos.insert(KeyCombo(keyCode: UInt16(keyCode), modifiers: flags))
        }
        return combos
    }

    /// A plist number narrowed to an integer, or nil.
    ///
    /// Via `doubleValue` and an explicit range rather than `intValue`, because
    /// `-[NSNumber intValue]` on a value outside `Int32` — or on a NaN, which a
    /// hand-written plist can hold as a `real` — is unspecified, and "unspecified"
    /// in a settings window is a number nobody chose being compared against the
    /// user's keystrokes. The bound is checked before the conversion, so the
    /// conversion cannot be the thing that goes wrong.
    private static func whole(_ raw: Any, in range: ClosedRange<Double>) -> Int? {
        guard let number = raw as? NSNumber else { return nil }
        let value = number.doubleValue
        guard value.isFinite, range.contains(value) else { return nil }
        return Int(value)
    }

    /// What to call the thing that owns a combination, for the twelve the user is
    /// most likely to try. Everything else is "a system shortcut" — naming a
    /// hundred symbolic hotkey ids from memory is how a table starts being wrong,
    /// and the rejection is correct either way because it came from the live
    /// list. This only decides how well the sentence reads.
    public static func name(for combo: KeyCombo) -> String? {
        switch (Int(combo.keyCode), combo.modifiers) {
        case (kVK_Space, [.command]):                  return "Spotlight"
        case (kVK_Space, [.command, .option]):         return "the Spotlight Finder window"
        case (kVK_Space, [.control]),
             (kVK_Space, [.control, .option]):         return "switching input source"
        case (kVK_Tab, [.command]),
             (kVK_Tab, [.command, .shift]):            return "the app switcher"
        case (kVK_ANSI_Grave, [.command]):             return "switching windows in an app"
        case (kVK_ANSI_Q, [.command, .shift]):         return "logging out"
        case (kVK_ANSI_Q, [.command, .control]):       return "locking the screen"
        case (kVK_ANSI_3, [.command, .shift]),
             (kVK_ANSI_4, [.command, .shift]),
             (kVK_ANSI_5, [.command, .shift]):         return "taking a screenshot"
        case (kVK_UpArrow, [.control]):                return "Mission Control"
        case (kVK_DownArrow, [.control]):              return "App Exposé"
        default: return nil
        }
    }
}
