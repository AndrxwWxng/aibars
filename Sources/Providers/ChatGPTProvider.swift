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
        self.isAuthenticated = SessionStore.shared.hasCredential(for: "chatgpt")
    }

    public var dashboardURL: URL? { URL(string: "https://chatgpt.com/#settings") }

    public var webLogin: WebLoginConfig? {
        WebLoginConfig(
            startURL: URL(string: "https://chatgpt.com/auth/login")!,
            capture: .cookie(name: cookieName, domainSuffix: "chatgpt.com"),
            hint: "Log in as usual — aibars picks up the session automatically.",
            dataDomains: ["chatgpt.com", "openai.com", "auth.openai.com"]
        )
    }

    /// Two legs, because `/backend-api` does not accept the session cookie.
    ///
    /// `/backend-api/usage` answered 404 for a signed-in Plus account: the web
    /// app first exchanges its cookie for a short-lived bearer token at
    /// `/api/auth/session`, then sends that as `Authorization` to
    /// `/backend-api/*`. The cookie alone reaches nothing.
    ///
    /// Which endpoint carries the message allowance has also moved more than
    /// once, so a few candidates are tried in order and the first recognisable
    /// shape wins. All of this is undocumented and may break again.
    public func fetchUsage() async throws -> UsageData {
        guard let token = session.token(for: "chatgpt") else {
            throw ProviderError.notAuthenticated
        }

        let accessToken = try await accessToken(sessionToken: token)
        let http = ProviderHTTP(headers: [
            "Authorization": "Bearer \(accessToken)",
            "Origin": "https://chatgpt.com",
            "Referer": "https://chatgpt.com/",
            "User-Agent": Self.browserUserAgent
        ])

        var lastError: ProviderError = .parse("No ChatGPT usage endpoint answered")
        for path in Self.usagePaths {
            guard let url = URL(string: "https://chatgpt.com\(path)") else { continue }
            do {
                let (data, _) = try await http.get(url)
                guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                    lastError = .parse("\(path) returned \(data.count) bytes that are not a JSON object")
                    continue
                }
                let usage = ChatGPTUsageParser.parse(raw)
                // A shape with no recognisable allowance is not worth reporting
                // as success; try the next candidate.
                if usage.primary.limit > 0 || !usage.secondary.isEmpty {
                    await MainActor.run { self.lastError = nil }
                    return usage
                }
                lastError = .parse("\(path) had no recognisable message allowance")
            } catch let error as ProviderError {
                if error.isAuth {
                    await MainActor.run { self.isAuthenticated = false }
                    throw error
                }
                lastError = error
            }
        }
        await MainActor.run { self.lastError = lastError }
        throw lastError
    }

    /// The web app's own cookie-for-token exchange.
    private func accessToken(sessionToken: String) async throws -> String {
        let url = URL(string: "https://chatgpt.com/api/auth/session")!
        let (data, _) = try await ProviderHTTP(headers: [
            "Cookie": "\(cookieName)=\(sessionToken)",
            "Referer": "https://chatgpt.com/",
            "User-Agent": Self.browserUserAgent
        ]).get(url)

        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderError.parse("Session endpoint did not return JSON")
        }
        guard let accessToken = raw["accessToken"] as? String, !accessToken.isEmpty else {
            // An expired cookie gets an empty object rather than an error.
            throw ProviderError.sessionExpired
        }
        return accessToken
    }

    /// Tried in order. The first two are where the allowance has lived most
    /// recently; `/models` is the fallback that at least confirms the session.
    private static let usagePaths = [
        "/backend-api/conversation_limit",
        "/backend-api/accounts/check/v4-2023-04-27",
        "/backend-api/models"
    ]

    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

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

    public func saveTokenManually(_ token: String, source: SessionSource = .manualPaste) throws {
        try session.setToken(token, for: "chatgpt", source: source)
        Task { @MainActor in self.isAuthenticated = true }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: enabledKey)
    }
}

public enum ChatGPTUsageParser {
    public static func parse(_ raw: [String: Any]) -> UsageData {
        // Known shape: { "total_usage": { "messages": ... }, "plan": ..., "rate_limits": { ... } }
        let totalUsage = raw["total_usage"] as? [String: Any] ?? [:]
        let planName = (raw["account_plan"] as? String) ?? (raw["plan"] as? String) ?? "Plus"
        let rateLimits = raw["rate_limits"] as? [String: Any] ?? [:]

        let messageCount = ProviderNumber.coerce(totalUsage["num_messages"])
            ?? ProviderNumber.coerce(totalUsage["messages"])
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
            let used = ProviderNumber.coerce(primaryBucket["used"]) ?? 0
            let limit = ProviderNumber.coerce(primaryBucket["limit"]) ?? 0
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
