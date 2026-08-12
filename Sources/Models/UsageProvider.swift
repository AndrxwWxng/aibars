import Foundation
import SwiftUI

/// A pluggable source of usage data.
///
/// Each provider is responsible for obtaining its own auth credentials
/// (cookies, session tokens, API keys) and calling the upstream API to
/// surface current usage. Providers are stateless beyond their config.
public protocol UsageProvider: AnyObject, Identifiable {
    /// Unique per account: "claude" for the only one, "claude#2" for a second.
    var id: String { get }
    /// The service family, shared by every account of it. Logos and labels key
    /// off this; storage and identity key off `id`.
    var serviceID: String { get }
    /// Which account, when a service is signed into more than once.
    var accountID: String? { get }
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
    /// Store a credential. `source` decides whether it is persisted at all —
    /// browser sessions are re-derived, so they stay in memory.
    func saveTokenManually(_ token: String, source: SessionSource) throws
}

public extension UsageProvider {
    var serviceID: String { id }

    /// The brand colour, for the one ramp that asks for it.
    ///
    /// Sixteen providers each wrote this out as a `Color(red:green:blue:)`
    /// literal, and sixteen hand-written opinions disagreed with
    /// `BrandMark.hex` by up to 98° of hue — ChatGPT's was green, Gemini's and
    /// Z.ai's were both Google blue, Grok's was slate. `ColorRamp.provider`
    /// painted meters and figures from them, so Copilot's meter drew at 1.08:1
    /// on a dark panel and Claude's percentage at 3.04:1 on a light one.
    ///
    /// One lookup now, against the one table, pre-banded to a lightness that is
    /// legible as text in both appearances. A service with no published mark
    /// falls back to the user's own accent colour rather than to a literal
    /// somebody invented for it.
    var accentColor: Color {
        BrandMark.mark(for: serviceID)?.brandInk ?? .accentColor
    }
    var accountID: String? { nil }
    var webLogin: WebLoginConfig? { nil }
    var dashboardURL: URL? { nil }

    /// Providers that don't persist the flag get the in-memory behaviour.
    func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
    }
}
