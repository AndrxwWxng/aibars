import Foundation
import SwiftUI

/// A pluggable source of usage data.
///
/// Each provider is responsible for obtaining its own auth credentials
/// (cookies, session tokens, API keys) and calling the upstream API to
/// surface current usage. Providers are stateless beyond their config.
public protocol UsageProvider: AnyObject, Identifiable {
    var id: String { get }
    var displayName: String { get }
    var iconName: String { get }
    var accentColor: Color { get }
    var isEnabled: Bool { get set }
    var isAuthenticated: Bool { get }
    /// Where to send the user to log in. `nil` means the provider has no
    /// hosted login page and falls back to manual token entry.
    var webLogin: WebLoginConfig? { get }
    /// The page a user would go to to see this usage themselves. Opened when
    /// they click through a connected row.
    var dashboardURL: URL? { get }
    func fetchUsage() async throws -> UsageData
    func authenticate() async throws
    func signOut() async throws
    /// Enable or disable the provider. Part of the protocol so the type-erased
    /// wrapper reaches the implementation that persists the choice, rather than
    /// assigning `isEnabled` and silently skipping the UserDefaults write.
    func setEnabled(_ enabled: Bool)
}

public extension UsageProvider {
    var webLogin: WebLoginConfig? { nil }
    var dashboardURL: URL? { nil }

    /// Providers that don't persist the flag get the in-memory behaviour.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }
}
