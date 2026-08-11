import Foundation
import SwiftUI

/// Tracks ChatGPT (Plus, Team, Pro) usage via the public usage endpoint.
public final class ChatGPTProvider: ObservableObject, UsageProvider {
    public let id: String
    /// The account this instance follows, when a service is signed into more
    /// than once. Nil is the only-account case.
    public let accountID: String?
    public var serviceID: String { "chatgpt" }
    public let displayName = "ChatGPT"
    public let iconName = "bubble.left.and.bubble.right.fill"
    public let accentColor: Color = Color(red: 0.10, green: 0.55, blue: 0.40)

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var lastError: ProviderError?

    private let session = SessionStore.shared
    private let userDefaults = UserDefaults.standard
    private let enabledKey: String

    public init(accountID: String? = nil) {
        self.accountID = accountID
        self.id = accountID.map { "chatgpt#\($0)" } ?? "chatgpt"
        self.enabledKey = "aibars.\(self.id).enabled"
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = SessionStore.shared.hasCredential(for: id)
    }

    public var dashboardURL: URL? { URL(string: "https://chatgpt.com/#settings") }

    public var webLogin: WebLoginConfig? {
        WebLoginConfig(
            startURL: URL(string: "https://chatgpt.com/auth/login")!,
            capture: .cookie(name: ChatGPTSession.cookieName, domainSuffix: "chatgpt.com"),
            hint: "Log in as usual — aibars picks up the session automatically.",
            dataDomains: ["chatgpt.com", "openai.com", "auth.openai.com"]
        )
    }

    /// Two legs, because `/backend-api` does not accept the session cookie: the
    /// web app trades it for a short-lived bearer token at `/api/auth/session`
    /// first. That exchange lives in `ChatGPTSession` — `CodexProvider` makes
    /// the identical call, and two copies of it would drift the moment the
    /// endpoint or the cookie name moves.
    ///
    /// There is no message allowance to report. `/backend-api/usage`,
    /// `/conversation_limit` and `/rate_limits` are all 404 for a signed-in
    /// account — ChatGPT delivers rate limits inline with conversation
    /// responses rather than exposing them as something you can ask for. So
    /// rather than inventing a number or failing loudly, this reports what the
    /// account genuinely publishes: who is signed in, which plan they are on,
    /// and when it renews.
    public func fetchUsage() async throws -> UsageData {
        guard let token = session.token(for: id) else {
            throw ProviderError.notAuthenticated
        }

        let identity = try await ChatGPTSession.identity(sessionToken: token)
        // No `ChatGPT-Account-Id` header, deliberately. This endpoint is the one
        // that enumerates every workspace the session can see, and the parser
        // then picks whichever of them is actually paying; scoping the request
        // to a single workspace would throw that choice away.
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

    /// `backend-api` sits behind the same edge as the web app and answers the
    /// aibars agent string with a challenge page, so this leg has to look like a
    /// browser too.
    ///
    /// A Safari-shaped string would be the closer claim: these requests go out
    /// over URLSession's own TLS stack, whose fingerprint is Apple's, and
    /// pairing that with a Chrome agent string is a mismatch an edge can read.
    /// The string is not changed here on a guess, because the two chatgpt.com
    /// legs must agree — `ChatGPTSession` sends Chrome on the cookie exchange —
    /// and a session that starts as one browser and finishes as another is a
    /// worse claim than a consistent wrong one. Both belong on a shared
    /// `.browser` identity in `ProviderHTTP`, where the pair can be changed
    /// once and stay in step.
    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
        + "(KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    public func authenticate() async throws {
        if let cookie = CookieExtractors.firstAvailableCookie(named: ChatGPTSession.cookieName, for: "chatgpt.com") {
            try session.setToken(cookie.value, for: id, source: .browserCookie, accountHint: cookie.source.displayName)
            await MainActor.run { self.isAuthenticated = true }
        }
    }

    public func signOut() async throws {
        session.clear(id)
        await MainActor.run { self.isAuthenticated = false }
    }

    public func saveTokenManually(_ token: String, source: SessionSource = .manualPaste) throws {
        try session.setToken(token, for: id, source: source)
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
                windowLabel: nil,
                // Nil, and stated rather than defaulted so nobody fills it in
                // later. The date above is when the subscription renews, not
                // the length of a rolling allowance — ChatGPT publishes no
                // allowance at all — and a pace notch drawn from a billing
                // cycle would measure how far through the month the user is
                // and then claim it was pace.
                windowDuration: nil
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
