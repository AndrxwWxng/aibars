import Foundation
import AppKit

/// Where the panel's global shortcut is kept.
///
/// Its own namespace, and deliberately not `AppearanceSettings`. That class
/// clears its entire key domain once per look generation — `adoptCurrentLook`
/// removes every case of its `Key` enum except the two that record migrations —
/// which is right for a look and catastrophic for a binding: a build that only
/// moved a default bar thickness would unbind the user's shortcut, and the only
/// symptom would be a keystroke that stops doing anything. That wipe is scoped
/// to `aibars.appearance.*`, so the prefix below is not decoration; it is what
/// keeps these three keys out of its reach.
///
/// Three scalars rather than an encoded blob. A blob is a schema, and a schema
/// in UserDefaults is a thing that has to be versioned before it can be changed;
/// two integers and a bool can be read by any build this app ever ships and by
/// `defaults read` when someone is trying to work out where their shortcut went.
public enum HotkeyStore {
    public static let keyCodeKey = "aibars.hotkey.panel.keyCode"
    public static let modifiersKey = "aibars.hotkey.panel.modifiers"
    public static let enabledKey = "aibars.hotkey.panel.enabled"

    /// The stored combination, or nil when there isn't one — which is what a
    /// fresh install has, on purpose. A menu bar app that claims a system-wide
    /// key combination before anyone has asked for one is the same imposition as
    /// asking for notification permission at launch, and this app doesn't do
    /// that either.
    ///
    /// Repairs on read rather than tolerating: a half-written pair, an
    /// impossible key code or a modifier set that could never have been recorded
    /// are all deleted here, because a value nothing can honour is a value that
    /// would otherwise be re-read at every launch for the life of the install.
    ///
    /// What is deliberately *not* re-checked here is `KeyComboPolicy`. If macOS
    /// assigns Spotlight to a combination the user bound last year, the honest
    /// behaviour is to keep the binding and let the registration fail visibly,
    /// not to erase a setting because the system moved underneath it.
    public static func combo(in store: UserDefaults = .standard) -> KeyCombo? {
        let rawKey = store.object(forKey: keyCodeKey) as? Int
        let rawModifiers = store.object(forKey: modifiersKey) as? Int

        guard let rawKey, let rawModifiers else {
            // One without the other can only come from a crash between the two
            // writes, or from a hand-edited plist.
            if rawKey != nil || rawModifiers != nil { clear(in: store) }
            return nil
        }
        guard (0...127).contains(rawKey) else { clear(in: store); return nil }

        let modifiers = NSEvent.ModifierFlags(rawValue: UInt(bitPattern: rawModifiers))
            .intersection(KeyCombo.recordedFlags)
        guard !modifiers.intersection(KeyCombo.requiredFlags).isEmpty else {
            clear(in: store)
            return nil
        }
        return KeyCombo(keyCode: UInt16(rawKey), modifiers: modifiers)
    }

    /// Off is stored, on is the absence of off. A user who turns the shortcut off
    /// keeps the combination they recorded, so turning it back on returns them to
    /// their own binding rather than to an empty field.
    ///
    /// `object(forKey:)` rather than `bool(forKey:)` for the reason
    /// `AppearanceSettings.readBool` gives: `bool(forKey:)` answers false for a
    /// key that was never written, which is indistinguishable from a user having
    /// switched it off.
    public static func isEnabled(in store: UserDefaults = .standard) -> Bool {
        store.object(forKey: enabledKey) as? Bool ?? true
    }

    public static func setCombo(_ combo: KeyCombo?, in store: UserDefaults = .standard) {
        guard let combo else { return clear(in: store) }
        store.set(Int(combo.keyCode), forKey: keyCodeKey)
        store.set(Int(bitPattern: combo.modifiers.rawValue), forKey: modifiersKey)
    }

    public static func setEnabled(_ enabled: Bool, in store: UserDefaults = .standard) {
        if enabled {
            store.removeObject(forKey: enabledKey)
        } else {
            store.set(false, forKey: enabledKey)
        }
    }

    /// Clears the binding and the off switch together. Leaving `enabled = false`
    /// behind a cleared combination means the next combination the user records
    /// arrives switched off, which reads as the recorder having failed.
    public static func clear(in store: UserDefaults = .standard) {
        store.removeObject(forKey: keyCodeKey)
        store.removeObject(forKey: modifiersKey)
        store.removeObject(forKey: enabledKey)
    }
}
