import AppKit
import Combine

/// What the status item needs to know about the bar it sits in.
///
/// This used to rasterise the four-bar meter as well. `MenuBarStripRenderer`
/// draws the status item now — a brand mark and its own figure per service,
/// because four abstract bars could not tell you which bar was Claude — and it
/// memoises on the strip's own inputs rather than on bucketed levels. What is
/// left here is the pair of facts every drawing of the status item still needs
/// and that neither the strip model nor the rasteriser should own: how tall the
/// bar is, and which way the bar itself is currently painted.
@MainActor
public enum MenuBarIcon {
    /// Status bar glyphs sit in a 22pt bar; 13pt of drawing with integral width
    /// keeps the marks crisp.
    nonisolated public static let height: CGFloat = 13

    /// Whether the menu bar is currently dark.
    ///
    /// The menu bar's own appearance, and deliberately not the application's.
    /// macOS paints the bar dark under Light mode whenever the desktop picture
    /// behind it is dark, and `NSApp.effectiveAppearance` reports `.aqua`
    /// throughout that — so baking the strip's neutral from the application drew
    /// every figure and every brand mark black on a dark bar. The status item's
    /// own window carries the appearance the bar is actually drawn in, it is a
    /// window in this process, and `effectiveAppearance` is a documented property
    /// on it: nothing here reaches into a private view hierarchy or asks by KVC.
    ///
    /// A coloured strip cannot be a template, so it bakes its neutral colour in
    /// and has to be told which one to bake. That is the only reason this is read
    /// directly rather than left to SwiftUI's environment, which resolves against
    /// the window an `ImageRenderer` draws into and not the menu bar.
    ///
    /// Read at the moment of drawing and never latched. The window does not exist
    /// until the run-loop turn after launch, it is replaced when a display
    /// arrives, and measured it answers `NSAppearanceNameVibrantLight` for the
    /// moment before it has resolved against the bar — so a cached answer would
    /// be a wrong one, and falling back to the application keeps the reading the
    /// app shipped with on any Mac where the window cannot be found. *When* to
    /// redraw is the other half of the question and not this one's: the app
    /// target's `MenuBarAppearance` answers it by observing this same window.
    static var isDarkMenuBar: Bool {
        isDark(statusBarWindow?.effectiveAppearance ?? NSApp?.effectiveAppearance)
    }

    /// Matched on the class name because `NSStatusBarWindow` is not a type this
    /// app can name. There is one per screen carrying a bar, and two screens with
    /// different wallpapers can be painted differently — but the strip is a single
    /// image serving every bar, so there is one answer to be had and the first
    /// window is what gives it.
    private static var statusBarWindow: NSWindow? {
        (NSApp?.windows ?? []).first {
            String(describing: type(of: $0)).contains("NSStatusBarWindow")
        }
    }

    /// The vibrant appearance names are what a status bar window actually
    /// reports, where the application reports `NSAppearanceNameDarkAqua`;
    /// `bestMatch(from:)` folds both spellings onto the two the strip asks about.
    private static func isDark(_ appearance: NSAppearance?) -> Bool {
        appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// Publishes when the paint of the menu bar changes.
///
/// A coloured status image has its neutral colour baked in, so anything that
/// repaints the bar has to redraw it. SwiftUI re-renders on state changes, not on
/// appearance changes, and a strip has no other reason to update between usage
/// refreshes — so without this it keeps yesterday's colour until the next one.
///
/// Three triggers, because the bar's paint has three causes and the theme
/// notification covers one of them:
///
/// - `AppleInterfaceThemeChangedNotification` — the Light/Dark switch, and the
///   only cause the shipped observer heard about;
/// - `activeSpaceDidChangeNotification` — a space carries its own desktop
///   picture, and a dark picture is enough to darken the bar under Light mode;
/// - `didChangeScreenParametersNotification` — a display arriving, leaving or
///   being rearranged moves the bar over a different picture.
///
/// What none of the three sees is the user changing the picture of the space they
/// are already on. There is no public notification for that; the trigger that
/// does catch it is KVO on the status item window's own `effectiveAppearance`,
/// which needs the status item, so it lives beside it in the app target rather
/// than in a framework type that has no handle on one.
@MainActor
public final class SystemAppearanceObserver: ObservableObject {
    public static let shared = SystemAppearanceObserver()

    @Published public private(set) var isDark: Bool

    /// One token per notification centre. Three centres deliver these three
    /// notifications — distributed, workspace, application — and a token has to
    /// be handed back to the centre it came from, so they are kept apart rather
    /// than collected into one array.
    private var themeObserver: NSObjectProtocol?
    private var spaceObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?

    private init() {
        isDark = MenuBarIcon.isDarkMenuBar
        themeObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleReread()
        }
        spaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleReread()
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.scheduleReread()
        }
    }

    deinit {
        if let themeObserver {
            DistributedNotificationCenter.default().removeObserver(themeObserver)
        }
        if let spaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(spaceObserver)
        }
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    /// Takes the reading on the next turn of the loop rather than inline: every
    /// one of the three notifications arrives a beat before the thing it
    /// announces has settled — the theme flip before `effectiveAppearance` moves,
    /// a space change before the bar has repainted, a screen change before the
    /// status item's window has been replaced.
    ///
    /// `nonisolated` because a notification handler is delivered outside the
    /// actor; the hop is what puts the read back on it.
    private nonisolated func scheduleReread() {
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                self.reread()
            }
        }
    }

    private func reread() {
        let dark = MenuBarIcon.isDarkMenuBar
        // Only on a flip. A space change fires on every switch and most switches
        // do not change the bar's paint at all, and republishing an unchanged
        // value asks the strip to redraw itself into the identical image.
        guard dark != isDark else { return }
        isDark = dark
    }
}
