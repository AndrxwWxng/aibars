import XCTest
import AppKit
import Combine
@testable import aibarsCore

/// What is left of `MenuBarIcon` once `MenuBarStripRenderer` owns the drawing:
/// how tall the status item is, and which way the bar it sits in is currently
/// painted. Both are read while the strip is being rasterised — before any
/// window exists, and from a notification handler — so "it answers at all" is
/// the property that would actually fail.
///
/// The second fact is deliberately not the application's appearance. macOS
/// paints the menu bar dark under Light mode whenever the wallpaper behind it is
/// dark, while the application's own appearance stays light throughout — so a
/// coloured strip, which cannot be a template image and therefore bakes its
/// neutral colour in, drew every figure black on a dark bar. What this file pins
/// is the pair of platform facts the fix makes a claim on: that the two readings
/// can disagree inside one process, and that a change to the bar's paint is
/// heard on a channel of its own rather than only on the theme notification.
///
/// The outcome cannot be cornered from here, only the substrate. A bundle with
/// no status item has no bar window at all, so there is nothing for a reading of
/// the bar to disagree with — which is why these tests are written against
/// `NSAppearance` and `NSWindow` rather than by putting the process into the
/// state being described.
///
/// Every assertion about the image itself lives in `MenuBarStripRendererTests`
/// now, because the image is drawn there.
final class MenuBarIconTests: XCTestCase {
    /// The windows the appearance tests built, kept alive for the length of the
    /// test. Not locals: what is being read is a property of the window, and a
    /// window nobody retains is a reading taken against an object that is
    /// already going away.
    private var windows: [NSWindow] = []

    override func tearDown() {
        windows.removeAll()
        super.tearDown()
    }

    // MARK: - Height

    /// A status glyph that is taller than the bar is clipped, and a fractional
    /// one is scaled to fit — which is enough to smear tabular figures.
    func testHeightFitsTheMenuBar() {
        XCTAssertLessThanOrEqual(MenuBarIcon.height, 16, "taller than the status bar allows")
        XCTAssertEqual(MenuBarIcon.height, MenuBarIcon.height.rounded(), "a fractional height gets scaled")
    }

    // MARK: - Which way the bar is painted

    /// The disagreeing case, constructed: the application light while the bar it
    /// draws into is dark.
    ///
    /// Both readings go through `bestMatch(from: [.aqua, .darkAqua])`, and that
    /// fold is what makes the bar's own appearance usable at all — a status bar
    /// window reports one of the *vibrant* names, never `NSAppearanceNameDarkAqua`,
    /// so unfolded it is a name nothing in the app could act on. Read straight
    /// off `NSAppearance` rather than off the process, because "app aqua, bar
    /// darkAqua" is a state no unit test bundle can put a real menu bar into.
    func testTheBarAndTheApplicationCanDisagreeAboutDark() throws {
        let application = try XCTUnwrap(NSAppearance(named: .aqua))
        let bar = try XCTUnwrap(NSAppearance(named: .vibrantDark))

        XCTAssertFalse(readsDark(application), "the application is in Light mode")
        XCTAssertTrue(readsDark(bar), "the bar it draws into is painted dark")
        XCTAssertNotEqual(
            readsDark(application), readsDark(bar),
            "if these could not disagree there would be nothing to read the bar for"
        )
    }

    /// Every name a bar can report folds onto one of the two, including the
    /// high-contrast variants: with Increase Contrast on, a dark bar reports
    /// `NSAppearanceNameAccessibilityVibrantDark`, and a fold that missed it
    /// would bake black figures into exactly the strip that can least afford
    /// them.
    func testEveryVibrantNameFoldsOntoLightOrDark() throws {
        for name in [NSAppearance.Name.vibrantDark, .accessibilityHighContrastVibrantDark, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            XCTAssertTrue(readsDark(appearance), "\(name.rawValue) is a dark bar")
        }
        for name in [NSAppearance.Name.vibrantLight, .accessibilityHighContrastVibrantLight, .aqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            XCTAssertFalse(readsDark(appearance), "\(name.rawValue) is a light bar")
        }
    }

    /// And the disagreement is reachable inside one process rather than only
    /// between two `NSAppearance` values: a window carrying its own appearance
    /// resolves apart from the application, while one carrying none inherits it.
    /// That is the whole mechanism behind reading the status item's window
    /// instead of `NSApp` — no private view hierarchy, one documented property.
    @MainActor
    func testAWindowResolvesItsAppearanceApartFromTheApplication() throws {
        let inheriting = window()
        // Read after a window exists: instantiating one is what creates `NSApp`
        // in a bundle that has no application object of its own, so asking first
        // would be asking a different question.
        let applicationIsDark = readsDark(NSApp?.effectiveAppearance)
        XCTAssertEqual(
            readsDark(inheriting.effectiveAppearance), applicationIsDark,
            "a window with no appearance of its own should follow the application"
        )

        // The opposite of however this Mac is set, so the disagreement is
        // constructed on a light machine and on a dark one rather than only on
        // whichever the suite happens to run under.
        let carrying = window()
        carrying.appearance = try XCTUnwrap(
            NSAppearance(named: applicationIsDark ? .vibrantLight : .vibrantDark)
        )
        XCTAssertEqual(
            readsDark(carrying.effectiveAppearance), !applicationIsDark,
            "the window did not keep its own appearance"
        )
        XCTAssertNotEqual(
            readsDark(carrying.effectiveAppearance), readsDark(inheriting.effectiveAppearance),
            "two windows in one process agreed everywhere, so the bar could not disagree either"
        )
    }

