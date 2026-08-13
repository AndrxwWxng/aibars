import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// What the panel's controls say they are.
///
/// Every one of them was drawn as a bare `Image(systemName:)` with a `.help` on
/// it, and `.help` is the accessibility *hint* — the sentence about what pressing
/// would do. With no name to go with it, VoiceOver falls back to the symbol, so
/// the panel's four permanent controls announced "arrow.clockwise",
/// "chart.xyaxis.line", "gearshape" and "power". The disclosure had the opposite
/// half of the same problem: a name and no state, so an open group and a folded
/// one sounded identical.
///
/// Asserted against the values the views are built from rather than against a
/// rendered accessibility tree. An `NSHostingView` laid out off screen publishes
/// one `AXGroup` and no children at all — there is nothing to walk here — so what
/// is checkable is the data, and the shape of the data is what makes the check
/// worth anything: `HoverIconButton.name` has no default, so a nameless button
/// does not compile, and `HeaderControl` is a closed list, so an unnamed one
/// cannot be added beside it either.
final class PanelA11yTests: XCTestCase {

    // MARK: - The header's cluster

    /// Every control in the header has a name, and it is not its symbol.
    func testNoHeaderControlAnnouncesItsSymbol() {
        for control in HeaderControl.allCases {
            XCTAssertFalse(
                control.name.isEmpty,
                "\(control.systemName) has no name, so it announces as its symbol"
            )
            XCTAssertNotEqual(control.name, control.systemName)
            // An SF Symbol is a dotted identifier where it is compound at all —
            // "arrow.clockwise", "chart.xyaxis.line" — and a name is a phrase, so
            // a name carrying a dot is a symbol that has been copied across.
            XCTAssertFalse(
                control.name.contains("."),
                "\(control.name) reads like a symbol rather than like a name"
            )
            // The discriminator that holds for all four, since "gearshape" and
            // "power" are single words and carry no dot: a symbol is lower case
            // throughout and a name is a sentence, so it is not.
            XCTAssertEqual(
                control.systemName, control.systemName.lowercased(),
                "\(control.systemName) is not the lower-case form this case tells them apart by"
            )
            XCTAssertNotEqual(
                control.name, control.name.lowercased(),
                "\(control.name) is set like a symbol rather than like a sentence"
            )
        }
    }

    /// And no two of them answer to the same one. Four controls in a row of
    /// 22pt squares are told apart by name alone under VoiceOver.
    func testTheHeadersControlsAreNamedApart() {
        let names = Set(HeaderControl.allCases.map(\.name))
        XCTAssertEqual(
            names.count, HeaderControl.allCases.count,
            "two of the header's controls announce the same name: \(names.sorted())"
        )
    }

    /// The name reaches the button as a name and the tooltip stays the hint.
    ///
    /// The two are deliberately different strings for the refresh control: the
    /// name is what it is, the hint carries the age of the readings and the
    /// keyboard shortcut. Collapsing them would put "· updated 12s ago (⌘R)" into
    /// the control's name, which changes every second the panel is open.
    @MainActor
    func testTheButtonKeepsItsNameApartFromItsHint() {
        let refresh = HoverIconButton(.refreshAll, help: "Refresh all · updated 12s ago (⌘R)") {}
        XCTAssertEqual(refresh.name, "Refresh all")
        XCTAssertEqual(refresh.systemName, "arrow.clockwise")
        XCTAssertNotEqual(refresh.name, refresh.help)
        XCTAssertNotEqual(refresh.name, refresh.systemName)
    }

    /// The spinner that replaces a button while a fetch is out is named too, and
    /// with one string rather than two.
    ///
    /// Both of them stand in for a `HoverIconButton` — the header's cluster
    /// swaps the refresh control for one, and a row's actions swap its own — and
    /// a bare `ProgressView` announces as an unlabelled progress indicator for as
    /// long as the fetch takes, which on a launch sweep is most of the time the
    /// panel is open.
    func testTheInFlightSpinnersAreNamed() {
        XCTAssertFalse(HoverIconButton.inFlightName.isEmpty)
        XCTAssertFalse(HoverIconButton.inFlightName.contains("."))
        // Not one of the four names, or the cluster would answer to the same
        // word twice while a sweep is running.
        XCTAssertFalse(HeaderControl.allCases.map(\.name).contains(HoverIconButton.inFlightName))
    }

    // MARK: - The section disclosures

    /// A folded group and an open one do not sound the same.
    ///
    /// Open and closed used to be drawn only as a `rotationEffect` on the
    /// chevron, and a rotation is not spoken: there was no `accessibilityValue`,
    /// no trait, and no `DisclosureGroup` to carry one. This is the difference
    /// the value has to make.
    func testTheDisclosureSaysWhetherItIsOpen() {
        let open = DisclosureHeader.expansionValue(isExpanded: true)
        let folded = DisclosureHeader.expansionValue(isExpanded: false)
        XCTAssertFalse(open.isEmpty)
        XCTAssertFalse(folded.isEmpty)
        XCTAssertNotEqual(
            open, folded,
            "an open group and a folded one both announce \"\(open)\""
        )
    }

    /// And it is a value rather than the trait that would sound like something
    /// else. `.isSelected` speaks as "selected", which is the word the Settings
    /// sidebar's chosen pane already uses — a folded group and a chosen pane
    /// would then be indistinguishable — and `.isToggle` is macOS 14, a version
    /// above the floor `project.yml` pins.
    func testTheDisclosureDoesNotSpeakAsASelection() {
        for isExpanded in [true, false] {
            XCTAssertNotEqual(
                DisclosureHeader.expansionValue(isExpanded: isExpanded).lowercased(),
                "selected"
            )
        }
    }

    /// The hint names the rows it would move, both ways round.
    ///
    /// The tooltip it replaces said "Show 3 more" when folded and the single word
    /// "Hide" when open — one word naming neither the subject nor what pressing
    /// would leave behind, which is the state a reader is in when they most need
    /// telling.
    func testTheDisclosureSaysWhatPressingItWouldDo() {
        let open = DisclosureHeader.expansionHint(isExpanded: true, count: 3)
        let folded = DisclosureHeader.expansionHint(isExpanded: false, count: 3)
        XCTAssertNotEqual(open, folded)
        for hint in [open, folded] {
            XCTAssertTrue(hint.contains("3"), "\"\(hint)\" does not say how many rows it moves")
            XCTAssertGreaterThan(
                hint.split(separator: " ").count, 1,
                "\"\(hint)\" is the one-word tooltip this replaced"
            )
        }
    }
}
