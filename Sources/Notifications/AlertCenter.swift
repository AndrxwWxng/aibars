import Foundation
import AppKit
import UserNotifications

/// Whether macOS will actually carry an alert for us.
///
/// Four states rather than a Bool, because "we have not asked yet" and "the
/// system will not serve this build at all" lead to completely different lines
/// in the settings pane, and neither of them is a refusal by the user.
public enum AlertPermission: Equatable, Sendable {
    case unknown
    /// No app bundle to hang a notification off — an xctest run, or a binary
    /// launched outside a `.app`.
    case unavailable
    case denied
    case granted

    /// One line for the pane, or nothing when there is nothing to explain.
    /// Both failure states end the same way on purpose: the in-app log is the
    /// fallback surface, and the user should know it is there before they go
    /// looking for a banner that is never coming.
    public var explanation: String? {
        switch self {
        case .unknown, .granted:
            return nil
        case .unavailable:
            return "macOS will not deliver notifications for this build. Alerts are still listed below."
        case .denied:
            return "Notifications are turned off for aibars in System Settings. Alerts are still listed below."
        }
    }
}

/// Delivery, permission and persistence for threshold alerts. The only place in
/// the app that touches UserNotifications.
///
/// This app is ad-hoc signed and un-notarised, so `UNUserNotificationCenter`
/// refusing to serve it is the ordinary case, not the edge case. Three defences,
/// in the order they matter:
///
/// 1. `UNUserNotificationCenter.current()` is never reached unless the process
///    is running from a real `.app`. From a test bundle that call raises an
///    Objective-C exception about a missing bundle proxy, which Swift cannot
///    catch, and it would take the whole suite down with it. Under tests the
///    permission stays `.unavailable` and every other part of this class —
///    the policy, the state, the log — still runs.
/// 2. Authorisation is requested exactly once, at the moment the user turns
///    alerts on, never at launch. A refusal is recorded and never revisited;
///    the pane says so and offers the settings pane instead of asking again.
/// 3. Every alert is appended to a short in-app log whether or not it was
///    delivered. When macOS silently drops a banner the feature still has a
///    visible surface, and the user can see for themselves that it is working.
///
/// Nothing here throws. `consider` is called from the refresh loop, and a
/// notification that failed to post is not a reason to fail a poll.
@MainActor
public final class AlertCenter: ObservableObject {
    /// Shared because the refresh loop and the settings pane have to agree
    /// about permission and about the log; the initialiser stays public so
    /// tests get a scratch domain and a fixed clock.
    public static let shared = AlertCenter()

    // MARK: - Published state

    /// Written back to the store on every change, so the pane can bind straight
    /// to it without a save button.
    @Published public var rules: ThresholdRules {
        didSet {
            guard rules != oldValue else { return }
            persist(rules, .rules)
        }
    }

    @Published public private(set) var permission: AlertPermission

    /// The last few alerts the policy produced, newest first. Short on purpose:
    /// this is evidence that the feature is alive, not a history anyone scrolls.
    @Published public private(set) var recent: [PendingAlert] = []

    // MARK: - Lifecycle

    public init(store: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        self.rules = Self.decode(ThresholdRules.self, from: store, .rules) ?? .default
        self.state = Self.decode(ThresholdState.self, from: store, .state) ?? ThresholdState()
        self.permission = Self.isHostedInApp ? .unknown : .unavailable
    }

    // MARK: - Environment

    /// Whether this process can safely talk to the notification centre.
    ///
    /// Both halves are load-bearing. A bundle identifier alone is not enough —
    /// an xctest bundle has one — and it is the missing `.app` wrapper that
    /// makes `current()` throw an uncatchable exception.
    public static var isHostedInApp: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    // MARK: - Permission

    /// Called when the user turns alerts on, and again at launch when they are
    /// already on. Asks at most once in the lifetime of the install; every later
    /// call only reads back what the system already decided, which never
    /// prompts.
    public func primeIfNeeded() async {
        guard rules.isEnabled else { return }
        guard Self.isHostedInApp else {
            permission = .unavailable
            return
        }

        let center = UNUserNotificationCenter.current()
        guard !store.bool(forKey: Key.didAsk.rawValue) else {
            permission = await Self.status(of: center)
            return
        }

        // Recorded before the prompt rather than after it. If the app is killed
        // while the panel is up, the user has still been asked, and asking a
        // second time is the nagging this whole class is written to avoid.
        store.set(true, forKey: Key.didAsk.rawValue)

        do {
            // Alerts only. A quota crossing is worth a banner and is not worth
            // a noise in a meeting, and asking for sound we never play would
            // put a permission in the list that we do not use.
            let granted = try await center.requestAuthorization(options: [.alert])
            permission = granted ? .granted : .denied
        } catch {
            // The system declines to even present the prompt for some
            // unnotarised bundles. That is not the user saying no.
            //
            // No prompt appeared, so the user has not in fact been asked, and
            // leaving the flag set would latch this install into a state where
            // the toggle reads on, nothing is ever delivered, and there is no
            // way back. Clearing it lets the next launch try again; a build
            // that macOS will never prompt for simply lands here each time.
            store.set(false, forKey: Key.didAsk.rawValue)
            permission = .unavailable
        }
    }

    /// Opens the notifications pane of System Settings, which is as far as we
    /// can take a user who has already refused: the prompt cannot be shown twice.
    public static func openNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Alerts

