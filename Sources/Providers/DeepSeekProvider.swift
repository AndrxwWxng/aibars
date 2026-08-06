import Foundation
import SwiftUI

/// Tracks the prepaid balance on a DeepSeek platform account.
///
/// Auth: a platform API key, pasted by the user. Cookies are deliberately not
/// used — DeepSeek's own web surfaces authenticate with a JWT kept in
/// localStorage (`userToken`) and reject the `ds_session_id` / `aws-waf-token`
/// cookies on their own, so the browser cookie extractors cannot serve this
/// provider. An embedded login would yield cookies, not the key.
///
/// DeepSeek is pay-as-you-go: no subscription tier, no monthly quota, and no
/// published per-user rate limit, so there is no used/limit pair to render.
/// What it does expose is the remaining balance, which this provider reports as
/// a status-only figure.
public final class DeepSeekProvider: ObservableObject, UsageProvider {
    public let id = "deepseek"
    public let displayName = "DeepSeek"
    public let iconName = "water.waves"
    public let accentColor: Color = Color(red: 0.30, green: 0.42, blue: 1.00)

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false

    private let session = SessionStore.shared
    private let userDefaults = UserDefaults.standard
    private let enabledKey = "aibars.deepseek.enabled"

    /// The documented balance endpoint.
    private let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!
    /// Guess, not documentation: `/v1` is DeepSeek's OpenAI-SDK compatibility
    /// prefix, so the same handler is likely mounted under it. Only tried when
    /// the unprefixed path fails at the transport level.
    private let compatBalanceURL = URL(string: "https://api.deepseek.com/v1/user/balance")!

    public init() {
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = SessionStore.shared.hasCredential(for: "deepseek")
    }

    public var dashboardURL: URL? { URL(string: "https://platform.deepseek.com/usage") }

    public var webLogin: WebLoginConfig? {
        WebLoginConfig(
            startURL: URL(string: "https://platform.deepseek.com/api_keys")!,
            capture: .tokenShownOnPage,
            hint: "Click “Create new API key”, copy it, then paste it below — the key is only shown once.",
            dataDomains: ["platform.deepseek.com", "deepseek.com"]
        )
    }

    public func fetchUsage() async throws -> UsageData {
        guard let token = session.token(for: "deepseek") else {
            throw ProviderError.notAuthenticated
        }

        let http = ProviderHTTP(headers: ["Authorization": "Bearer \(token)"])

        do {
            let payload = try await balancePayload(from: http)
            let raw = try JSONSerialization.jsonObject(with: payload) as? [String: Any] ?? [:]
            return try DeepSeekUsageParser.parse(raw)
        } catch let error as ProviderError {
            // A revoked or mistyped key has to drop the flag, or the row keeps
            // claiming it is connected and never offers to paste a new key.
            if case .sessionExpired = error {
                await MainActor.run { self.isAuthenticated = false }
            }
            throw error
        }
    }

    /// One retry against the `/v1` alias, and only after a transport-level
    /// failure. A rejected key is final, and repeating a 429 straight away just
    /// doubles the rate the endpoint is already refusing.
    private func balancePayload(from http: ProviderHTTP) async throws -> Data {
        do {
            let (payload, _) = try await http.get(balanceURL)
            return payload
        } catch ProviderError.network {
            let (payload, _) = try await http.get(compatBalanceURL)
            return payload
        }
    }

    public func authenticate() async throws {
        if session.token(for: "deepseek") != nil {
            await MainActor.run { self.isAuthenticated = true }
        }
    }

    public func signOut() async throws {
        session.clear("deepseek")
        await MainActor.run { self.isAuthenticated = false }
    }

    public func saveTokenManually(_ token: String) throws {
        try session.setToken(token, for: "deepseek", source: .apiKey)
        Task { @MainActor in self.isAuthenticated = true }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: enabledKey)
    }
}

public enum DeepSeekUsageParser {
    private static let totalBalanceKeys = ["total_balance", "totalBalance", "balance", "total"]

