import Foundation
import SwiftUI

/// Provider for services with no hosted login page: the user pastes a bearer
/// token and tells aibars which JSON usage endpoint to poll (Settings →
/// Services → Connect). The request always sends `Authorization: Bearer
/// <token>`; the response is matched against the fixed shapes documented on
/// `MiniMaxUsageParser`. The plan name is fixed to "API" by the connect flow.
public final class MiniMaxProvider: ObservableObject, UsageProvider {
    public let id: String
    /// The account this instance follows, when a service is signed into more
    /// than once. Nil is the only-account case.
    public let accountID: String?
    public var serviceID: String { "minimax" }
    public let displayName = "MiniMax"
    public let iconName = "hexagon.fill"
    public let accentColor: Color = Color(red: 0.45, green: 0.30, blue: 0.85)

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false

    private let userDefaults = UserDefaults.standard
    private let enabledKey: String
    private let endpointKey = "aibars.minimax.endpoint"
    private let tokenKey = "aibars.minimax.token"
    private let planNameKey = "aibars.minimax.planName"

    public init(accountID: String? = nil) {
        self.accountID = accountID
        self.id = accountID.map { "minimax#\($0)" } ?? "minimax"
        self.enabledKey = "aibars.\(self.id).enabled"
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = SessionStore.shared.hasCredential(for: id)
    }

    public func fetchUsage() async throws -> UsageData {
        guard let endpoint = userDefaults.string(forKey: endpointKey),
              let url = URL(string: endpoint) else {
            throw ProviderError.configuration("Set a usage endpoint in Settings → Services.")
        }
        guard let token = SessionStore.shared.token(for: id) else {
            throw ProviderError.notAuthenticated
        }

        let (data, _) = try await ProviderHTTP(headers: [
            "Authorization": "Bearer \(token)"
        ]).get(url)
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return MiniMaxUsageParser.parse(raw, planName: userDefaults.string(forKey: planNameKey))
    }

    public func authenticate() async throws {
        if SessionStore.shared.hasCredential(for: id) {
            await MainActor.run { self.isAuthenticated = true }
        }
    }

    public func signOut() async throws {
        SessionStore.shared.clear(id)
        await MainActor.run { self.isAuthenticated = false }
    }

    public func saveTokenManually(_ token: String, source: SessionSource = .manualPaste) throws {
        try SessionStore.shared.setToken(token, for: id, source: source)
        Task { @MainActor in self.isAuthenticated = true }
    }

    public func configure(endpoint: String, planName: String) {
        userDefaults.set(endpoint, forKey: endpointKey)
        userDefaults.set(planName, forKey: planNameKey)
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: enabledKey)
    }

    public var configuredEndpoint: String? { userDefaults.string(forKey: endpointKey) }
}

public enum MiniMaxUsageParser {
    /// Tries a small set of well-known shapes:
    ///   { "used": n, "limit": m, "reset_at": "..." }
    ///   { "usage": { "primary": { "used": n, "limit": m } } }
    ///   { "data": { "messages": { "used": n, "limit": m } } }
    public static func parse(_ raw: [String: Any], planName: String?) -> UsageData {
        let (used, limit, reset, label, unit) = firstMetric(in: raw)
        let primary = UsageMetric(
            label: label,
            used: used,
            limit: limit,
            unit: unit,
            resetDate: reset
        )
        return UsageData(
            providerID: "minimax",
            planName: planName ?? "API",
            primary: primary,
            secondary: [],
            rawJSON: try? JSONSerialization.data(withJSONObject: raw).base64EncodedString()
        )
    }

    /// The trailing element is the unit `used` is counted in — nil unless the
    /// response names it, which only the nested `data` shape does. Never "%":
    /// every shape here reports a count, and the UI reads "%" as "`used` is
    /// already the percentage" and hides the figures.
    private static func firstMetric(in raw: [String: Any]) -> (Double, Double, Date?, String, String?) {
        if let u = ProviderNumber.coerce(raw["used"]), let l = ProviderNumber.coerce(raw["limit"]) {
            let r = (raw["reset_at"] as? String).flatMap { ProviderDate.parse($0) }
            return (u, l, r, "Used", nil)
        }
        if let usage = raw["usage"] as? [String: Any], let primary = usage["primary"] as? [String: Any] {
            let used = ProviderNumber.coerce(primary["used"]) ?? 0
            let limit = ProviderNumber.coerce(primary["limit"]) ?? 0
            let reset = (primary["reset_at"] as? String).flatMap { ProviderDate.parse($0) }
            return (used, limit, reset, "Primary", nil)
        }
        if let data = raw["data"] as? [String: Any] {
            for (label, value) in data {
                guard let dict = value as? [String: Any] else { continue }
                let used = ProviderNumber.coerce(dict["used"]) ?? 0
                let limit = ProviderNumber.coerce(dict["limit"]) ?? 0
                if limit > 0 {
                    let reset = (dict["reset_at"] as? String).flatMap { ProviderDate.parse($0) }
                    return (used, limit, reset, label, label)
                }
            }
        }
        return (0, 0, nil, "Usage", nil)
    }
}
