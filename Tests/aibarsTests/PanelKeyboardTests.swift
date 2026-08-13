import XCTest
import AppKit
@testable import aibarsCore

/// The translation table and the reducer, both pure.
///
/// One of these — `testCommandEventsThePanelDoesNotOwnArePassedThrough` — is the
/// single highest-value assertion in this change. The monitor sees every keyDown
/// in the process, and a ⌘ pass-through rule that is wrong by one branch makes an
/// app with no Dock icon and no window unquittable except by Force Quit.
final class PanelKeyboardTests: XCTestCase {

    // MARK: - Translation

    private func command(
        _ keyCode: UInt16,
        _ characters: String? = nil,
        ignoringModifiers: String? = nil,
        _ modifiers: NSEvent.ModifierFlags = []
    ) -> PanelKeyCommand? {
        PanelKeyCommand.from(
            keyCode: keyCode,
            characters: characters,
            charactersIgnoringModifiers: ignoringModifiers ?? characters,
            modifiers: modifiers
        )
    }

    func testTheTranslationTable() {
        // The navigation keys, which all arrive carrying `.function` and
        // `.numericPad` — so this is also the case that pins the key-code switch
        // running *before* the function guard.
        let navigation: NSEvent.ModifierFlags = [.function, .numericPad]
        XCTAssertEqual(command(125, "\u{F701}", navigation), .moveDown)   // kVK_DownArrow
        XCTAssertEqual(command(126, "\u{F700}", navigation), .moveUp)     // kVK_UpArrow
        XCTAssertEqual(command(115, "\u{F729}", navigation), .moveToFirst) // kVK_Home
        XCTAssertEqual(command(116, "\u{F72C}", navigation), .moveToFirst) // kVK_PageUp
        XCTAssertEqual(command(119, "\u{F72B}", navigation), .moveToLast)  // kVK_End
        XCTAssertEqual(command(121, "\u{F72D}", navigation), .moveToLast)  // kVK_PageDown

        XCTAssertEqual(command(36, "\r"), .activate)     // kVK_Return
        XCTAssertEqual(command(76, "\u{3}"), .activate)  // kVK_ANSI_KeypadEnter
        XCTAssertEqual(command(53, "\u{1B}"), .cancel)   // kVK_Escape
        XCTAssertEqual(command(51, "\u{8}"), .backspace) // kVK_Delete

        XCTAssertEqual(command(18, "1", .command), .jump(1))
        XCTAssertEqual(command(25, "9", .command), .jump(9))
        XCTAssertEqual(command(3, "f", .command), .beginFiltering)
        XCTAssertEqual(command(3, "F", ignoringModifiers: "F", .command), .beginFiltering)

        XCTAssertEqual(command(8, "c"), .character("c"))
        XCTAssertEqual(command(49, " "), .character(" "))
        // Shift is text, not a chord: a capital is a character.
        XCTAssertEqual(command(8, "C", ignoringModifiers: "c", .shift), .character("C"))

        // Control and fn are nobody's text.
        XCTAssertNil(command(8, "\u{3}", ignoringModifiers: "c", .control))
        XCTAssertNil(command(8, "c", .function))
        // Nor is a chord of two digits, an empty string, or a control scalar that
        // reached the character branch.
        XCTAssertNil(command(8, ""))
        XCTAssertNil(command(8, nil))
        XCTAssertNil(command(48, "\t"))  // kVK_Tab
        // ⌘0 is a digit the panel does not claim.
        XCTAssertNil(command(29, "0", .command))
    }

    /// **The one that stands between this change and an app you cannot quit.**
    ///
    /// `.keyboardShortcut("q")`, `("r")` and `(",")` are key equivalents dispatched
    /// inside `NSApplication.sendEvent(_:)`, which runs *after* every local event
    /// monitor — so anything this returns non-nil for is a shortcut the panel has
    /// eaten. ⌘W and ⌘V belong to the system and are here for the same reason.
    func testCommandEventsThePanelDoesNotOwnArePassedThrough() {
        XCTAssertNil(command(12, "q", .command), "⌘Q was swallowed — the app cannot be quit")
        XCTAssertNil(command(15, "r", .command), "⌘R was swallowed — refresh is dead")
        XCTAssertNil(command(43, ",", .command), "⌘, was swallowed — Settings is unreachable")
        XCTAssertNil(command(13, "w", .command), "⌘W was swallowed")
        XCTAssertNil(command(9, "v", .command), "⌘V was swallowed")
        // And the two chords the panel *does* own are only owned bare: ⌘⇧1 and
        // ⌥⌘F belong to whoever else wants them.
        XCTAssertNil(command(18, "1", [.command, .shift]))
        XCTAssertNil(command(3, "f", [.command, .option]))
        // Caps lock is not a chord, so a user typing with it on still filters.
        XCTAssertEqual(command(8, "C", ignoringModifiers: "c", .capsLock), .character("C"))
    }