    /// Feeds one reading through the policy and posts whatever it earned.
    ///
    /// The policy runs whatever the permission is. Its state has to keep moving
    /// even when nothing can be delivered, or the day notifications start
    /// working every armed window would fire at once.
    public func consider(_ data: UsageData, providerID: String, displayName: String) async {
        await refreshPermissionIfStale()

        let outcome = ThresholdPolicy.evaluate(
            data,
            providerID: providerID,
            displayName: displayName,
            rules: rules,
            state: state,
            now: now()
        )

        // Compared before writing: the common poll changes nothing, and the
        // store should not be touched sixty times an hour to say so.
        if outcome.state != state {
            state = outcome.state
            persist(state, .state)
        }

        for alert in outcome.alerts {
            let delivered = await post(alert)
            record(alert, delivered: delivered)
        }
    }

    /// Whether the log row for this alert reached Notification Centre. Kept off
    /// `PendingAlert` because delivery is this file's business and the policy
    /// has no way of knowing.
    public func wasDelivered(_ alert: PendingAlert) -> Bool {
        deliveries[Self.logID(alert)] ?? false
    }

    /// Drops everything remembered about a provider — its arming and its log
    /// rows — so that signing back in later seeds afresh instead of firing
    /// against a reading from a previous session.
    public func forget(_ providerID: String) {
        let next = ThresholdPolicy.forget(providerID, in: state)
        if next != state {
            state = next
            persist(state, .state)
        }

        let kept = recent.filter { $0.providerID != providerID }
        guard kept.count != recent.count else { return }
        prune(to: kept)
    }

    // MARK: - Delivery

    private func post(_ alert: PendingAlert) async -> Bool {
        guard permission == .granted, Self.isHostedInApp else { return false }

        let content = UNMutableNotificationContent()
        content.title = alert.title
        content.body = alert.body
        // One thread per service, so three crossings on the same account
        // collapse into one stack rather than three separate banners.
        content.threadIdentifier = alert.providerID

        // The policy's key is stable per provider and window, which makes a 95%
        // banner replace the 80% one still sitting in Notification Centre.
        let request = UNNotificationRequest(identifier: alert.key, content: content, trigger: nil)

        do {
            try await UNUserNotificationCenter.current().add(request)
            return true
        } catch {
            // Logged as undelivered and nothing more. The caller is a refresh
            // loop and has no use for the reason.
            return false
        }
    }

    /// Only ever reads; `notificationSettings()` does not prompt. Runs when the
    /// permission is still unknown and the user has already been asked once —
    /// the state after a relaunch, and after they changed their mind in System
    /// Settings.
    private func refreshPermissionIfStale() async {
        guard rules.isEnabled else { return }
        guard Self.isHostedInApp else {
            permission = .unavailable
            return
        }
        guard permission == .unknown, store.bool(forKey: Key.didAsk.rawValue) else { return }
        permission = await Self.status(of: UNUserNotificationCenter.current())
    }

    private static func status(of center: UNUserNotificationCenter) async -> AlertPermission {
        switch await center.notificationSettings().authorizationStatus {
        case .authorized, .provisional:
            return .granted
        case .denied:
            return .denied
        case .notDetermined:
            return .unknown
        @unknown default:
            // A status this build does not recognise is not permission to post.
            return .unknown
        }
    }

    // MARK: - Log

    private func record(_ alert: PendingAlert, delivered: Bool) {
        deliveries[Self.logID(alert)] = delivered
        prune(to: [alert] + recent)
    }

    /// Trims the log to its limit and drops the delivery marks belonging to
    /// rows that fell off the end, so the dictionary cannot grow without bound
    /// over a long-running session.
    private func prune(to rows: [PendingAlert]) {
        let kept = Array(rows.prefix(Self.logLimit))
        let live = Set(kept.map(Self.logID))
        deliveries = deliveries.filter { live.contains($0.key) }
        recent = kept
    }

    /// The key alone is not unique over time — the same window fires at 80% and
    /// again at 95% — so the instant is part of the identity.
    private static func logID(_ alert: PendingAlert) -> String {
        "\(alert.key)@\(alert.at.timeIntervalSinceReferenceDate)"
    }

    private static let logLimit = 5

    // MARK: - Storage

    private enum Key: String {
        case rules = "aibars.alerts.rules"
        case state = "aibars.alerts.state"
        case didAsk = "aibars.alerts.didAsk"
    }

    private let store: UserDefaults
    private let now: () -> Date

    /// The policy's memory. Opaque here by design — this class persists it and
    /// hands it back, and reads nothing out of it.
    private var state: ThresholdState

    /// Delivery marks for the rows in `recent`, keyed by `logID`. Separate from
    /// the log itself so `recent` stays exactly what the policy produced.
    private var deliveries: [String: Bool] = [:]

    private func persist<T: Encodable>(_ value: T, _ key: Key) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        store.set(data, forKey: key.rawValue)
    }

    /// A stored value that no longer decodes is discarded rather than repaired.
    /// For the rules that means the defaults, which are off; for the state it
    /// means every window seeds again on the next poll. Both cost the user at
    /// most a missed alert, which is the right way round.
    private static func decode<T: Decodable>(_ type: T.Type, from store: UserDefaults, _ key: Key) -> T? {
        guard let data = store.data(forKey: key.rawValue) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }
}
