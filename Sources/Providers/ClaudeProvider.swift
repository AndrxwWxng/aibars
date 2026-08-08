import Foundation
import SwiftUI

/// Tracks Claude (Anthropic) usage for Pro and Max plans.
///
/// Auth: `sessionKey` cookie from claude.ai. The provider tries the
/// installed browsers first; if none returns a usable token, the user
/// is asked to paste it via the Settings sheet.
public final class ClaudeProvider: ObservableObject, UsageProvider {
    public let id: String
    /// The account this instance follows, when a service is signed into more
    /// than once. Nil is the only-account case.
    public let accountID: String?
    public var serviceID: String { "claude" }
    public let displayName = "Claude"
    public let iconName = "sparkles"
    public let accentColor: Color = Color(red: 0.85, green: 0.45, blue: 0.30)

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var lastError: ProviderError?

    private let cookieName = "sessionKey"
    private let session = SessionStore.shared
    private let userDefaults = UserDefaults.standard
    private let enabledKey: String

    public init(accountID: String? = nil) {
        self.accountID = accountID
        self.id = accountID.map { "claude#\($0)" } ?? "claude"
        self.enabledKey = "aibars.\(self.id).enabled"
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = SessionStore.shared.hasCredential(for: id)
    }

    public var dashboardURL: URL? { URL(string: "https://claude.ai/settings/usage") }

    public var webLogin: WebLoginConfig? {
        WebLoginConfig(
            startURL: URL(string: "https://claude.ai/login")!,
            capture: .cookie(name: cookieName, domainSuffix: "claude.ai"),
            hint: "Log in as usual — aibars picks up the session automatically.",
            dataDomains: ["claude.ai", "anthropic.com"]
        )
    }

    public func fetchUsage() async throws -> UsageData {
        guard let token = session.token(for: id) else {
            throw ProviderError.notAuthenticated
        }

        // First, resolve the active organization.
        let orgsURL = URL(string: "https://claude.ai/api/organizations")!
        let (orgsData, _) = try await ProviderHTTP(headers: [
            "Cookie": "\(cookieName)=\(token)",
            "Origin": "https://claude.ai",
            "Referer": "https://claude.ai/"
        ]).get(orgsURL)

        struct Orgs: Decodable { let uuid: String; let name: String; let rate_limit_tier: String? }
        let orgs = try ProviderHTTP().decode([Orgs].self, from: orgsData)
        guard let org = orgs.first else {
            throw ProviderError.parse("No organization found")
        }

        // Pull usage.
        let usageURL = URL(string: "https://claude.ai/api/organizations/\(org.uuid)/usage")!
        let (usageData, _) = try await ProviderHTTP(headers: [
            "Cookie": "\(cookieName)=\(token)",
            "Origin": "https://claude.ai",
            "Referer": "https://claude.ai/usage"
        ]).get(usageURL)

        let raw = try JSONSerialization.jsonObject(with: usageData) as? [String: Any] ?? [:]
        return try ClaudeUsageParser.parse(raw, planName: org.rate_limit_tier, orgName: org.name)
    }

