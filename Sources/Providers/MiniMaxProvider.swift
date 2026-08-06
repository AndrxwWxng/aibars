import Foundation
import SwiftUI

/// Generic provider for services that expose a JSON usage endpoint.
///
/// Users configure a URL, optional headers, and a JSONPath expression
/// for the primary usage number. See README → Adding a Provider.
public final class MiniMaxProvider: ObservableObject, UsageProvider {
    public let id = "minimax"
    public let displayName = "MiniMax"
    public let iconName = "hexagon.fill"
    public let accentColor: Color = Color(red: 0.45, green: 0.30, blue: 0.85)

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false

    private let userDefaults = UserDefaults.standard
    private let enabledKey = "aibars.minimax.enabled"
    private let endpointKey = "aibars.minimax.endpoint"
    private let tokenKey = "aibars.minimax.token"
    private let planNameKey = "aibars.minimax.planName"

    public init() {
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = SessionStore.shared.hasCredential(for: "minimax")
    }

    public func fetchUsage() async throws -> UsageData {
        guard let endpoint = userDefaults.string(forKey: endpointKey),
              let url = URL(string: endpoint) else {
            throw ProviderError.configuration("Set a usage endpoint in Settings → MiniMax.")
        }
        guard let token = SessionStore.shared.token(for: "minimax") else {
            throw ProviderError.notAuthenticated
        }

        let (data, _) = try await ProviderHTTP(headers: [
            "Authorization": "Bearer \(token)"
        ]).get(url)
        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return MiniMaxUsageParser.parse(raw, planName: userDefaults.string(forKey: planNameKey))
    }

    public func authenticate() async throws {
        if SessionStore.shared.hasCredential(for: "minimax") {
            await MainActor.run { self.isAuthenticated = true }
        }
    }

    public func signOut() async throws {
        SessionStore.shared.clear("minimax")
        await MainActor.run { self.isAuthenticated = false }
    }

    public func saveTokenManually(_ token: String) throws {
        try SessionStore.shared.setToken(token, for: "minimax", source: .manualPaste)
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
        let (used, limit, reset, label) = firstMetric(in: raw)
        let primary = UsageMetric(
            label: label,
            used: used,
            limit: limit,
            unit: "%",
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

    private static func firstMetric(in raw: [String: Any]) -> (Double, Double, Date?, String) {
        if let u = ProviderNumber.coerce(raw["used"]), let l = ProviderNumber.coerce(raw["limit"]) {
            let r = (raw["reset_at"] as? String).flatMap { ProviderDate.parse($0) }
            return (u, l, r, "Used")
        }
        if let usage = raw["usage"] as? [String: Any], let primary = usage["primary"] as? [String: Any] {
            let used = ProviderNumber.coerce(primary["used"]) ?? 0
            let limit = ProviderNumber.coerce(primary["limit"]) ?? 0
            let reset = (primary["reset_at"] as? String).flatMap { ProviderDate.parse($0) }
            return (used, limit, reset, "Primary")
        }
        if let data = raw["data"] as? [String: Any] {
            for (label, value) in data {
                guard let dict = value as? [String: Any] else { continue }
                let used = ProviderNumber.coerce(dict["used"]) ?? 0
                let limit = ProviderNumber.coerce(dict["limit"]) ?? 0
                if limit > 0 {
                    let reset = (dict["reset_at"] as? String).flatMap { ProviderDate.parse($0) }
                    return (used, limit, reset, label)
                }
            }
        }
        return (0, 0, nil, "Usage")
    }
}
