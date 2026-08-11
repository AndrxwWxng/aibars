import SwiftUI
import AppKit
import aibarsCore

@main
struct aibarsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var state = AppState.shared
    @StateObject private var appearance = AppearanceSettings.shared
    @State private var showSettings = false

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(state: state, showSettings: $showSettings, appearance: appearance)
                .environmentObject(state)
                .environmentObject(appearance)
        } label: {
            MenuBarLabel(state: state, appearance: appearance)
        }
        .menuBarExtraStyle(.window)
        .onChange(of: showSettings) { newValue in
            if newValue {
                SettingsWindowController.show(state: state)
                showSettings = false
            }
        }
    }
}

/// Starts the refresh loop when the app launches.
///
/// It used to hang off the dropdown's `.task`, and `MenuBarExtra` only builds
/// its content when the menu is opened — so nothing refreshed until the user
/// clicked the icon, and the icon they were deciding whether to click showed no
/// data. A menu bar app has to be working before anyone looks at it.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppState.shared.start()
            // What macOS says, not what we last asked for: a login item can be
            // removed in System Settings while the app isn't running, and the
            // toggle in Settings has to open showing that.
            LoginItem.shared.refresh()
            // A no-op unless the user has already turned alerts on, so a first
            // launch raises no permission prompt. Asking for notifications
            // before anyone has asked for notifications is the nag this app is
            // written to avoid.
            Task { await AlertCenter.shared.primeIfNeeded() }
            // Opens the history database and applies retention once. `shared` is
            // nil when the file could not be opened — a full disk, a container
            // the app cannot write — and that means history is simply off, which
            // is not a reason to fail a launch.
            UsageHistoryStore.shared?.maintain()
        }
        // Deferred a turn deliberately, and this is why the observer is asked
        // twice. The status item's window is created as the `MenuBarExtra` scene
        // installs itself: measured, the observer's own first look — taken when
        // the label is built — finds no window at all, and one exists by the next
        // turn of the run loop. Without this the strip would watch nothing until
        // a display was plugged in.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { MenuBarAppearance.shared.attach() }
        }
    }
}

/// Which way the menu bar the status item sits in is currently painted.
///
/// `NSApp.effectiveAppearance` answers a different question. macOS paints the
/// menu bar dark under Light mode whenever the wallpaper behind it is dark, and
/// the application's own appearance stays light throughout — so a coloured strip,
/// which cannot be a template image and therefore bakes its neutral colour in,
/// drew every figure and every brand mark black on a dark bar.
///
/// The status item's own window carries the appearance the bar is actually drawn
/// in. Verified rather than assumed, and no private view hierarchy is reached
/// into — this is a window in our own process and a documented property on it:
///
/// - `NSApp.windows` holds an `NSStatusBarWindow` from the first run-loop turn
///   after launch, one per screen carrying a bar;
/// - its `effectiveAppearance` reads one of the vibrant names where the
///   application reads `NSAppearanceNameDarkAqua`, so the two are separately
///   resolved facts and not the same one twice;
/// - `bestMatch(from:)` folds the vibrant names onto the two we ask about;
/// - `effectiveAppearance` is KVO compliant on the window, which is what gives
///   this the trigger it needs.
///
/// That trigger is the point. `AppleInterfaceThemeChangedNotification` fires for
/// the Light/Dark switch and for nothing else, so a wallpaper change left the
/// strip carrying yesterday's colour. Observing the window's own appearance
/// covers both, because whatever repaints the bar is by definition a change to
/// the property the bar is painted from.
///
/// The window's first answer is not its final one: measured, it reports
/// `NSAppearanceNameVibrantLight` for the ~16ms before it has resolved against
/// the bar, and the second status item's window arrives after the first has. So
/// this is written to be corrected rather than to be right first time — the
/// opening value comes from the application, the KVO handler replaces it, and a
/// window arriving late is picked up because the handler re-takes the tokens
/// whenever the set has changed size.
///
/// This is the trigger half, and it sits next to the label it redraws. The value
/// is *spent* elsewhere: `MenuBarIcon.isDarkMenuBar` is what
/// `MenuBarStripRenderer` bakes the strip's neutral colour from and what keys its
/// memo, so that side has to read the bar at the moment it draws rather than
/// trust a cached answer from this one. Both sides can see the window —
/// `NSApp.windows` is the process's, not the app target's — and the split is the
/// ordinary one: an observation that says *when*, a read at the point of use that
/// says *what*.
@MainActor
final class MenuBarAppearance: ObservableObject {
    static let shared = MenuBarAppearance()

    /// True when the bar is painted dark, whatever the application's appearance
    /// says.
    ///
    /// Published so the label redraws: SwiftUI re-renders on state changes and
    /// not on appearance changes, and the strip has no other reason to update
    /// between usage refreshes.
    @Published private(set) var isDark: Bool

