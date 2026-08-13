import AppKit
import Carbon.HIToolbox

/// What macOS currently says about the panel's global shortcut.
///
/// Shaped like `LoginItemState` deliberately, and for the same reason: the
/// unhappy cases have different remedies, and a control that reports "on" over a
/// registration that failed is worse than one that reports nothing.
public enum GlobalHotkeyState: Equatable, Sendable {
    /// Nothing recorded. The shipped state.
    case none
    /// Recorded and switched off by the user. The combination is kept so turning
    /// it back on returns them to their own binding.
    case off(KeyCombo)
    case registered(KeyCombo)
    /// Recorded, and macOS would not give it to us. Carries the reason.
    case unavailable(KeyCombo, String)

    public var combo: KeyCombo? {
        switch self {
        case .none: return nil
        case .off(let c), .registered(let c), .unavailable(let c, _): return c
        }
    }

    /// Where the switch sits. `unavailable` counts as on for the reason
    /// `LoginItemState.requiresApproval` does: the user asked for it, it is
    /// recorded, and unticking it would hide the note explaining what went wrong.
    public var isOn: Bool {
        switch self {
        case .none, .off: return false
        case .registered, .unavailable: return true
        }
    }

    /// A line to print under the field, or nil when there is nothing to say.
    public var note: String? {
        guard case .unavailable(_, let reason) = self else { return nil }
        return reason
    }
}

/// The panel's global shortcut, over Carbon's `RegisterEventHotKey`.
///
/// Carbon and not `NSEvent.addGlobalMonitorForEvents`, and not a `CGEventTap`.
/// Both of those need Accessibility permission — a TCC prompt, a trip to System
/// Settings and a relaunch, for a keyboard shortcut — and neither can take the
/// keystroke away from the app in front, so ⌃⌥⌘A would also type an `a` into
/// whatever was frontmost. `RegisterEventHotKey` needs no permission and no
/// entitlement, works whether or not the app is sandboxed, and the WindowServer
/// withholds the combination from everyone else while we hold it. **This feature
/// must not grow an Accessibility prompt**: anything that reaches for one of the
/// other two mechanisms is changing what the app asks of the user, not just how
/// it listens.
///
/// What it cannot do is tell us that somebody else got there first. When another
/// application holds the combination `RegisterEventHotKey` returns `noErr` and
/// the handler simply never fires; `eventHotKeyExistsErr` means *this* process
/// already holds it and nothing else. There is no API, public or private, that
/// answers "who owns ⌃⌥⌘A" — so the recorder prevents the slice that can be
/// prevented (the combinations macOS itself has bound) and the pane says the
/// rest in plain words rather than pretending to detect it.
@MainActor
public final class GlobalHotkey: ObservableObject {
    public static let shared = GlobalHotkey()

    @Published public private(set) var state: GlobalHotkeyState = .none

    /// Raised the first time a press finds no status item button to click. The
    /// shortcut registered, macOS delivered it, and there was nothing to open —
    /// which is a different fault from a refused registration and gets a
    /// different sentence.
    @Published public private(set) var didFailToOpen = false

    private let store: UserDefaults
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    /// Depth rather than a Bool: the recorder suspends while it is open, and a
    /// second suspend arriving from anywhere else must not be undone by the
    /// recorder's own resume.
    private var suspensions = 0

    /// `store` is injectable for the same reason `AppearanceSettings`'s is: a
    /// test gets a scratch domain instead of the user's real binding.
    public init(store: UserDefaults = .standard) {
        self.store = store
    }

    // MARK: - Lifecycle

    /// Reads the stored binding and registers it. Call once, at launch.
    ///
    /// Idempotent: an existing registration is dropped first, so calling this
    /// twice leaves one hot key rather than leaking the first one's ref.
    public func start() {
        apply(HotkeyStore.combo(in: store), enabled: HotkeyStore.isEnabled(in: store))
    }

    /// Records a new combination, or clears it with nil. Persists, then
    /// re-registers, then publishes whatever actually happened — never what was
    /// asked for.
    public func setCombo(_ combo: KeyCombo?) {
        HotkeyStore.setCombo(combo, in: store)
        didFailToOpen = false
        apply(combo, enabled: HotkeyStore.isEnabled(in: store))
    }

    public func setEnabled(_ enabled: Bool) {
        HotkeyStore.setEnabled(enabled, in: store)
        apply(HotkeyStore.combo(in: store), enabled: enabled)
    }

    /// Drops the registration while something else needs the raw keystrokes —
    /// which is exactly one thing: the recorder. Without this, recording ⌃⌥⌘A
    /// while ⌃⌥⌘A is already bound opens the panel over the settings window
    /// mid-recording.
    ///
    /// The published state deliberately does not move. A field that reported
    /// "not registered" for the two seconds the recorder is open would be
    /// telling the user their shortcut had broken at the exact moment they were
    /// looking at it.
    public func suspend() {
        suspensions += 1
        guard suspensions == 1 else { return }
        unregisterHotKey()
    }

    public func resume() {
        suspensions = max(0, suspensions - 1)
        guard suspensions == 0 else { return }
        apply(HotkeyStore.combo(in: store), enabled: HotkeyStore.isEnabled(in: store))
    }

