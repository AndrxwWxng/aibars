import Foundation
import SwiftUI

/// Tracks grok.com quota for the signed-in xAI account.
///
/// Auth: the `sso` cookie on grok.com. Signing in at grok.com bounces through
/// accounts.x.ai and lands back with `sso` and `sso-rw` set on the bare domain;
/// the gateway reads only those two names (anything else answers "No credentials
/// presented"), so both are sent when both can be read. Do not send users to
/// accounts.x.ai directly: it 403s non-browser clients and the cookie aibars
/// needs is scoped to grok.com anyway.
///
/// This is the consumer grok.com surface. An xAI developer key (api.x.ai) bills
/// against a separate ledger and says nothing about a SuperGrok subscription, so
/// it is deliberately not accepted here.
public final class GrokProvider: ObservableObject, UsageProvider {
    public let id: String
    /// The account this instance follows, when a service is signed into more
    /// than once. Nil is the only-account case.
    public let accountID: String?
    public var serviceID: String { "grok" }
    public let displayName = "Grok"
    public let iconName = "x.circle"
    public let accentColor: Color = Color(red: 0.20, green: 0.22, blue: 0.26)

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var lastError: ProviderError?

    /// In priority order: `sso` is the credential, `sso-rw` rides along because
    /// the anti-bot layer has been seen rejecting `sso` on its own.
    private let cookieNames = ["sso", "sso-rw"]
    private let cookieDomain = "grok.com"

    private let session = SessionStore.shared
    private let userDefaults = UserDefaults.standard
    private let enabledKey: String

    /// Grok quota is per mode (auto | fast | expert | heavy | build), not one
    /// shared pool — `expert` and `heavy` report their own `totalQueries`.
    /// `auto` is what the web app has selected by default.
    private let mode = "auto"

    private let rateLimitsURL = URL(string: "https://grok.com/rest/rate-limits")!
    private let subscriptionsURL = URL(string: "https://grok.com/rest/subscriptions")!
    private let freeUsageGatesURL = URL(string: "https://grok.com/rest/usage/free-usage-gates")!

    public init(accountID: String? = nil) {
        self.accountID = accountID
        self.id = accountID.map { "grok#\($0)" } ?? "grok"
        self.enabledKey = "aibars.\(self.id).enabled"
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = SessionStore.shared.hasCredential(for: id)
    }

    public var dashboardURL: URL? { URL(string: "https://grok.com/") }

    public var webLogin: WebLoginConfig? {
        WebLoginConfig(
            startURL: URL(string: "https://grok.com/")!,
            capture: .cookie(name: "sso", domainSuffix: cookieDomain),
            hint: "Sign in as usual — aibars picks up the session automatically.",
            dataDomains: ["grok.com", "x.ai", "accounts.x.ai"]
        )
    }

    /// Unofficial: `POST /rest/rate-limits` is the call grok.com's own composer
    /// polls for the quota pill, and `GET /rest/subscriptions` is what its plan
    /// badge reads. Neither is documented; both are cookie-gated and POST-only /
    /// GET-only respectively (the other verb answers 501).
    public func fetchUsage() async throws -> UsageData {
        guard let token = session.token(for: id) else {
            throw ProviderError.notAuthenticated
        }

        let http = ProviderHTTP(headers: [
            "Cookie": cookieHeader(for: token),
            "Origin": "https://grok.com",
            "Referer": "https://grok.com/",
            // grok.com sits behind Cloudflare; the default aibars agent string
            // is the shape its anti-bot rules look for.
            "User-Agent": Self.browserUserAgent
        ])

        do {
            let body = try JSONSerialization.data(withJSONObject: ["modelName": mode])
            let (rateData, _) = try await http.post(rateLimitsURL, body: body, headers: [
                "Content-Type": "application/json",
                // The web app stamps every /rest call with a fresh lowercase
                // UUID. It also sends a computed x-statsig-id, which is not
                // enforced at the edge today — a 403 here is the signal that it
                // started being.
                "x-xai-request-id": UUID().uuidString.lowercased()
            ])

            // The Cloudflare interstitial answers 200 with HTML, so a body that
            // isn't a JSON object has to be reported as itself. Reading it as an
            // empty object instead would blame the parser and spend a third
            // request on the free-usage fallback.
            guard let raw = (try? JSONSerialization.jsonObject(with: rateData)) as? [String: Any] else {
                throw ProviderError.parse("Rate-limit endpoint returned \(rateData.count) bytes that are not a JSON object")
            }
            let subscriptions = try? await json(from: subscriptionsURL, using: http)

            let usage: UsageData
            do {
                usage = try GrokUsageParser.parse(raw, subscriptions: subscriptions)
            } catch let error as ProviderError where !error.isAuth {
                // Free accounts get a rate-limit window with nothing in it;
                // their allowance lives behind the free-usage gates instead.
                // Only worth the third call once the cheap path has failed.
                guard let gates = try? await json(from: freeUsageGatesURL, using: http) else { throw error }
                usage = try GrokUsageParser.parse(raw, subscriptions: subscriptions, gates: gates)
            }
            await MainActor.run { self.lastError = nil }
            return usage
        } catch let error as ProviderError {
            await MainActor.run {
                self.lastError = error
                // A 403 is either a stale cookie or the anti-bot layer deciding
                // we look automated. Both are fixed by logging in again, so the
                // row has to go back to offering that.
                if error.isAuth { self.isAuthenticated = false }
            }
            throw error
        }
    }

