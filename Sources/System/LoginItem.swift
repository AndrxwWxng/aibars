import Foundation
import ServiceManagement

/// What macOS currently says about launching aibars at login.
///
/// The three unhappy cases are kept apart because the remedy differs: approval
/// is a switch the user flicks in System Settings, unavailability is something
/// they fix by moving the app, and a toggle that silently springs back is worth
/// neither.
public enum LoginItemState: Equatable, Sendable {
    case enabled
    case disabled
    /// Registered, but macOS wants the user to confirm it in Login Items.
    case requiresApproval
    /// macOS will not register this copy of the app. Carries the reason.
    case unavailable(String)

    /// Where the toggle should sit. `requiresApproval` counts as on: the
    /// registration exists, it just isn't approved yet, and unticking it would
    /// hide the one thing the user has to act on.
    public var isOn: Bool {
        switch self {
        case .enabled, .requiresApproval: return true
        case .disabled, .unavailable:     return false
        }
    }

    /// A line to show under the toggle, or nil when there is nothing to say.
    public var note: String? {
        switch self {
        case .enabled, .disabled:
            return nil
        case .requiresApproval:
            return "Approve aibars in System Settings → General → Login Items."
        case .unavailable(let reason):
            return reason
        }
    }
}

/// Launch at login, over `SMAppService.mainApp`.
///
/// The interesting part is not registering — it is that registering routinely
/// fails. A build run out of DerivedData, or an app still sitting in Downloads,
/// makes `register()` throw `SMAppServiceErrorDomain 1`, and a toggle that
/// reported success on the strength of "no error was thrown a moment ago" would
/// leave the user with a ticked switch that unticks itself at the next launch.
///
/// So `setEnabled` never throws and never trusts its own request: it asks, then
/// re-reads `status` and publishes whatever the system actually did.
@MainActor
public final class LoginItem: ObservableObject {
    /// The app's single instance. Shared because the app delegate reads it at
    /// launch while the settings pane, built later, has to observe the same
    /// object.
    public static let shared = LoginItem()

    @Published public private(set) var state: LoginItemState = .disabled

    public init() {
        refresh()
    }

    /// Re-reads the system's view. Worth calling when the settings window opens
    /// or the app is reactivated, since the user can change login items behind
    /// the app's back.
    public func refresh() {
        apply(Self.currentState())
    }

    /// Asks macOS to add or remove the login item, then reports what is true
    /// afterwards — which is not always what was asked for.
    @discardableResult
    public func setEnabled(_ enabled: Bool) -> LoginItemState {
        guard Self.isHostedInApp else {
            apply(.unavailable(Self.noBundleReason))
            return state
        }

        let service = SMAppService.mainApp
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            // Deliberately swallowed. The thrown error says less than the status
            // read below does: unregistering something that was never registered
            // throws, and a failed register can still leave the item awaiting
            // approval.
        }

        var result = Self.currentState()
        // Asked for on, did not get on: name the reason rather than let the
        // switch quietly slide back.
        if enabled, case .disabled = result {
            result = .unavailable(Self.refusedReason)
        }
        apply(result)
        return state
    }

    /// Whether there is a real `.app` around `Bundle.main` for launchd to
    /// launch.
    ///
    /// False under `xctest` and in any command line context, and everything here
    /// short-circuits on it: `SMAppService.mainApp` would otherwise happily
    /// register the test runner as the user's login item, which survives the
    /// test run.
    ///
    /// The signal is the bundle on disk rather than an environment variable,
    /// because the environment belongs to whoever launched the process and a
    /// real user's login item must not be switchable off by an exported
    /// variable.
    nonisolated public static var isHostedInApp: Bool { hostedInApp }

    /// Opens System Settings → General → Login Items, the destination for both
    /// the approval case and the manual fallback.
    public static func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    // MARK: - Internals

    private nonisolated static let hostedInApp: Bool = {
        let bundle = Bundle.main
        return bundle.bundleURL.pathExtension == "app" && bundle.bundleIdentifier != nil
    }()

    private nonisolated static let noBundleReason =
        "aibars isn't running from an app bundle, so there is nothing for macOS to launch."

    private nonisolated static let refusedReason =
        "macOS refused to add aibars to login items. Run aibars from /Applications, or add it by hand in System Settings → General → Login Items."

    private nonisolated static let missingReason =
        "macOS can't find this copy of aibars. Run aibars from /Applications, or add it by hand in System Settings → General → Login Items."

    private static func currentState() -> LoginItemState {
        guard isHostedInApp else { return .unavailable(noBundleReason) }
        switch SMAppService.mainApp.status {
        case .enabled:          return .enabled
        case .requiresApproval: return .requiresApproval
        case .notRegistered:    return .disabled
        case .notFound:         return .unavailable(missingReason)
        // A status this build doesn't know about is not evidence of anything, so
        // it reads as off rather than as a failure the user is asked to fix.
        @unknown default:       return .disabled
        }
    }

    /// Assigning unconditionally would republish on every refresh, and the
    /// settings pane redraws on each one.
    private func apply(_ new: LoginItemState) {
        guard new != state else { return }
        state = new
    }
}