    /// Everything Carbon holds on our behalf, released. Called from
    /// `applicationWillTerminate` — the process is about to go and the kernel
    /// would clean up anyway, but a registration this class opened is a
    /// registration this class closes, and the symmetry is what makes the
    /// suspend/resume pair above readable.
    public func stop() {
        unregisterHotKey()
        if let handlerRef {
            RemoveEventHandler(handlerRef)
            self.handlerRef = nil
        }
        // Through `publish` rather than assigned, so calling this twice is one
        // notification and not two — the same rule the rest of the class follows.
        publish(.none)
    }

    // MARK: - Registration

    /// True when there is a real `.app` around `Bundle.main`.
    ///
    /// Everything below short-circuits on it, for the reason `LoginItem` does:
    /// `RegisterEventHotKey` is process-wide and system-visible, and a test run
    /// that reached it would grab a combination out of the user's hands for as
    /// long as the runner lived. The signal is the bundle on disk rather than an
    /// environment variable, because the environment belongs to whoever launched
    /// the process.
    nonisolated public static var isInstallable: Bool { HostProcess.isAppBundle }

    /// The order of these guards is the load-bearing part.
    ///
    /// `isInstallable` is checked *before* the handler is installed and before
    /// Carbon is asked for anything, so on a machine running the test suite the
    /// failure carries `noBundleReason` and no system-wide combination is ever
    /// claimed. `GlobalHotkeyTests` reads that marker back for exactly this
    /// reason: it is the only evidence from outside that the guard ran first.
    private func apply(_ combo: KeyCombo?, enabled: Bool) {
        unregisterHotKey()

        guard let combo else { return publish(.none) }
        guard enabled else { return publish(.off(combo)) }
        guard Self.isInstallable else { return publish(.unavailable(combo, Self.noBundleReason)) }
        guard suspensions == 0 else { return }

        installHandlerIfNeeded()
        guard handlerRef != nil else {
            return publish(.unavailable(combo, Self.handlerReason))
        }

        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: Self.signature, id: Self.hotKeyID)
        let status = RegisterEventHotKey(
            UInt32(combo.keyCode),
            combo.carbonModifiers,
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else {
            return publish(.unavailable(combo, Self.refusedReason(status)))
        }
        hotKeyRef = ref
        publish(.registered(combo))
    }

    private func unregisterHotKey() {
        guard let hotKeyRef else { return }
        UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil
    }

    /// Installed once and left in place for the life of the process. Removing
    /// and re-installing it around every change is churn on a global event
    /// target, and the handler ignores anything that is not ours by signature.
    private func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // Pressed only. The released event would be a second trip through the
        // WindowServer for something this app has no use for, and hot keys do not
        // auto-repeat, so one press is one open and no debounce is needed.
        InstallEventHandler(GetApplicationEventTarget(), Self.handler, 1, &spec, nil, &handlerRef)
    }

    /// Assigning unconditionally would republish on every `resume`, and the pane
    /// redraws on each one — the same rule `LoginItem.apply` follows.
    private func publish(_ new: GlobalHotkeyState) {
        guard new != state else { return }
        state = new
    }

    // MARK: - Firing

    /// Called from the Carbon handler, on the main thread.
    fileprivate func fire() {
        guard MenuBarPanel.toggle() else {
            didFailToOpen = true
            if let combo = state.combo {
                publish(.unavailable(combo, Self.noPanelReason))
            }
            return
        }
        didFailToOpen = false
    }

    // MARK: - Carbon plumbing

    /// 'AIBR'. Signature plus id is how the handler tells our hot key from
    /// anything else registered against the application event target — a
    /// framework loaded into this process may register its own.
    fileprivate static let signature: OSType = 0x41494252
    fileprivate static let hotKeyID: UInt32 = 1

    /// A C function pointer, so it captures nothing; the singleton is reached
    /// through a static. Carbon dispatches hot key events on the application
    /// event target's run loop, which is the main one — the same fact that lets
    /// the app delegate use `MainActor.assumeIsolated`.
    private static let handler: EventHandlerUPP = { _, event, _ in
        var id = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &id
        )
        guard status == noErr,
              id.signature == GlobalHotkey.signature,
              id.id == GlobalHotkey.hotKeyID
        else { return OSStatus(eventNotHandledErr) }

        MainActor.assumeIsolated { GlobalHotkey.shared.fire() }
        return noErr
    }

    // MARK: - Reasons

    private static let noBundleReason =
        "aibars isn't running from an app bundle, so macOS won't give it a keyboard shortcut."

    private static let handlerReason =
        "macOS wouldn't let aibars listen for keyboard shortcuts. Quit and reopen aibars."

    private static let noPanelReason =
        "The shortcut worked, but aibars couldn't find its own menu bar item to open. Quit and reopen aibars."

    private static func refusedReason(_ status: OSStatus) -> String {
        // -9878 is `eventHotKeyExistsErr`, which means *this application* already
        // holds the combination — it is not the answer to "does another app own
        // it", and the sentence must not claim it is. Named rather than numeric
        // at the comparison and numeric in the sentence: the user cannot look up
        // `eventHotKeyExistsErr`, and a support thread can look up -9878.
        if status == OSStatus(eventHotKeyExistsErr) {
            return "aibars already holds that combination. Quit and reopen aibars, then set it again."
        }
        return "macOS refused that combination (error \(status)). Try a different one."
    }
}