    /// The strip resolves its neutral colour from this before the status item has
    /// a window to ask, so at that point it has to answer off the application
    /// alone — and with no application object at all it has to answer "light"
    /// rather than trap.
    ///
    /// The expectation is taken live rather than written down: this bundle owns
    /// no status item, so the bar's appearance *is* the application's here and
    /// the two readings have to agree whichever the property is taken from.
    @MainActor
    func testIsDarkMenuBarAnswersWithoutAScene() {
        let expected = readsDark(NSApp?.effectiveAppearance)
        XCTAssertEqual(MenuBarIcon.isDarkMenuBar, expected)
        // Idempotent: it reads a system fact rather than latching one, so the
        // observer's deferred re-read cannot get a stale answer.
        XCTAssertEqual(MenuBarIcon.isDarkMenuBar, expected)
    }

    // MARK: - Hearing the next change

    /// A wallpaper change repaints the bar and fires no theme notification, so an
    /// observer listening for `AppleInterfaceThemeChangedNotification` alone
    /// leaves the strip carrying yesterday's colour until the next usage refresh.
    /// The channel that covers both is the bar window's own `effectiveAppearance`,
    /// and this pins the two things that has to be true of: that it is KVO
    /// compliant, and that it publishes on a change nothing posted a
    /// notification for.
    ///
    /// Asserted against an ordinary `NSWindow` because the property is
    /// `NSWindow`'s and a test bundle cannot own a status item. Nothing here
    /// posts a distributed notification either: the theme one is system-wide, and
    /// a suite that posted it would tell every app on the machine the theme had
    /// changed.
    @MainActor
    func testAWindowsAppearancePublishesOnItsOwnWithoutAThemeChange() throws {
        let observed = window()
        observed.appearance = try XCTUnwrap(NSAppearance(named: .vibrantLight))

        var readings: [Bool] = []
        let observation = observed.observe(\.effectiveAppearance) { window, _ in
            readings.append(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
        }
        defer { observation.invalidate() }

        XCTAssertEqual(readings, [], "an observation firing before anything changed would redraw on nothing")

        observed.appearance = try XCTUnwrap(NSAppearance(named: .vibrantDark))
        XCTAssertEqual(readings, [true], "the repaint was not heard")

        observed.appearance = try XCTUnwrap(NSAppearance(named: .vibrantLight))
        XCTAssertEqual(readings, [true, false], "the repaint back was not heard")

        // Handing the window back to the application is a change too — a display
        // leaving is how the app meets it — and it has to land as the
        // application's reading rather than as the last one held.
        observed.appearance = nil
        XCTAssertEqual(
            readings, [true, false, readsDark(NSApp?.effectiveAppearance)],
            "clearing the window's appearance did not fall back to the application"
        )
    }

    /// The label subscribes at launch and the theme may not change for days, so
    /// an observer that only published on change would leave the first strip
    /// drawn against a guess.
    @MainActor
    func testObserverPublishesItsInitialValue() {
        let observer = SystemAppearanceObserver.shared
        XCTAssertEqual(observer.isDark, MenuBarIcon.isDarkMenuBar, "the observer started out of step")

        var received: [Bool] = []
        let subscription = observer.$isDark.sink { received.append($0) }
        defer { subscription.cancel() }

        XCTAssertEqual(received, [MenuBarIcon.isDarkMenuBar], "a new subscriber got nothing to draw with")
    }

    // MARK: - Harness

    /// The rule both readings go through, written out here so the tests state it
    /// rather than imply it.
    private func readsDark(_ appearance: NSAppearance?) -> Bool {
        appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Never ordered in: what is under test is how a window resolves its
    /// appearance, which it does whether or not anyone can see it.
    @MainActor
    private func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 40, height: 22),
            styleMask: [.borderless], backing: .buffered, defer: true
        )
        windows.append(window)
        return window
    }
}

final class SessionStoreTests: XCTestCase {
    private let a = "session-store-test-a"
    private let b = "session-store-test-b"

    override func tearDown() {
        SessionStore.shared.clear(a)
        SessionStore.shared.clear(b)
        super.tearDown()
    }

    /// All tokens share one Keychain item now, so the round trip has to keep
    /// providers from overwriting each other.
    func testMultipleProvidersShareOneItemWithoutClobbering() throws {
        let store = SessionStore.shared
        try store.setToken("alpha", for: a)
        try store.setToken("beta", for: b)

        XCTAssertEqual(store.token(for: a), "alpha")
        XCTAssertEqual(store.token(for: b), "beta")

        store.invalidateCache()
        XCTAssertEqual(store.token(for: a), "alpha", "lost after a reload")
        XCTAssertEqual(store.token(for: b), "beta", "lost after a reload")

        store.clear(a)
        store.invalidateCache()
        XCTAssertNil(store.token(for: a))
        XCTAssertEqual(store.token(for: b), "beta", "clearing one dropped the other")
    }

    func testMetadataTracksCredentialsWithoutReadingTheKeychain() throws {
        let store = SessionStore.shared
        XCTAssertFalse(store.hasCredential(for: a))
        try store.setToken("alpha", for: a)
        XCTAssertTrue(store.hasCredential(for: a))
        store.clear(a)
        XCTAssertFalse(store.hasCredential(for: a))
    }
}
