import Foundation
import SwiftUI

/// A pluggable source of usage data.
///
/// Each provider is responsible for obtaining its own auth credentials
/// (cookies, session tokens, API keys) and calling the upstream API to
/// surface current usage. Providers are stateless beyond their config.
public protocol UsageProvider: AnyObject, Identifiable {
    /// Stable identifier used in settings and storage. e.g. `"claude"`.
    var id: String { get }

    /// Human-readable name shown in the menu bar dropdown.
    var displayName: String { get }

    /// SF Symbol name used in the menu bar list.
    var iconName: String { get }

    /// Accent color for the row.
    var accentColor: Color { get }

    /// Whether the user has enabled this provider.
    var isEnabled: Bool { get set }

    /// Whether this provider is currently authenticated.
    var isAuthenticated: Bool { get }

    /// Fetch the latest usage. Implementations are responsible for caching
    /// their own state between calls.
    func fetchUsage() async throws -> UsageData

    /// Begin the auth flow. Called when the user clicks "Sign in".
    func authenticate() async throws

    /// Sign out and clear any stored credentials.
    func signOut() async throws
}
