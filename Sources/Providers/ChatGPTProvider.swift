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

    /// Two legs, because `/backend-api` does not accept the session cookie: the
    /// web app trades it for a short-lived bearer token at `/api/auth/session`
    /// first.
    ///
    /// There is no message allowance to report. `/backend-api/usage`,
    /// `/conversation_limit` and `/rate_limits` are all 404 for a signed-in
    /// account — ChatGPT delivers rate limits inline with conversation
    /// responses rather than exposing them as something you can ask for. So
    /// rather than inventing a number or failing loudly, this reports what the
    /// account genuinely publishes: who is signed in, which plan they are on,
    /// and when it renews.
    public func fetchUsage() async throws -> UsageData {
        guard let token = session.token(for: "chatgpt") else {
            throw ProviderError.notAuthenticated
        }

        let identity = try await identity(sessionToken: token)
        let http = ProviderHTTP(headers: [
            "Authorization": "Bearer \(identity.accessToken)",
            "Origin": "https://chatgpt.com",
            "Referer": "https://chatgpt.com/",
            "User-Agent": Self.browserUserAgent
        ])

        do {
            let url = URL(string: "https://chatgpt.com/backend-api/accounts/check/v4-2023-04-27")!
            let (data, _) = try await http.get(url)
            guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw ProviderError.parse("Account check returned \(data.count) bytes that are not JSON")
            }
            let usage = ChatGPTUsageParser.parse(raw, account: identity.email)
            await MainActor.run { self.lastError = nil }
            return usage
        } catch let error as ProviderError {
            if error.isAuth {
                await MainActor.run { self.isAuthenticated = false }
            }
            await MainActor.run { self.lastError = error }
            throw error
        }
    }

    /// The web app's own cookie-for-token exchange. It also names the signed-in
    /// account, which is the only place that comes from.
    private func identity(sessionToken: String) async throws -> (accessToken: String, email: String?) {
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
        let email = (raw["user"] as? [String: Any])?["email"] as? String
        return (accessToken, email)
    }

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
    /// Reads `/backend-api/accounts/check/v4-2023-04-27`, whose useful part is
    /// the entitlement:
    ///
    ///     entitlement: { has_active_subscription: 0,
    ///                    subscription_plan: "chatgptplusplan",
    ///                    renews_at: null, expires_at: "2025-12-03T…" }
    ///
    /// No message counts appear anywhere in it, so the metric is status-only —
    /// a zero limit, which the row renders as a state rather than a bar. An
    /// invented denominator would be worse than saying nothing.
    public static func parse(_ raw: [String: Any], account: String? = nil) -> UsageData {
        let entitlement = accounts(in: raw)
            .compactMap { $0["entitlement"] as? [String: Any] }
            // Prefer whichever account is actually paying.
            .sorted { isActive($0) && !isActive($1) }
            .first ?? [:]

        let active = isActive(entitlement)
        let plan = (entitlement["subscription_plan"] as? String).map(planName(from:))
        let renewal = ["renews_at", "expires_at", "cancels_at"]
            .compactMap { entitlement[$0] as? String }
            .compactMap { ProviderDate.parse($0) }
            .first

        return UsageData(
            providerID: "chatgpt",
            planName: active ? (plan ?? "Plus") : "Free",
            primary: UsageMetric(
                label: active ? "Subscription active" : "No active subscription",
                used: active ? 1 : 0,
                limit: 0,
                unit: nil,
                resetDate: active ? renewal : nil,
                windowLabel: nil
            ),
            secondary: [],
            accountLabel: account,
            rawJSON: try? JSONSerialization.data(withJSONObject: raw).base64EncodedString()
        )
    }

    private static func accounts(in raw: [String: Any]) -> [[String: Any]] {
        guard let accounts = raw["accounts"] as? [String: Any] else { return [] }
        return accounts.values.compactMap { $0 as? [String: Any] }
    }

    private static func isActive(_ entitlement: [String: Any]) -> Bool {
        if let flag = entitlement["has_active_subscription"] as? Bool { return flag }
        return (ProviderNumber.coerce(entitlement["has_active_subscription"]) ?? 0) > 0
    }

    /// "chatgptplusplan" is not a label anyone should read.
    private static func planName(from identifier: String) -> String {
        switch identifier {
        case "chatgptplusplan": return "Plus"
        case "chatgptproplan": return "Pro"
        case "chatgptteamplan": return "Team"
        case "chatgptenterpriseplan": return "Enterprise"
        default:
            let trimmed = identifier
                .replacingOccurrences(of: "chatgpt", with: "")
                .replacingOccurrences(of: "plan", with: "")
            return trimmed.isEmpty ? identifier : trimmed.capitalized
        }
    }
}
