import AppKit

/// One keystroke, as something the panel can act on.
///
/// `nil` from `from(...)` is the important case and it means "not ours": the
/// monitor hands the event straight back to AppKit, which is what keeps ⌘Q
/// working in an application with no Dock icon and no window to quit from.
public enum PanelKeyCommand: Equatable {
    case character(Character)
    case backspace
    case moveDown, moveUp, moveToFirst, moveToLast
    case activate
    case cancel
    /// 1...9. Selects; never activates.
    case jump(Int)
    /// ⌘F.
    case beginFiltering

    /// nil means "not ours" — the monitor then returns the event untouched.
    ///
    /// **The ⌘ rule is the one line in this change with a catastrophic failure
    /// mode.** `.keyboardShortcut("q")`, `("r")` and `(",")` are AppKit key
    /// equivalents, dispatched inside `NSApplication.sendEvent(_:)` →
    /// `NSWindow.performKeyEquivalent(with:)`, which runs *after* every local event
    /// monitor. So a monitor that consumed ⌘Q would leave an app with no Dock icon
    /// and no window unquittable except by Force Quit. Everything carrying ⌘ is
    /// therefore passed through except the two chords nothing else in the app
    /// claims: ⌘1–⌘9 and ⌘F.
    ///
    /// One consequence worth stating: those three shortcuts only fire while the
    /// panel's window is key, and `PanelKeyMonitor` is what makes it key. If they
    /// were dead before this change, this change is also what fixes them.
    ///
    /// Virtual key codes are written as literals with the `kVK_` name beside them,
    /// the way `Tokens.Strip.figureDigits` writes its own: importing Carbon for
    /// fifteen integers would put a framework in this file for the length of its
    /// constants.
    public static func from(
        keyCode: UInt16,
        characters: String?,
        charactersIgnoringModifiers: String?,
        modifiers: NSEvent.ModifierFlags
    ) -> PanelKeyCommand? {
        // Caps lock is not a chord and neither are the device-dependent
        // left/right bits, so both come off before anything is compared. A user
        // typing with caps lock on is still typing.
        let chord = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .subtracting(.capsLock)

        if chord.contains(.command) {
            // Exactly ⌘, not ⌘ plus something: ⌥⌘F and ⌘⇧1 belong to whoever else
            // wants them, and a panel that swallowed a chord it does not draw for
            // would be doing the same damage as swallowing ⌘Q, one shortcut at a
            // time.
            guard chord == [.command] else { return nil }
            if let digit = charactersIgnoringModifiers.flatMap(Int.init), (1...9).contains(digit) {
                return .jump(digit)
            }
            if charactersIgnoringModifiers?.lowercased() == "f" { return .beginFiltering }
            return nil
        }

        // Before the `.function` guard below, deliberately: every arrow, Home,
        // End, Page Up and Page Down arrives carrying `.function` and
        // `.numericPad`, so a guard that ran first would take the whole of the
        // navigation with it.
        //
        // Home/End/PageUp/PageDown all land on the two ends on purpose. A panel of
        // 38–66pt rows capped at `maximumListHeight` has no meaningful "page", and
        // the only page motion worth having in a list this short is to an end of
        // it.
        switch keyCode {
        case 125: return .moveDown          // kVK_DownArrow
        case 126: return .moveUp            // kVK_UpArrow
        case 115, 116: return .moveToFirst  // kVK_Home, kVK_PageUp
        case 119, 121: return .moveToLast   // kVK_End, kVK_PageDown
        case 36, 76: return .activate       // kVK_Return, kVK_ANSI_KeypadEnter
        case 53: return .cancel             // kVK_Escape
        case 51: return .backspace          // kVK_Delete
        default: break
        }

        guard !chord.contains(.control), !chord.contains(.function) else { return nil }
        // One grapheme, and nothing a font would not draw. `characters` rather
        // than `charactersIgnoringModifiers`, so ⌥e-then-e types the é the user
        // meant rather than the bare e underneath it.
        guard let characters, characters.count == 1, let character = characters.first,
              !character.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
                      || CharacterSet.illegalCharacters.contains($0)
              })
        else { return nil }
        return .character(character)
    }
}

/// Everything the keyboard has done to the panel, in one value.
///
/// One struct rather than three `@State` flags, so the reducer can be handed the
/// whole thing `inout` and checked without a view — which is what makes the
/// twelve cases in `PanelKeyboardTests` possible at all.
public struct PanelKeyboardState: Equatable {
    public var query: String
    public var isFiltering: Bool
    /// A provider id — `"claude#2"` — never an index.
    ///
    /// **An id, and the reason is the refresh loop.** The default sort is
    /// `.urgency`, `AppState.refreshAll` runs every 60s while the panel is open,
    /// and `rankedProviders` re-sorts on every reading. An index selection would
    /// move to a different service between refreshes with the user's hands off the
    /// keyboard, and Return would then open the wrong dashboard.
    public var selection: String?

    public init(query: String, isFiltering: Bool, selection: String?) {
        self.query = query
        self.isFiltering = isFiltering
        self.selection = selection
    }

