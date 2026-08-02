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
    func fetchUsage() async throws -> UsageData
    func authenticate() async throws
    func signOut() async throws
}
