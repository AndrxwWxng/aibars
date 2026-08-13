import Foundation
import SwiftUI

/// Tracks GitHub Copilot usage.
///
/// Uses the official Copilot user info endpoint. Detailed usage metrics
/// require a GitHub token; without one, we surface plan + seat info.
public final class CopilotProvider: ObservableObject, UsageProvider {
    public let id: String
    /// The account this instance follows, when a service is signed into more
    /// than once. Nil is the only-account case.
    public let accountID: String?
    public var serviceID: String { "copilot" }
    public let displayName = "GitHub Copilot"
    public let iconName = "chevron.left.slash.chevron.right"

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false

    private let session = SessionStore.shared
    private let userDefaults = AppDefaults.current
    private let enabledKey: String

    public init(accountID: String? = nil) {
        self.accountID = accountID
        self.id = accountID.map { "copilot#\($0)" } ?? "copilot"
        self.enabledKey = "aibars.\(self.id).enabled"
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = SessionStore.shared.hasCredential(for: id)
    }

    public var dashboardURL: URL? { URL(string: "https://github.com/settings/copilot") }

    public var webLogin: WebLoginConfig? {
        // Copilot's API wants a personal access token, not a session cookie,
        // so the best we can do is land the user on a pre-filled token form
        // and take the result without them leaving the app.
        WebLoginConfig(
            startURL: URL(string: "https://github.com/settings/tokens/new?scopes=read:user,copilot&description=aibars")!,
            capture: .tokenShownOnPage,
            hint: "Scroll down, click “Generate token”, then paste it below.",
            dataDomains: ["github.com"]
        )
    }

    public func fetchUsage() async throws -> UsageData {
        guard let token = session.token(for: id) else {
            throw ProviderError.notAuthenticated
        }

        let http = ProviderHTTP(headers: [
            "Authorization": "Bearer \(token)",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"
        ])

        // User info (plan, seat)
        let userURL = URL(string: "https://api.github.com/copilot_internal/user")!
        let (userData, _) = try await http.get(userURL)
        let user = try JSONSerialization.jsonObject(with: userData) as? [String: Any] ?? [:]

        // Quota / usage (best-effort — endpoint may be gated)
        var usage: [String: Any] = [:]
        if let quotaURL = URL(string: "https://api.github.com/copilot_internal/usage") {
            if let (u, _) = try? await http.get(quotaURL),
               let dict = (try? JSONSerialization.jsonObject(with: u)) as? [String: Any] {
                usage = dict
            }
        }

        return CopilotUsageParser.parse(user: user, usage: usage)
    }

    public func authenticate() async throws {
        if session.token(for: id) != nil {
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

public enum CopilotUsageParser {
    public static func parse(user: [String: Any], usage: [String: Any]) -> UsageData {
        let plan = (user["copilot_plan"] as? String)
            ?? (user["plan"] as? String)
            ?? "Individual"
        let chat = (user["chat_enabled"] as? Bool) ?? true
        let quotaReset = (usage["quota_reset_date"] as? String).flatMap { ProviderDate.parse($0) }

        // Most public-facing Copilot endpoints don't expose numeric usage, so
        // this is a status rather than a quota. A zero limit marks it as such:
        // it keeps a seat that is merely *active* from reading as 100% used
        // and dragging the menu bar meter into the red. The menu bar strip
        // reads the same zero and prints an em dash, which is the honest
        // statement — Copilot reports that it is on, not how much is left.
        let primary = UsageMetric(
            label: chat ? "Active" : "Paused",
            used: chat ? 1 : 0,
            limit: 0,
            unit: nil,
            resetDate: quotaReset,
            windowLabel: nil,
            // Nil, and stated rather than defaulted so nobody fills it in later:
            // the date above is when the seat renews, not the length of a
            // rolling window. A notch drawn from a billing cycle would measure
            // how far through the month the user is and claim it was pace.
            windowDuration: nil
        )

        return UsageData(
            providerID: "copilot",
            planName: plan,
            primary: primary,
            secondary: [],
            rawJSON: try? JSONSerialization.data(withJSONObject: ["user": user, "usage": usage]).base64EncodedString()
        )
    }
}