    public static let resting = PanelKeyboardState(query: "", isFiltering: false, selection: nil)

    public static func filtering(_ query: String, selection: String? = nil) -> PanelKeyboardState {
        PanelKeyboardState(query: query, isFiltering: true, selection: selection)
    }
}

/// What the panel has to do about a command, beyond the state change.
public enum PanelKeyEffect: Equatable {
    /// Consumed. The monitor returns nil and AppKit never sees the event.
    case handled
    /// Not ours after all — the monitor returns the event unchanged.
    case ignored
    case activate(String)
    case close
}

/// The translation table and the reducer. Pure, both halves.
public enum PanelKeyboard {

    /// The longest query the panel will hold.
    ///
    /// A width contract rather than a taste: the query is drawn on the header's
    /// one line and quoted back in the no-match block, and both are `lineLimit(1)`
    /// — but a four-thousand-character paste has no business reaching a layout
    /// pass at all. ⌘V is not claimed, so that paste cannot happen today; the cap
    /// is what stops it happening if it ever is.
    public static let queryLimit = 32

    // MARK: - The reducer

    /// The whole of what a key does, as a function of the command, the state and
    /// the rows currently on screen.
    ///
    /// **Selection clamps, it does not wrap.** Wrapping from the last row to the
    /// first moves the plate the length of the window in answer to a key that
    /// means "one more"; in a list of nine you then have to look to find out where
    /// it went.
    ///
    /// **`.jump(n)` selects and scrolls; it does not activate.** Activating is
    /// Return, everywhere, once. A ⌘-digit that opened a browser tab would be the
    /// only key in the app that acts without a second confirming keystroke, and a
    /// mis-hit ⌘3 for ⌘Q is not recoverable.
    ///
    /// **An out-of-range jump and a Return with nothing selected are consumed,
    /// not passed on.** An unconsumed key equivalent reaching AppKit with no
    /// handler is a system beep, and a panel that beeps at you for pressing ⌘5 is
    /// worse than one that ignores it.
    @discardableResult
    public static func reduce(
        _ command: PanelKeyCommand,
        into state: inout PanelKeyboardState,
        rows: [String]
    ) -> PanelKeyEffect {
        switch command {
        case .character(let character):
            // A query cannot begin with a space, and Space is worth leaving
            // available on a resting panel.
            if character == " ", state.query.isEmpty { return .ignored }
            guard state.query.count < queryLimit else { return .handled }
            state.isFiltering = true
            state.query.append(character)
            // The rows are about to change under it; `reconcile` puts the
            // selection back on whatever the new top result is.
            state.selection = nil
            return .handled

        case .backspace:
            if !state.query.isEmpty {
                state.query.removeLast()
                state.selection = nil
                return .handled
            }
            guard state.isFiltering else { return .ignored }
            state.isFiltering = false
            return .handled

        case .moveDown:
            guard !rows.isEmpty else { return .handled }
            guard let index = state.selection.flatMap(rows.firstIndex(of:)) else {
                state.selection = rows.first
                return .handled
            }
            state.selection = rows[min(index + 1, rows.count - 1)]
            return .handled

        case .moveUp:
            guard !rows.isEmpty else { return .handled }
            guard let index = state.selection.flatMap(rows.firstIndex(of:)) else {
                state.selection = rows.last
                return .handled
            }
            state.selection = rows[max(index - 1, 0)]
            return .handled

        case .moveToFirst:
            guard !rows.isEmpty else { return .handled }
            state.selection = rows.first
            return .handled

        case .moveToLast:
            guard !rows.isEmpty else { return .handled }
            state.selection = rows.last
            return .handled

        case .jump(let n):
            guard (1...rows.count).contains(n) else { return .handled }
            state.selection = rows[n - 1]
            return .handled

        case .activate:
            guard let selection = state.selection else { return .handled }
            return .activate(selection)

        case .cancel:
            guard state.isFiltering || !state.query.isEmpty || state.selection != nil else {
                return .close
            }
            state = .resting
            return .handled

        case .beginFiltering:
            state.isFiltering = true
            return .handled
        }
    }

    /// Drops a selection whose row has gone, and puts one on the top result the
    /// moment there is a query to have a top result of.
    ///
    /// Both halves belong together because both are answers to the same event:
    /// the drawn rows just changed underneath the selection. It is called from the
    /// panel's own `onChange(of: drawn ids)`, so it runs after a keystroke, after
    /// a refresh, and after a service is hidden from a row's context menu.
    ///
    /// Auto-selection happens **only while filtering**. A resting panel has no
    /// selection until an arrow key asks for one, because a plate sitting on row
    /// one every time you open the panel is a selection nobody made.
    public static func reconcile(_ state: inout PanelKeyboardState, rows: [String]) {
        if let selection = state.selection, !rows.contains(selection) {
            state.selection = nil
        }
        if state.isFiltering, !state.query.isEmpty, state.selection == nil, !rows.isEmpty {
            state.selection = rows[0]
        }
    }
}