    public func authenticate() async throws {
        let names = cookieNames
        let domain = cookieDomain
        let lookup = Task.detached(priority: .utility) {
            GrokProvider.resolveCookieHeader(names: names, domain: domain)
        }
        guard let found = await lookup.value else { return }

        try session.setToken(found.header, for: id, source: .browserCookie, accountHint: found.browser.displayName)
        await MainActor.run {
            self.isAuthenticated = true
            self.lastError = nil
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

    // MARK: - Internals

    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private func json(from url: URL, using http: ProviderHTTP) async throws -> [String: Any] {
        let (data, _) = try await http.get(url, headers: [
            "x-xai-request-id": UUID().uuidString.lowercased()
        ])
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderError.parse("Non-object response from \(url.path)")
        }
        return object
    }

    private struct ResolvedCookies {
        let header: String
        let browser: BrowserCookie.Browser
    }

    /// Walks every installed browser for the cookie pair, taking the first
    /// browser that has a usable `sso`. `sso-rw` is optional — it is only there
    /// to look like the web app.
    private static func resolveCookieHeader(names: [String], domain: String) -> ResolvedCookies? {
        guard let credential = names.first else { return nil }
        for extractor in CookieExtractors.available() {
            let pool = (try? extractor.cookies(for: domain)) ?? []
            let pairs = names.compactMap { name -> String? in
                guard let cookie = pool.first(where: { $0.name == name && !$0.value.isEmpty }) else { return nil }
                return "\(name)=\(cookie.value)"
            }
            // An sso-rw with no sso is not a session we can use.
            guard pairs.first?.hasPrefix("\(credential)=") == true else { continue }
            return ResolvedCookies(header: pairs.joined(separator: "; "), browser: extractor.browser)
        }
        return nil
    }

    /// A pasted value is the `sso` cookie, which is what the Settings hint asks
    /// for. A token that already carries one of the known names is passed
    /// through instead, so a user who copied the whole pair — or a whole
    /// `document.cookie` dump — keeps it. Testing for a bare "=" would not do:
    /// the `sso` value is base64ish and can end in padding of its own, and
    /// sending it with no name at all gets "No credentials presented".
    private func cookieHeader(for token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if cookieNames.contains(where: { trimmed.contains("\($0)=") }) { return trimmed }
        return "sso=\(trimmed)"
    }
}

public enum GrokUsageParser {
    /// `POST /rest/rate-limits` returns a flat object. Every field is optional in
    /// grok.com's own decoder, so none of it can be assumed present:
    ///
    ///   { "windowSizeSeconds": 7200, "remainingQueries": 24, "waitTimeSeconds": 0,
    ///     "totalQueries": 25, "remainingTokens": 8830, "totalTokens": 10000,
    ///     "lowEffortRateLimits":  { "cost": 1, "waitTimeSeconds": 0, "remainingQueries": 24 },
    ///     "highEffortRateLimits": { "cost": 5, "waitTimeSeconds": 0, "remainingQueries": 4 },
    ///     "preGenerationDelayMs": 0 }
    ///
    /// `subscriptions` is the `GET /rest/subscriptions` payload, used only for the
    /// plan label; `gates` is `GET /rest/usage/free-usage-gates`, the fallback
    /// meter for accounts with no subscription window.
    public static func parse(
        _ raw: [String: Any],
        subscriptions: [String: Any]? = nil,
        gates: [String: Any]? = nil,
        now: Date = Date()
    ) throws -> UsageData {
        let root = unwrap(raw)

        let totalQueries = number(root, "totalQueries", "total_queries")
        let remainingQueries = number(root, "remainingQueries", "remaining_queries")
        let totalTokens = number(root, "totalTokens", "total_tokens")
        let remainingTokens = number(root, "remainingTokens", "remaining_tokens")
        let windowSeconds = number(root, "windowSizeSeconds", "window_size_seconds")
        let waitSeconds = number(root, "waitTimeSeconds", "wait_time_seconds")

        // windowSizeSeconds is the window *length*, not a countdown: it comes
        // back as the same 7200 on every poll, so turning it into a reset date
        // would show "resets in 2h" forever. grok.com renders it as "Limit
        // resets every 2h", which is what windowLabel is for. waitTimeSeconds is
        // the only real countdown here, and it is non-zero exactly when the pool
        // is spent.
        let resetDate: Date? = waitSeconds.flatMap { $0 > 0 ? now.addingTimeInterval($0) : nil }
        let windowLabel = windowSeconds.flatMap(durationLabel).map { "every \($0)" }

        func meter(_ label: String, unit: String, total: Double?, remaining: Double?) -> UsageMetric? {
            guard let total, total > 0 else { return nil }
            // A missing `remaining` reads as untouched rather than as capped.
            let used = min(max(total - (remaining ?? total), 0), total)
            return UsageMetric(
                label: label,
                used: used,
                limit: total,
                unit: unit,
                resetDate: resetDate,
                windowLabel: windowLabel
            )
        }

        let queries = meter("Queries", unit: "queries", total: totalQueries, remaining: remainingQueries)
        let tokens = meter("Tokens", unit: "tokens", total: totalTokens, remaining: remainingTokens)
        let gateMeters = gates.map { gateMetrics($0) } ?? []

        var lanes: [UsageMetric] = []
        if let queries { lanes.append(queries) }
        if let tokens { lanes.append(tokens) }
        lanes.append(contentsOf: gateMeters)

        guard let primary = lanes.first else {
            throw ProviderError.parse("No query, token, or free-usage figures in Grok rate-limit response")
        }

        // The per-effort buckets carry a remaining count and a cost, but no
        // ceiling of their own, so they stay status-only: limit 0.
        var secondary = Array(lanes.dropFirst())
        for (key, label) in [("lowEffortRateLimits", "Low effort left"), ("highEffortRateLimits", "High effort left")] {
            guard let bucket = (root[key] ?? root[snakeCased(key)]) as? [String: Any],
                  let remaining = number(bucket, "remainingQueries", "remaining_queries")
            else { continue }
            secondary.append(UsageMetric(label: label, used: remaining, limit: 0, unit: "queries"))
        }

        return UsageData(
            providerID: "grok",
            planName: subscriptions.map { planName(from: $0) } ?? "Grok",
            primary: primary,
            secondary: secondary,
            rawJSON: try? JSONSerialization.data(withJSONObject: raw).base64EncodedString()
        )
    }

