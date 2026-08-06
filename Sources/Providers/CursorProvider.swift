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
        self.isAuthenticated = SessionStore.shared.hasCredential(for: "cursor")
    }

    public var dashboardURL: URL? { URL(string: "https://www.cursor.com/dashboard") }

    public var webLogin: WebLoginConfig? {
        WebLoginConfig(
            // The dashboard bounces to the login page when signed out and
            // back here once done, which is when the cookie lands.
            startURL: URL(string: "https://www.cursor.com/dashboard")!,
            capture: .cookie(name: cookieName, domainSuffix: "cursor.com"),
            hint: "Log in as usual — aibars picks up the session automatically.",
            dataDomains: ["cursor.com", "cursor.sh", "workos.com"]
        )
    }

    public func fetchUsage() async throws -> UsageData {
        guard let token = session.token(for: "cursor") else {
            throw ProviderError.notAuthenticated
        }

        // `/api/dashboard/usage` returns 404 — it moved. `/api/usage` is what the
        // dashboard calls now, verified against a live Pro session.
        let url = URL(string: "https://cursor.com/api/usage")!
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

    public func saveTokenManually(_ token: String, source: SessionSource = .manualPaste) throws {
        try session.setToken(token, for: "cursor", source: source)
        Task { @MainActor in self.isAuthenticated = true }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: enabledKey)
    }
}

public enum CursorUsageParser {
    /// `/api/usage` answers with one entry per model plus `startOfMonth`:
    ///
    ///     { "gpt-4": { "numRequests": 12, "maxRequestUsage": 500, … },
    ///       "gpt-3.5-turbo": { … },
    ///       "startOfMonth": "2026-07-21T23:37:30.000Z" }
    ///
    /// `maxRequestUsage` is null on plans that no longer meter requests — the
    /// usage-based tiers bill instead of capping — so a null ceiling is reported
    /// as a status rather than invented as a percentage.
    public static func parse(_ raw: [String: Any]) -> UsageData {
        let plan = (raw["plan"] as? String) ?? (raw["membershipType"] as? String) ?? "Pro"
        let usage = (raw["usage"] as? [String: Any]) ?? raw

        // The cycle rolls a month after it started.
        let cycleStart = (usage["startOfMonth"] as? String).flatMap { ProviderDate.parse($0) }
            ?? (raw["startOfMonth"] as? String).flatMap { ProviderDate.parse($0) }
        let resetDate = cycleStart.flatMap {
            Calendar.current.date(byAdding: .month, value: 1, to: $0)
        } ?? (raw["cycleEnd"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }

        var buckets: [(label: String, used: Double, limit: Double)] = []
        for (key, value) in usage {
            guard let bucket = value as? [String: Any] else { continue }
            let used = ProviderNumber.coerce(bucket["numRequests"])
                ?? ProviderNumber.coerce(bucket["numRequestsTotal"])
                ?? ProviderNumber.coerce(bucket["used"])
                ?? 0
            // Absent or null means "no ceiling on this plan".
            let limit = ProviderNumber.coerce(bucket["maxRequestUsage"])
                ?? ProviderNumber.coerce(bucket["limit"])
                ?? 0
            buckets.append((label(for: key), used, limit))
        }

        // The metered bucket is the interesting one; ties break on usage so the
        // busiest model leads.
        let sorted = buckets.sorted { lhs, rhs in
            if (lhs.limit > 0) != (rhs.limit > 0) { return lhs.limit > 0 }
            return lhs.used > rhs.used
        }

        let leading = sorted.first
        let primary = UsageMetric(
            label: leading.map { $0.limit > 0 ? "Requests" : "\($0.label) requests" } ?? "Requests",
            used: leading?.used ?? 0,
            limit: leading?.limit ?? 0,
            unit: leading.map { $0.limit > 0 ? "reqs" : nil } ?? nil,
            resetDate: resetDate,
            windowLabel: "Monthly"
        )

        let secondary = sorted.dropFirst()
            .filter { $0.limit > 0 || $0.used > 0 }
            .prefix(3)
            .map {
                UsageMetric(
                    label: $0.label,
                    used: $0.used,
                    limit: $0.limit,
                    unit: "reqs",
                    resetDate: resetDate,
                    windowLabel: "Monthly"
                )
            }

        return UsageData(
            providerID: "cursor",
            planName: plan,
            primary: primary,
            secondary: Array(secondary),
            rawJSON: try? JSONSerialization.data(withJSONObject: raw).base64EncodedString()
        )
    }

    private static func label(for key: String) -> String {
        switch key {
        case "gpt-4": return "GPT-4 class"
        case "gpt-3.5-turbo": return "GPT-3.5"
        case "gpt-4-turbo": return "GPT-4 Turbo"
        default: return key
        }
    }
}