    /// Documented shape:
    ///   { "is_available": true,
    ///     "balance_infos": [{ "currency": "USD", "total_balance": "110.00",
    ///                         "granted_balance": "10.00",
    ///                         "topped_up_balance": "100.00" }] }
    /// All money values arrive as strings. Multi-currency accounts return more
    /// than one entry; USD wins, otherwise the first entry.
    public static func parse(_ raw: [String: Any]) throws -> UsageData {
        let root = (raw["data"] as? [String: Any]) ?? raw
        let entries = balanceEntries(in: root)

        guard let entry = preferredEntry(in: entries) else {
            throw ProviderError.parse("No balance_infos entry in DeepSeek response")
        }

        let currency = (firstString(entry, "currency", "Currency", "currency_code", "currencyCode") ?? "USD").uppercased()
        let granted = money(entry, ["granted_balance", "grantedBalance", "granted"])
        let toppedUp = money(entry, ["topped_up_balance", "toppedUpBalance", "topped_up", "toppedUp"])

        // total_balance is documented as granted + topped_up; recompute it if the
        // field is missing rather than reporting a zero balance.
        let parts = [granted, toppedUp].compactMap { $0 }
        let total = money(entry, totalBalanceKeys)
            ?? (parts.isEmpty ? nil : parts.reduce(0, +))

        guard let total else {
            throw ProviderError.parse("No balance figure in DeepSeek response for \(currency)")
        }

        let available = firstBool(root, "is_available", "isAvailable", "available") ?? (total > 0)

        // Prepaid credit has no ceiling to measure against, so limit stays 0:
        // that marks the metric status-only and keeps a healthy balance from
        // rendering as 100% consumed.
        let primary = UsageMetric(
            label: available ? "Balance" : "Balance (exhausted)",
            used: total,
            limit: 0,
            unit: currency,
            resetDate: nil,
            windowLabel: nil
        )

        var secondary: [UsageMetric] = []
        if let granted {
            secondary.append(UsageMetric(label: "Granted", used: granted, limit: 0, unit: currency))
        }
        if let toppedUp {
            secondary.append(UsageMetric(label: "Topped up", used: toppedUp, limit: 0, unit: currency))
        }

        return UsageData(
            providerID: "deepseek",
            planName: "Pay-as-you-go",
            primary: primary,
            secondary: secondary,
            rawJSON: try? JSONSerialization.data(withJSONObject: raw).base64EncodedString()
        )
    }

    private static func balanceEntries(in root: [String: Any]) -> [[String: Any]] {
        for key in ["balance_infos", "balanceInfos", "balance_info", "balanceInfo", "balances"] {
            if let list = root[key] as? [[String: Any]] { return list }
            if let single = root[key] as? [String: Any] { return [single] }
        }
        // Some accounts might one day report a flat single-currency payload.
        // Kept in step with the keys `money` is asked for below.
        if totalBalanceKeys.contains(where: { root[$0] != nil }) { return [root] }
        return []
    }

    private static func preferredEntry(in entries: [[String: Any]]) -> [String: Any]? {
        let usd = entries.first { entry in
            (firstString(entry, "currency", "Currency", "currency_code", "currencyCode") ?? "").uppercased() == "USD"
        }
        return usd ?? entries.first
    }

    private static func firstString(_ dict: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func firstBool(_ dict: [String: Any], _ keys: String...) -> Bool? {
        for key in keys {
            if let value = dict[key] as? Bool { return value }
            if let value = dict[key] as? NSNumber { return value.boolValue }
            if let value = dict[key] as? String {
                switch value.lowercased() {
                case "true", "1", "yes": return true
                case "false", "0", "no": return false
                default: continue
                }
            }
        }
        return nil
    }

    private static func money(_ dict: [String: Any], _ keys: [String]) -> Double? {
        for key in keys {
            if let value = ProviderNumber.coerce(dict[key]) { return value }
            // Guard against a localised or symbol-prefixed string sneaking in.
            if let text = dict[key] as? String {
                let cleaned = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
                if let value = Double(cleaned) { return value }
            }
        }
        return nil
    }
}