    /// grok.com's own `getSubscriptionLevel()`: keep the active subscriptions,
    /// take the highest-priority tier, map it to a label. The skew on
    /// `SUBSCRIPTION_TIER_GROK_PRO` displaying as "SuperGrok" is theirs.
    public static func planName(from subscriptions: [String: Any]) -> String {
        let list = (subscriptions["subscriptions"] as? [[String: Any]])
            ?? (subscriptions["data"] as? [[String: Any]])
            ?? []

        let active = list.filter { entry in
            guard let status = (entry["status"] as? String)?.uppercased() else {
                // No status field: assume it wouldn't be listed if it were dead.
                return true
            }
            // Not `hasSuffix("ACTIVE")` — SUBSCRIPTION_STATUS_INACTIVE ends in it.
            return status == "SUBSCRIPTION_STATUS_ACTIVE" || status == "ACTIVE"
        }

        let best = active
            .compactMap { entry -> (priority: Int, tier: String)? in
                guard let tier = (entry["tier"] as? String ?? entry["subscriptionTier"] as? String)?.uppercased() else {
                    return nil
                }
                return (tierPriority[tier] ?? 0, tier)
            }
            .max { $0.priority < $1.priority }

        guard let tier = best?.tier else { return "Free" }
        // A tier xAI added after this map was written is still a paid tier;
        // calling it "Free" would be worse than staying vague.
        return tierLabel[tier] ?? "Grok"
    }

