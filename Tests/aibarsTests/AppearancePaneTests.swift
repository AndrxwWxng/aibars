import XCTest
import SwiftUI
import AppKit
@testable import aibarsCore

/// The Appearance pane is a Form of controls next to a live preview. A snapshot
/// of it came out blank, which is either a broken pane or a harness that cannot
/// draw a Form nested in a VStack — so this counts the AppKit controls SwiftUI
/// actually instantiated instead of looking at pixels.
final class AppearancePaneTests: XCTestCase {
    @MainActor
    private func hosted<V: View>(_ view: V, height: CGFloat = 520) -> NSView {
        let host = NSHostingView(rootView: AnyView(view))
        host.frame = CGRect(x: 0, y: 0, width: 660, height: height)
        let window = NSWindow(
            contentRect: host.frame,
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.contentView = host
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        return host
    }

    private func controls(in view: NSView) -> [NSControl] {
        var found: [NSControl] = []
        if let control = view as? NSControl { found.append(control) }
        for subview in view.subviews { found.append(contentsOf: controls(in: subview)) }
        return found
    }

    @MainActor
    func testThePaneInstantiatesItsControls() {
        let appearance = AppearanceSettings(store: UserDefaults(suiteName: "pane-tests")!)
        let host = hosted(AppearancePane().environmentObject(appearance))
        let found = controls(in: host)
        XCTAssertGreaterThan(
            found.count, 8,
            "only \(found.count) controls — the options form is not being built"
        )
    }

    /// The pane has to survive being short. Squeezed between a preview strip and
    /// a small window, the form must still scroll rather than vanish.
    @MainActor
    func testThePaneSurvivesAShortWindow() {
        let appearance = AppearanceSettings(store: UserDefaults(suiteName: "pane-tests-short")!)
        let host = hosted(AppearancePane().environmentObject(appearance), height: 300)
        XCTAssertGreaterThan(controls(in: host).count, 4, "the form collapsed in a short window")
    }

    /// Every preset must resolve to a usable panel: a width that fits a menu bar
    /// dropdown and metrics that are not degenerate.
    @MainActor
    func testEveryPresetIsUsable() {
        let appearance = AppearanceSettings(store: UserDefaults(suiteName: "preset-sanity")!)
        for preset in AppearanceSettings.Preset.allCases {
            appearance.apply(preset)
            XCTAssertGreaterThanOrEqual(appearance.panelWidth, 240, "\(preset.id) is too narrow")
            XCTAssertLessThanOrEqual(appearance.panelWidth, 600, "\(preset.id) is too wide")
            let metrics = appearance.metrics
            XCTAssertGreaterThan(metrics.titleSize, 8, "\(preset.id) title type is unreadable")
            XCTAssertGreaterThan(metrics.rowVerticalPadding, 0, "\(preset.id) has no row padding")
            XCTAssertGreaterThan(metrics.barHeight, 0, "\(preset.id) draws a zero-height bar")
        }
    }

    /// Applying a preset then reading it back has to name the same preset, or the
    /// settings pane cannot show which one is selected.
    @MainActor
    func testPresetsRoundTrip() {
        let appearance = AppearanceSettings(store: UserDefaults(suiteName: "preset-roundtrip")!)
        for preset in AppearanceSettings.Preset.allCases {
            appearance.apply(preset)
            XCTAssertEqual(appearance.matchingPreset, preset, "\(preset.id) does not match itself")
        }
    }

    @MainActor
    func testResetReturnsToTheShippedConfiguration() {
        let appearance = AppearanceSettings(store: UserDefaults(suiteName: "preset-reset")!)
        appearance.apply(.dashboard)
        appearance.resetToDefaults()
        XCTAssertEqual(appearance.panelWidth, 356, "reset must restore the shipped panel width")
    }
}