    public func authenticate() async throws {
        if let cookie = CookieExtractors.firstAvailableCookie(named: cookieName, for: "claude.ai"),
           !cookie.value.isEmpty {
            try session.setToken(cookie.value, for: id, source: .browserCookie, accountHint: cookie.source.displayName)
            await MainActor.run {
                self.isAuthenticated = true
                self.lastError = nil
            }
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

public enum ClaudeUsageParser {
    /// Claude publishes every window it enforces in a `limits` array:
    ///
    ///     limits: [
    ///       { kind: "session",       percent: 5,  resets_at: …, severity: "normal"  },
    ///       { kind: "weekly_all",    percent: 79, resets_at: …, severity: "warning" },
    ///       { kind: "weekly_scoped", percent: 59, resets_at: …, scope: { model: … } }
    ///     ]
    ///
    /// Reading only `five_hour` and `seven_day` — which is all this used to do —
    /// silently dropped the per-model weekly cap, so an account 59% through one
    /// of its limits was shown no sign of it. Every window it reports is now a
    /// window aibars shows.
    public static func parse(_ raw: [String: Any], planName: String?, orgName: String) throws -> UsageData {
        var windows = (raw["limits"] as? [[String: Any]]).map(metrics(from:)) ?? []

        // Older responses only carried the two named buckets.
        if windows.isEmpty {
            windows = [("five_hour", "5h window"), ("seven_day", "7d window")]
                .compactMap { key, label in
                    guard let bucket = raw[key] as? [String: Any] else { return nil }
                    return metric(
                        label: bucket["label"] as? String ?? label,
                        percent: ProviderNumber.coerce(bucket["utilization"]) ?? 0,
                        resetsAt: bucket["resets_at"] as? String
                    )
                }
        }
        guard !windows.isEmpty else {
            throw ProviderError.parse("No usage windows in the Claude response")
        }

        // Busiest first, so the headline figure is the limit actually at risk.
        // The 5-hour window used to lead unconditionally, which reported 5%
        // while the weekly cap sat at 79%.
        let sorted = windows.sorted { $0.percent > $1.percent }

        return UsageData(
            providerID: "claude",
            planName: tierName(planName),
            primary: sorted[0],
            secondary: Array(sorted.dropFirst()),
            accountLabel: accountName(orgName),
            rawJSON: try? JSONSerialization.data(withJSONObject: raw).base64EncodedString()
        )
    }

    /// Turns a rate-limit tier into a plan someone would recognise.
    ///
    /// The API answers with identifiers like `Default_Claude_Max_20X` or
    /// `Default_Claude_Ai`. Stripping the boilerplate off the latter leaves "Ai",
    /// which is the product's name rather than a plan — so the tiers are mapped
    /// rather than tidied, and only an unrecognised one falls back to tidying.
    private static func tierName(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "Pro" }
        let lower = raw.lowercased()
        if lower.contains("max") {
            // "Max_20X" is a multiplier worth keeping; "Max" alone is not.
            if let multiplier = lower.split(separator: "_").last(where: { $0.hasSuffix("x") }),
               let digits = Int(multiplier.dropLast()) {
                return "Max \(digits)×"
            }
            return "Max"
        }
        if lower.contains("team") { return "Team" }
        if lower.contains("enterprise") { return "Enterprise" }
        if lower.contains("pro") { return "Pro" }
        // `claude_ai` with nothing else is the tier every free account reports.
        if lower.replacingOccurrences(of: "default_", with: "") == "claude_ai" { return "Free" }
        return PlanName.pretty(raw, service: "Claude")
    }

    /// Personal organisations are all named "<email>'s Organization", so the
    /// suffix is eleven characters that distinguish nothing — and it pushed the
    /// address itself into an ellipsis.
    private static func accountName(_ orgName: String) -> String? {
        guard !orgName.isEmpty else { return nil }
        for suffix in ["'s Organization", "’s Organization", "'s Org", "’s Org"] {
            if orgName.hasSuffix(suffix) {
                return String(orgName.dropLast(suffix.count))
            }
        }
        return orgName
    }

    private static func metrics(from limits: [[String: Any]]) -> [UsageMetric] {
        limits.compactMap { entry in
            guard let percent = ProviderNumber.coerce(entry["percent"]) else { return nil }
            return metric(
                label: label(for: entry),
                percent: percent,
                resetsAt: entry["resets_at"] as? String
            )
        }
    }

    private static func metric(label: String, percent: Double, resetsAt: String?) -> UsageMetric {
        UsageMetric(
            label: label,
            used: percent,
            limit: 100,
            unit: "%",
            resetDate: resetsAt.flatMap { ProviderDate.parse($0) },
            windowLabel: label
        )
    }

    /// `kind` is the specific window, `group` the family it belongs to. A
    /// scoped weekly limit applies to particular models, and names them when it
    /// can — "Weekly · Opus" is worth far more than "weekly_scoped".
    private static func label(for entry: [String: Any]) -> String {
        let kind = (entry["kind"] as? String) ?? (entry["group"] as? String) ?? "limit"
        switch kind {
        case "session":
            return "5h session"
        case "weekly_all":
            return "Weekly · all models"
        case "weekly_scoped":
            if let scope = entry["scope"] as? [String: Any],
               let model = scopedModelName(scope) {
                return "Weekly · \(model)"
            }
            return "Weekly · per-model"
        default:
            return kind.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    private static func scopedModelName(_ scope: [String: Any]) -> String? {
        if let name = scope["model"] as? String, !name.isEmpty { return name }
        // Some responses nest it a level deeper.
        if let model = scope["model"] as? [String: Any] {
            for key in ["display_name", "name", "id"] {
                if let name = model[key] as? String, !name.isEmpty { return name }
            }
        }
        return nil
    }
}