    // MARK: - Internals

    private static let tierPriority: [String: Int] = [
        "SUBSCRIPTION_TIER_INVALID": 0,
        "SUBSCRIPTION_TIER_X_BASIC": 1,
        "SUBSCRIPTION_TIER_X_PREMIUM": 2,
        "SUBSCRIPTION_TIER_X_PREMIUM_PLUS": 3,
        "SUBSCRIPTION_TIER_SUPER_GROK_LITE": 4,
        "SUBSCRIPTION_TIER_GROK_PRO": 5,
        "SUBSCRIPTION_TIER_SUPER_GROK_PLUS": 6,
        "SUBSCRIPTION_TIER_SUPER_GROK_PRO": 7
    ]

    private static let tierLabel: [String: String] = [
        "SUBSCRIPTION_TIER_INVALID": "Free",
        "SUBSCRIPTION_TIER_X_BASIC": "Basic",
        "SUBSCRIPTION_TIER_X_PREMIUM": "Premium",
        "SUBSCRIPTION_TIER_X_PREMIUM_PLUS": "PremiumPlus",
        "SUBSCRIPTION_TIER_SUPER_GROK_LITE": "SuperGrokLite",
        "SUBSCRIPTION_TIER_GROK_PRO": "SuperGrok",
        "SUBSCRIPTION_TIER_SUPER_GROK_PLUS": "SuperGrokPlus",
        "SUBSCRIPTION_TIER_SUPER_GROK_PRO": "SuperGrokPro"
    ]

    /// `{ "chat": { "allowance": n, "remaining": n }, "imagine": …, "voice": …, "build": … }`.
    /// Listed in a fixed order so the rows don't shuffle between refreshes.
    private static func gateMetrics(_ gates: [String: Any]) -> [UsageMetric] {
        let root = (gates["gates"] as? [String: Any]) ?? (gates["data"] as? [String: Any]) ?? gates
        let surfaces = [("chat", "Chat"), ("imagine", "Imagine"), ("voice", "Voice"), ("build", "Build")]
        return surfaces.compactMap { key, label in
            guard let gate = root[key] as? [String: Any],
                  let allowance = number(gate, "allowance", "total", "limit"),
                  allowance > 0
            else { return nil }
            let remaining = number(gate, "remaining", "remainingQueries") ?? allowance
            return UsageMetric(
                label: label,
                used: min(max(allowance - remaining, 0), allowance),
                limit: allowance,
                unit: "queries",
                resetDate: nil,
                windowLabel: "free tier"
            )
        }
    }

    /// The payload is flat today, but a wrapper key is the most common way an
    /// undocumented endpoint changes shape.
    private static func unwrap(_ raw: [String: Any]) -> [String: Any] {
        let markers = [
            "totalQueries", "total_queries", "remainingQueries", "remaining_queries",
            "totalTokens", "total_tokens", "windowSizeSeconds", "window_size_seconds"
        ]
        if markers.contains(where: { raw[$0] != nil }) { return raw }
        for key in ["data", "rateLimits", "rate_limits", "result"] {
            if let nested = raw[key] as? [String: Any] { return nested }
        }
        return raw
    }

    private static func number(_ dict: [String: Any], _ keys: String...) -> Double? {
        for key in keys {
            if let value = ProviderNumber.coerce(dict[key]) { return value }
        }
        return nil
    }

    /// Rounded to the nearest minute: the windows in the wild are hours, and a
    /// label like "119m" would be noise.
    private static func durationLabel(_ seconds: Double) -> String? {
        guard seconds >= 60 else { return nil }
        let minutes = Int((seconds / 60).rounded())
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    private static func snakeCased(_ camel: String) -> String {
        camel.reduce(into: "") { result, character in
            if character.isUppercase {
                result.append("_")
                result.append(Character(character.lowercased()))
            } else {
                result.append(character)
            }
        }
    }
}