    // MARK: - Selection

    private let rows = ["claude", "claudecode", "chatgpt", "cursor"]

    func testDownFromNothingSelectsTheFirstRow() {
        var state = PanelKeyboardState.resting
        XCTAssertEqual(PanelKeyboard.reduce(.moveDown, into: &state, rows: rows), .handled)
        XCTAssertEqual(state.selection, "claude")
    }

    func testUpFromNothingSelectsTheLast() {
        var state = PanelKeyboardState.resting
        XCTAssertEqual(PanelKeyboard.reduce(.moveUp, into: &state, rows: rows), .handled)
        XCTAssertEqual(state.selection, "cursor")
    }

    /// Clamps, never wraps. Wrapping from the last row to the first moves the
    /// plate the length of the window in answer to a key that means "one more".
    func testSelectionClampsAtBothEnds() {
        var state = PanelKeyboardState(query: "", isFiltering: false, selection: "cursor")
        PanelKeyboard.reduce(.moveDown, into: &state, rows: rows)
        XCTAssertEqual(state.selection, "cursor")

        state.selection = "claude"
        PanelKeyboard.reduce(.moveUp, into: &state, rows: rows)
        XCTAssertEqual(state.selection, "claude")

        // And the ends themselves.
        PanelKeyboard.reduce(.moveToLast, into: &state, rows: rows)
        XCTAssertEqual(state.selection, "cursor")
        PanelKeyboard.reduce(.moveToFirst, into: &state, rows: rows)
        XCTAssertEqual(state.selection, "claude")

        // An empty list has no ends, and the key is still consumed rather than
        // left to reach AppKit and beep.
        var empty = PanelKeyboardState.resting
        XCTAssertEqual(PanelKeyboard.reduce(.moveDown, into: &empty, rows: []), .handled)
        XCTAssertEqual(PanelKeyboard.reduce(.moveUp, into: &empty, rows: []), .handled)
        XCTAssertNil(empty.selection)
    }

    func testJumpSelectsTheNthRowAndIsConsumedOutOfRange() {
        var state = PanelKeyboardState.resting
        XCTAssertEqual(PanelKeyboard.reduce(.jump(3), into: &state, rows: rows), .handled)
        XCTAssertEqual(state.selection, rows[2])

        // Out of range changes nothing and is still consumed: an unconsumed key
        // equivalent reaching AppKit with no handler is a system beep.
        XCTAssertEqual(PanelKeyboard.reduce(.jump(9), into: &state, rows: rows), .handled)
        XCTAssertEqual(state.selection, rows[2])
    }

    func testReturnActivatesTheSelectionAndIsConsumedWithout() {
        var state = PanelKeyboardState(query: "", isFiltering: false, selection: "chatgpt")
        XCTAssertEqual(
            PanelKeyboard.reduce(.activate, into: &state, rows: rows),
            .activate("chatgpt")
        )
        var empty = PanelKeyboardState.resting
        XCTAssertEqual(PanelKeyboard.reduce(.activate, into: &empty, rows: rows), .handled)
    }

    func testEscapeClearsThenCloses() {
        var state = PanelKeyboardState.filtering("cl", selection: "claude")
        XCTAssertEqual(PanelKeyboard.reduce(.cancel, into: &state, rows: rows), .handled)
        XCTAssertEqual(state, .resting)
        XCTAssertEqual(PanelKeyboard.reduce(.cancel, into: &state, rows: rows), .close)
        XCTAssertEqual(state, .resting)

        // A selection with no query is also something to clear first.
        var selected = PanelKeyboardState(query: "", isFiltering: false, selection: "claude")
        XCTAssertEqual(PanelKeyboard.reduce(.cancel, into: &selected, rows: rows), .handled)
        XCTAssertNil(selected.selection)
    }

