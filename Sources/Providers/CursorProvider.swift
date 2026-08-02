import Foundation
import SwiftUI

/// Tracks Cursor Pro / Business usage via the dashboard API.
public final class CursorProvider: ObservableObject, UsageProvider {
    public let id = "cursor"
    public let displayName = "Cursor"
    public let iconName = "chevron.left.forwardslash.chevron.right"
    public let accentColor: Color = Color(red: 0.20, green: 0.20, blue: 0.20)

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false

    private let cookieName = "WorkosCursorSessionToken"
    private let session = SessionStore.shared
    private let userDefaults = UserDefaults.standard
    private let enabledKey = "aibars.cursor.enabled"

    public init() {
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = SessionStore.shared.token(for: "cursor") != nil
    }

    public func fetchUsage() async throws -> UsageData {
        guard let token = session.token(for: "cursor") else {
            throw ProviderError.notAuthenticated
        }

        let url = URL(string: "https://www.cursor.com/api/dashboard/usage")!
        let (data, _) = try await ProviderHTTP(headers: [
            "Cookie": "\(cookieName)=\(token)",
            "Origin": "https://www.cursor.com",
            "Referer": "https://www.cursor.com/dashboard"
        ]).get(url)

        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return CursorUsageParser.parse(raw)
    }

    public func authenticate() async throws {
        if let cookie = CookieExtractors.firstAvailableCookie(named: cookieName, for: "cursor.com") {
            try session.setToken(cookie.value, for: "cursor", source: .browserCookie, accountHint: cookie.source.displayName)
            await MainActor.run { self.isAuthenticated = true }
        }
    }

    public func signOut() async throws {
        session.clear("cursor")
        await MainActor.run { self.isAuthenticated = false }
    }

    public func saveTokenManually(_ token: String) throws {
        try session.setToken(token, for: "cursor", source: .manualPaste)
        Task { @MainActor in self.isAuthenticated = true }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: enabledKey)
    }
}

enum public CursorUsageParser {
    static func parse(_ raw: [String: Any]) -> UsageData {
        // Cursor's usage endpoint returns either individual buckets or
        // a `gpt-4`/`gpt-3.5-turbo` style breakdown. Be defensive.
        let plan = (raw["plan"] as? String) ?? (raw["membershipType"] as? String) ?? "Pro"
        let usage = (raw["usage"] as? [String: Any]) ?? raw
        let limit = (raw["limit"] as? Double) ?? (usage["limit"] as? Double) ?? 500

        let used = (usage["numRequests"] as? Double)
            ?? (usage["totalRequests"] as? Double)
            ?? (usage["used"] as? Double)
            ?? 0

        let cycleEnd = (raw["cycleEnd"] as? Double)
            ?? (raw["cycle_end"] as? Double)
            ?? (raw["resetAt"] as? Double)

        let primary = UsageMetric(
            label: "Fast requests",
            used: used,
            limit: limit,
            unit: "reqs",
            resetDate: cycleEnd.map { Date(timeIntervalSince1970: $0 / 1000) },
            windowLabel: "Monthly"
        )

        var secondary: [UsageMetric] = []
        for key in ["gpt-4", "gpt-3.5-turbo", "gpt-4-turbo", "claude-3-5-sonnet"] {
            if let bucket = usage[key] as? [String: Any],
               let bucketUsed = (bucket["numRequests"] as? Double) ?? (bucket["used"] as? Double),
               let bucketLimit = (bucket["limit"] as? Double) {
                secondary.append(UsageMetric(
                    label: key,
                    used: bucketUsed,
                    limit: bucketLimit,
                    unit: "reqs",
                    windowLabel: "Monthly"
                ))
            }
        }

        return UsageData(
            providerID: "cursor",
            planName: plan,
            primary: primary,
            secondary: secondary,
            rawJSON: try? JSONSerialization.data(withJSONObject: raw).base64EncodedString()
        )
    }
}
