import Foundation
import SwiftUI

/// Tracks ChatGPT (Plus, Team, Pro) usage via the public usage endpoint.
public final class ChatGPTProvider: ObservableObject, UsageProvider {
    public let id = "chatgpt"
    public let displayName = "ChatGPT"
    public let iconName = "bubble.left.and.bubble.right.fill"
    public let accentColor: Color = Color(red: 0.10, green: 0.55, blue: 0.40)

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var lastError: ProviderError?

    private let cookieName = "__Secure-next-auth.session-token"
    private let session = SessionStore.shared
    private let userDefaults = UserDefaults.standard
    private let enabledKey = "aibars.chatgpt.enabled"

    public init() {
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = SessionStore.shared.token(for: "chatgpt") != nil
    }

    public func fetchUsage() async throws -> UsageData {
        guard let token = session.token(for: "chatgpt") else {
            throw ProviderError.notAuthenticated
        }

        let url = URL(string: "https://chatgpt.com/backend-api/usage")!
        let (data, _) = try await ProviderHTTP(headers: [
            "Cookie": "\(cookieName)=\(token)",
            "Origin": "https://chatgpt.com",
            "Referer": "https://chatgpt.com/"
        ]).get(url)

        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return ChatGPTUsageParser.parse(raw)
    }

    public func authenticate() async throws {
        if let cookie = CookieExtractors.firstAvailableCookie(named: cookieName, for: "chatgpt.com") {
            try session.setToken(cookie.value, for: "chatgpt", source: .browserCookie, accountHint: cookie.source.displayName)
            await MainActor.run { self.isAuthenticated = true }
        }
    }

    public func signOut() async throws {
        session.clear("chatgpt")
        await MainActor.run { self.isAuthenticated = false }
    }

    public func saveTokenManually(_ token: String) throws {
        try session.setToken(token, for: "chatgpt", source: .manualPaste)
        Task { @MainActor in self.isAuthenticated = true }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: enabledKey)
    }
}

enum public ChatGPTUsageParser {
    static func parse(_ raw: [String: Any]) -> UsageData {
        // Known shape: { "total_usage": { "messages": ... }, "plan": ..., "rate_limits": { ... } }
        let totalUsage = raw["total_usage"] as? [String: Any] ?? [:]
        let planName = (raw["account_plan"] as? String) ?? (raw["plan"] as? String) ?? "Plus"
        let rateLimits = raw["rate_limits"] as? [String: Any] ?? [:]

        let messageCount = (totalUsage["num_messages"] as? Double)
            ?? (totalUsage["messages"] as? Double)
            ?? 0

        var primary = UsageMetric(
            label: "Messages",
            used: messageCount,
            limit: 0,
            unit: "msgs",
            windowLabel: "Last 30 days"
        )

        var secondary: [UsageMetric] = []

        // Rate limits are per-window (e.g. 3h, 24h). Each looks like:
        //   { "primary": { "used": 12, "limit": 40, "reset_at": "..." } }
        for (key, value) in rateLimits {
            guard let dict = value as? [String: Any],
                  let primaryBucket = dict["primary"] as? [String: Any] else { continue }
            let used = (primaryBucket["used"] as? Double) ?? 0
            let limit = (primaryBucket["limit"] as? Double) ?? 0
            let reset = (primaryBucket["reset_at"] as? String).flatMap { ProviderDate.parse($0) }
            if limit > 0 {
                let label: String
                switch key {
                case "gpt-3.5": label = "GPT-3.5"
                case "gpt-4": label = "GPT-4"
                case "gpt-4o": label = "GPT-4o"
                case "gpt-5": label = "GPT-5"
                case "o1": label = "o1"
                case "o3": label = "o3"
                default: label = key
                }
                let metric = UsageMetric(
                    label: label,
                    used: used,
                    limit: limit,
                    unit: "msgs",
                    resetDate: reset,
                    windowLabel: "Window"
                )
                if key.contains("gpt-5") || key.contains("o1") || key.contains("o3") {
                    primary = metric
                } else {
                    secondary.append(metric)
                }
            }
        }

        return UsageData(
            providerID: "chatgpt",
            planName: planName,
            primary: primary,
            secondary: secondary,
            rawJSON: try? JSONSerialization.data(withJSONObject: raw).base64EncodedString()
        )
    }
}