    func testALeadingSpaceIsIgnoredAndAnInnerSpaceIsNot() {
        var state = PanelKeyboardState.resting
        XCTAssertEqual(
            PanelKeyboard.reduce(.character(" "), into: &state, rows: rows), .ignored,
            "a leading space opened filter mode — Space is no longer available on a resting panel"
        )
        XCTAssertEqual(state, .resting)

        PanelKeyboard.reduce(.character("c"), into: &state, rows: rows)
        XCTAssertEqual(PanelKeyboard.reduce(.character(" "), into: &state, rows: rows), .handled)
        XCTAssertEqual(state.query, "c ")
    }

    func testBackspacePastTheFirstCharacterLeavesFilterMode() {
        var state = PanelKeyboardState.filtering("c")
        XCTAssertEqual(PanelKeyboard.reduce(.backspace, into: &state, rows: rows), .handled)
        XCTAssertEqual(state.query, "")
        XCTAssertTrue(state.isFiltering, "one backspace emptied the query *and* left filter mode")

        XCTAssertEqual(PanelKeyboard.reduce(.backspace, into: &state, rows: rows), .handled)
        XCTAssertFalse(state.isFiltering)

        // And a backspace on a panel that was never filtering is not the panel's:
        // returning `.handled` there would consume Delete for the whole app.
        var resting = PanelKeyboardState.resting
        XCTAssertEqual(PanelKeyboard.reduce(.backspace, into: &resting, rows: rows), .ignored)
    }

    func testTheQueryStopsAtThirtyTwoCharacters() {
        var state = PanelKeyboardState.resting
        for _ in 0..<40 {
            XCTAssertEqual(PanelKeyboard.reduce(.character("w"), into: &state, rows: rows), .handled)
        }
        XCTAssertEqual(state.query.count, PanelKeyboard.queryLimit)
        XCTAssertEqual(state.query.count, 32, "the cap the width contract is written against moved")
    }

    // MARK: - Reconciling with the drawn rows

    /// The refresh case: `rankedProviders` re-sorts on every reading, and a row
    /// can leave the list entirely with the user's hands off the keyboard.
    func testReconcileDropsASelectionWhoseRowIsGone() {
        var state = PanelKeyboardState(query: "", isFiltering: false, selection: "claude#2")
        PanelKeyboard.reconcile(&state, rows: rows)
        XCTAssertNil(state.selection)
    }

    /// A refinement that narrows nothing still has to put the selection back.
    ///
    /// The keystroke clears it, because the rows are usually about to move under
    /// it — but "cod" to "code" over the same three rows moves no id at all. The
    /// panel therefore reconciles on the query as well as on the ids; without that
    /// the plate vanishes mid-word and Return does nothing for the rest of the
    /// query.
    func testARefinementThatMovesNoRowKeepsASelection() {
        var state = PanelKeyboardState.filtering("cod", selection: "claudecode")
        let unchanged = ["codex", "claudecode", "opencode"]

        XCTAssertEqual(PanelKeyboard.reduce(.character("e"), into: &state, rows: unchanged), .handled)
        XCTAssertNil(state.selection, "the keystroke is supposed to release the selection")

        PanelKeyboard.reconcile(&state, rows: unchanged)
        XCTAssertEqual(state.selection, "codex")
    }

    func testReconcileSelectsTheTopResultOnlyWhileFiltering() {
        var filtering = PanelKeyboardState.filtering("cl")
        PanelKeyboard.reconcile(&filtering, rows: rows)
        XCTAssertEqual(filtering.selection, "claude")

        // A resting panel has no selection until an arrow key asks for one: a
        // plate sitting on row one every time you open the panel is a selection
        // nobody made.
        var resting = PanelKeyboardState.resting
        PanelKeyboard.reconcile(&resting, rows: rows)
        XCTAssertNil(resting.selection)

        // ⌘F with nothing typed is filter mode with no query, and it must not put
        // a plate on anything either.
        var opened = PanelKeyboardState.filtering("")
        PanelKeyboard.reconcile(&opened, rows: rows)
        XCTAssertNil(opened.selection)
    }
}