    /// The appearance the bar itself is painted in.
    ///
    /// Falls back to the application's rather than to a fixed value: on a Mac
    /// where the window cannot be found the old reading is still right most of
    /// the time, and it is the reading the app shipped with.
    var appearance: NSAppearance {
        Self.statusBarWindows.first?.effectiveAppearance
            ?? NSApp?.effectiveAppearance
            ?? NSAppearance(named: .aqua)
            ?? NSAppearance.currentDrawing()
    }

    private var observations: [NSKeyValueObservation] = []
    private var screenObserver: NSObjectProtocol?

    private init() {
        isDark = Self.isDark(NSApp?.effectiveAppearance)
        attach()
        // A display arriving or leaving replaces the windows this observes, so
        // the tokens have to be re-taken against the new ones.
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.attach() }
            }
        }
    }

    deinit {
        if let screenObserver {
            NotificationCenter.default.removeObserver(screenObserver)
        }
    }

    /// Takes the reading and starts watching for the next one.
    ///
    /// Idempotent, and safe to call before the status item exists: dropping the
    /// old tokens is what stops a second call from doubling the notifications,
    /// and finding no window simply leaves this watching nothing until something
    /// calls again.
    func attach() {
        observations = Self.statusBarWindows.map { window in
            window.observe(\.effectiveAppearance) { [weak self] _, _ in
                // Hopped rather than read inline: KVO delivers on whichever
                // thread made the change, and the value this cares about is the
                // one that has settled rather than the one mid-flight.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { self?.reread() }
                }
            }
        }
        publish()
    }

    /// The KVO handler. A second status item window can arrive after the first
    /// has settled, and an unobserved window is a bar this would stop hearing
    /// about, so the tokens are re-taken whenever the set has changed size.
    /// `attach` ends in a `publish` and the counts agree by then, so this settles
    /// in one round rather than bouncing.
    private func reread() {
        if Self.statusBarWindows.count == observations.count {
            publish()
        } else {
            attach()
        }
    }

    /// Publishes only on a flip. Anything finer would redraw the strip for a
    /// vibrancy change that cannot alter a single colour in it.
    private func publish() {
        let dark = Self.isDark(appearance)
        guard dark != isDark else { return }
        isDark = dark
    }

    /// Matched on the class name because `NSStatusBarWindow` is not a type this
    /// app can name. One per screen carrying a bar, and two displays with
    /// different wallpapers can be painted differently — but the strip is one
    /// image serving every bar, so there is one answer available and the first
    /// window is the one that gives it.
    private static var statusBarWindows: [NSWindow] {
        (NSApp?.windows ?? []).filter {
            String(describing: type(of: $0)).contains("NSStatusBarWindow")
        }
    }

    private static func isDark(_ appearance: NSAppearance?) -> Bool {
        appearance?.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

/// What sits in the menu bar itself: one brand mark and one figure per service,
/// closest to its cap first.
///
/// It used to be four abstract bars and a percentage beside them, and there was
/// no way to tell which bar was Claude — a meter with no identity is decoration,
/// and the number next to it named nothing. Every service now carries its own
/// mark and its own reading, so there is nothing left for a second `Text` to
/// add: it would print the highest percentage a second time.
struct MenuBarLabel: View {
    @ObservedObject var state: AppState
    @ObservedObject var appearance: AppearanceSettings
    /// Observed only so the strip is redrawn when the bar it sits in changes
    /// colour, which it bakes in whenever it is carrying usage tints. The menu
    /// bar's appearance rather than the application's — see `MenuBarAppearance`.
    @ObservedObject private var menuBar = MenuBarAppearance.shared

    /// The services the strip will actually draw.
    ///
    /// `AppState` reports what every service said; `AppearanceSettings` owns the
    /// decision about which of them fit and in what order, because the Appearance
    /// pane's live preview has to make the same one — a preview that disagrees
    /// with the strip it previews is worse than no preview.
    private var entries: [MenuBarEntry] {
        appearance.menuBarEntries(in: state)
    }

    var body: some View {
        // A pre-rendered image, not the SwiftUI view: MenuBarExtra draws
        // Shape-based labels as nothing at all.
        Image(nsImage: MenuBarStripRenderer.image(
            entries: entries,
            height: appearance.menuBarGlyphHeight,
            colour: appearance.menuBarColour,
            warningThreshold: appearance.warningThreshold
        ))
        .padding(.horizontal, 1)
        // What is on screen, not the panel's headline. The headline names one
        // service; the strip names up to three, and VoiceOver should hear the
        // ones that are actually being drawn.
        .accessibilityLabel(MenuBarStripContent.accessibilityLabel(entries))
    }
}
