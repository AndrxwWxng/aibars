import Foundation
import SwiftUI

/// Tracks Claude (Anthropic) usage for Pro and Max plans.
///
/// Auth: `sessionKey` cookie from claude.ai. The provider tries the
/// installed browsers first; if none returns a usable token, the user
/// is asked to paste it via the Settings sheet.
public final class ClaudeProvider: ObservableObject, UsageProvider {
    public let id = "claude"
    public let displayName = "Claude"
    public let iconName = "sparkles"
    public let accentColor: Color = Color(red: 0.85, green: 0.45, blue: 0.30)

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var lastError: ProviderError?

    private let cookieName = "sessionKey"
    private let session = SessionStore.shared
    private let userDefaults = UserDefaults.standard
    private let enabledKey = "aibars.claude.enabled"

    public init() {
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = SessionStore.shared.hasCredential(for: "claude")
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
        guard let token = session.token(for: "claude") else {
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
            try session.setToken(cookie.value, for: "claude", source: .browserCookie, accountHint: cookie.source.displayName)
            await MainActor.run {
                self.isAuthenticated = true
                self.lastError = nil
            }
        }
    }

    public func signOut() async throws {
        session.clear("claude")
        await MainActor.run { self.isAuthenticated = false }
    }

    public func saveTokenManually(_ token: String, source: SessionSource = .manualPaste) throws {
        try session.setToken(token, for: "claude", source: source)
        Task { @MainActor in self.isAuthenticated = true }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: enabledKey)
    }
}

public enum ClaudeUsageParser {
    public static func parse(_ raw: [String: Any], planName: String?, orgName: String) throws -> UsageData {
        // Claude's /usage endpoint shape varies. We accept a few common keys.
        let fiveHour = (raw["five_hour"] as? [String: Any]) ?? [:]
        let sevenDay = (raw["seven_day"] as? [String: Any]) ?? [:]

        func metric(_ bucket: [String: Any], fallback: String) -> UsageMetric? {
            let utilization = ProviderNumber.coerce(bucket["utilization"]) ?? 0
            let resetsAt = (bucket["resets_at"] as? String).flatMap { ProviderDate.parse($0) }
            return UsageMetric(
                label: bucket["label"] as? String ?? fallback,
                used: utilization,
                limit: 100,
                unit: "%",
                resetDate: resetsAt,
                windowLabel: fallback
            )
        }

        guard let primary = metric(fiveHour, fallback: "5h window") else {
            throw ProviderError.parse("Unexpected Claude response shape")
        }
        var secondary: [UsageMetric] = []
        if let weekly = metric(sevenDay, fallback: "7d window") {
            secondary.append(weekly)
        }

        return UsageData(
            providerID: "claude",
            planName: planName.map { $0.capitalized } ?? "Pro",
            primary: UsageMetric(
                label: primary.label,
                used: primary.used,
                limit: 100,
                unit: "%",
                resetDate: primary.resetDate,
                windowLabel: primary.windowLabel
            ),
            secondary: secondary,
            rawJSON: try? JSONSerialization.data(withJSONObject: raw).base64EncodedString()
        )
    }
}
