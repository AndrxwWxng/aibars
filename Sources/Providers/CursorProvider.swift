import Foundation
import SwiftUI

/// Tracks Cursor Pro / Business usage via the dashboard API.
public final class CursorProvider: ObservableObject, UsageProvider {
    public let id: String
    /// The account this instance follows, when a service is signed into more
    /// than once. Nil is the only-account case.
    public let accountID: String?
    public var serviceID: String { "cursor" }
    public let displayName = "Cursor"
    public let iconName = "chevron.left.forwardslash.chevron.right"

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false

    private let cookieName = "WorkosCursorSessionToken"
    private let session = SessionStore.shared
    private let userDefaults = AppDefaults.current
    private let enabledKey: String

    /// The signed-in address, once `/api/auth/me` has named it. Cached because
    /// it does not change between refreshes and a second request per minute for
    /// a value that never moves is waste.
    private var discoveredAccount: String?

    public init(accountID: String? = nil) {
        self.accountID = accountID
        self.id = accountID.map { "cursor#\($0)" } ?? "cursor"
        self.enabledKey = "aibars.\(self.id).enabled"
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = SessionStore.shared.hasCredential(for: id)
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
        guard let token = session.token(for: id) else {
            throw ProviderError.notAuthenticated
        }

        // `/api/dashboard/usage` returns 404 — it moved. `/api/usage` is what the
        // dashboard calls now, verified against a live Pro session.
        let url = URL(string: "https://cursor.com/api/usage")!
        let (data, _) = try await ProviderHTTP(headers: headers(cookie: token)).get(url)

        let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        // Best-effort, exactly as the account lookup below is: the quota card
        // from `/api/usage` is the thing the row is actually for, and a spend
        // figure that failed to arrive must not take the whole refresh down.
        let summary = await usageSummary(cookie: token)
        var usage = CursorUsageParser.parse(raw, summary: summary)

        if discoveredAccount == nil {
            discoveredAccount = try? await accountEmail(cookie: token)
        }
        if let account = discoveredAccount {
            usage = UsageData(
                providerID: usage.providerID,
                fetchedAt: usage.fetchedAt,
                planName: usage.planName,
                primary: usage.primary,
                secondary: usage.secondary,
                accountLabel: account,
                // Carried through by hand: this rebuild exists only to hang a
                // label on the reading, and a field left out here is a field
                // the row silently loses the moment an account gets named.
                rawJSON: usage.rawJSON,
                spend: usage.spend
            )
        }
        return usage
    }

    /// The session cookie, plus the Origin and Referer the dashboard sends. Both
    /// endpoints are the dashboard's own, and both refuse a cookie that arrives
    /// without them.
    private func headers(cookie token: String) -> [String: String] {
        [
            "Cookie": "\(cookieName)=\(token)",
            "Origin": "https://www.cursor.com",
            "Referer": "https://www.cursor.com/dashboard",
            "Accept": "application/json"
        ]
    }

    /// `/api/usage-summary` is where the money is: on-demand and overall spend
    /// in cents, and the billing cycle's own bounds.
    ///
    /// Four seconds rather than the usual fifteen, and the failure is swallowed
    /// rather than thrown: this is a second card on a row whose answer has
    /// already arrived, and a slow ledger must not hold up a quota.
    private func usageSummary(cookie token: String) async -> [String: Any]? {
        let url = URL(string: "https://cursor.com/api/usage-summary")!
        let http = ProviderHTTP(headers: headers(cookie: token), timeout: 4)
        guard let payload = (try? await http.get(url))?.0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }

    /// `/api/auth/me` answers with the account behind the session. Failure is not
    /// worth surfacing — the usage already arrived, and an unnamed row is a
    /// smaller problem than a row that errors over a label.
    private func accountEmail(cookie token: String) async throws -> String? {
        let url = URL(string: "https://cursor.com/api/auth/me")!
        let (data, _) = try await ProviderHTTP(headers: headers(cookie: token)).get(url)
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let email = raw?["email"] as? String
        return (email?.isEmpty ?? true) ? nil : email
    }

    public func authenticate() async throws {
        if let cookie = CookieExtractors.firstAvailableCookie(named: cookieName, for: "cursor.com") {
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

public enum CursorUsageParser {
    /// Cursor bills on Gregorian months in UTC, so the cycle arithmetic is done
    /// there rather than in the user's region calendar — adding a month in a
    /// lunar calendar would end the cycle a day early, every cycle.
    private static let billingCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        if let utc = TimeZone(identifier: "UTC") { calendar.timeZone = utc }
        return calendar
    }()

    /// `/api/usage` answers with one entry per model plus `startOfMonth`:
    ///
    ///     { "gpt-4": { "numRequests": 12, "maxRequestUsage": 500, … },
    ///       "gpt-3.5-turbo": { … },
    ///       "startOfMonth": "2026-07-21T23:37:30.000Z" }
    ///
    /// `maxRequestUsage` is null on plans that no longer meter requests — the
    /// usage-based tiers bill instead of capping — so a null ceiling is reported
    /// as a status rather than invented as a percentage.
    ///
    /// `summary` is the optional second payload, `/api/usage-summary`, which
    /// carries the money and the exact cycle bounds. It is a separate request
    /// and a separate failure, so it arrives as an optional rather than as a
    /// reason the quota card cannot be built.
    public static func parse(_ raw: [String: Any], summary: [String: Any]? = nil) -> UsageData {
        let plan = (raw["plan"] as? String) ?? (raw["membershipType"] as? String) ?? "Pro"
        let usage = (raw["usage"] as? [String: Any]) ?? raw

        let cycle = billingCycle(usage: usage, raw: raw, summary: summary)

        var buckets: [(key: String, label: String, used: Double, limit: Double)] = []
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
            buckets.append((key, label(for: key), used, limit))
        }

        // The metered bucket is the interesting one; ties break on usage so the
        // busiest model leads.
        let sorted = buckets.sorted { lhs, rhs in
            if (lhs.limit > 0) != (rhs.limit > 0) { return lhs.limit > 0 }
            return lhs.used > rhs.used
        }

        let leading = sorted.first
        let primary = UsageMetric(
            label: leading.map { $0.limit > 0 ? "Requests" : "this cycle" } ?? "Requests",
            used: leading?.used ?? 0,
            limit: leading?.limit ?? 0,
            // A unit even when uncapped: it marks the figure as a count, so the
            // row reads "0 reqs this cycle" rather than a bare label.
            unit: "reqs",
            resetDate: cycle.end,
            windowLabel: "Monthly",
            windowDuration: cycle.duration,
            // Pinned, because the label above is the one thing on this row that
            // moves: the same account reads "Requests" while its plan meters
            // them and "this cycle" the month it stops, and a key derived from
            // the label would file the second as a new series with none of the
            // first one's readings behind it.
            windowKey: "monthly_requests"
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
                    resetDate: cycle.end,
                    windowLabel: "Monthly",
                    windowDuration: cycle.duration,
                    // Cursor's own key for the bucket, not the display name
                    // `label(for:)` gives it — that mapping is this file's
                    // wording and can be reworded, while "gpt-4" is the payload.
                    windowKey: "model_\($0.key)"
                )
            }

        return UsageData(
            providerID: "cursor",
            planName: plan,
            primary: primary,
            secondary: Array(secondary),
            rawJSON: rawJSON(usage: raw, summary: summary),
            spend: spend(summary, cycle: cycle)
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

    // MARK: - The billing cycle

    /// The month being billed, as far as the two payloads state it.
    private struct BillingCycle {
        let start: Date?
        let end: Date?

        /// How long this window is, and only when both edges are known.
        ///
        /// The meter draws its pace notch against this, so the length has to be
        /// the month's own — 28 to 31 days — rather than a flat 30. A cycle with
        /// one edge named has no length, and nil is the honest answer: a notch
        /// on an assumed duration is an assumption drawn as an instrument.
        var duration: TimeInterval? {
            guard let start, let end else { return nil }
            let length = end.timeIntervalSince(start)
            return length > 0 ? length : nil
        }
    }

    private static func billingCycle(
        usage: [String: Any],
        raw: [String: Any],
        summary: [String: Any]?
    ) -> BillingCycle {
        // `/api/usage` names the start and the cycle rolls a month later.
        if let start = date(usage["startOfMonth"]) ?? date(raw["startOfMonth"]) {
            return BillingCycle(start: start, end: billingCalendar.date(byAdding: .month, value: 1, to: start))
        }
        // Enterprise and team responses can omit it, and usage-summary states
        // both bounds outright, so the second payload answers when the first
        // does not. Both edges or neither: half a cycle is not a cycle.
        if let start = date(summary?["billingCycleStart"]), let end = date(summary?["billingCycleEnd"]) {
            return BillingCycle(start: start, end: end)
        }
        // Older payloads carried the far edge only.
        return BillingCycle(start: nil, end: date(raw["cycleEnd"]))
    }

    /// A cycle bound as either an ISO 8601 string or epoch milliseconds, which
    /// is what the two endpoints send respectively.
    private static func date(_ value: Any?) -> Date? {
        if let text = value as? String { return ProviderDate.parse(text) }
        guard let millis = ProviderNumber.coerce(value), millis > 0 else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    // MARK: - The money

    /// The on-demand spend, from `/api/usage-summary`.
    ///
    /// Every figure in that payload is already in cents, which is exactly the
    /// shape `SpendReport` wants: the money never becomes a `Double` on the way
    /// in and never has to be rounded back.
    ///
    /// Four buckets can carry it and only one of them is this row's reading. The
    /// individual buckets are the signed-in account's own spend; the team ones
    /// are the organisation's aggregate, and an org's bill on a personal row is
    /// the wrong number rather than a rounder one. Individual first therefore,
    /// and the team aggregate only when Cursor sent no individual bucket at all
    /// or marked the ones it sent off.
    private static func spend(_ summary: [String: Any]?, cycle: BillingCycle) -> SpendReport? {
        guard let summary else { return nil }
        let individual = summary["individualUsage"] as? [String: Any]
        let team = summary["teamUsage"] as? [String: Any]
        let candidates: [Any?] = [
            individual?["onDemand"],
            individual?["overall"],
            team?["onDemand"],
            team?["pooled"]
        ]
        guard let bucket = candidates.compactMap({ Self.bucket($0) }).first else { return nil }

        return SpendReport(
            amountMinor: bucket.usedMinor,
            // Cursor states no currency anywhere in this payload and prices its
            // plans, its on-demand rates and this endpoint in dollars. It is the
            // one fact the response leaves out, rather than one this guesses at.
            currency: "USD",
            exponent: 2,
            ceiling: bucket.ceiling,
            period: .month,
            // Cursor's own accounting, to the cent. Nothing local priced it.
            confidence: .measured,
            resetDate: cycle.end
        )
    }

    private struct SpendBucket {
        let usedMinor: Int
        let ceiling: SpendReport.Ceiling
    }

    /// One `{ enabled, limit, used, remaining }` bucket, all four in cents.
    ///
    /// `enabled: false` is a placeholder Cursor sends beside a live bucket on
    /// team accounts, so it is skipped rather than read as a spend of zero.
    ///
    /// `used` leads, but it comes back as zero on shapes where only the
    /// remaining balance moved, so a positive `limit - remaining` wins over a
    /// reported zero. The two only ever disagree in that direction.
    ///
    /// A bucket carrying none of the three numbers is not a reading at all and
    /// falls through to the next candidate — otherwise an empty individual
    /// placeholder would report $0.00 and hide a team bucket that has figures.
    private static func bucket(_ value: Any?) -> SpendBucket? {
        guard let entry = value as? [String: Any] else { return nil }
        if let enabled = entry["enabled"] as? Bool, !enabled { return nil }

        let stated = ProviderNumber.coerce(entry["used"])
        let limit = ProviderNumber.coerce(entry["limit"])
        let remaining = ProviderNumber.coerce(entry["remaining"])
        guard stated != nil || limit != nil || remaining != nil else { return nil }

        var inferred: Double = 0
        if let limit, let remaining { inferred = max(limit - remaining, 0) }
        let reported = stated ?? 0
        let used = reported > 0 ? reported : inferred

        guard let usedMinor = minor(used) else { return nil }
        return SpendBucket(usedMinor: usedMinor, ceiling: ceiling(entry["limit"]))
    }

    /// What the payload said about the ceiling, in the three states a
    /// `SpendReport` tells apart.
    ///
    /// Cursor writes `0` for a bucket with no hard limit, which is genuinely
    /// uncapped and not a ceiling of nothing. A `limit` that is present and
    /// cannot be read is neither: it poisons the report, because showing an
    /// unread ceiling as uncapped invents headroom.
    private static func ceiling(_ stated: Any?) -> SpendReport.Ceiling {
        guard let stated, !(stated is NSNull) else { return .uncapped }
        guard let limit = ProviderNumber.coerce(stated) else { return .unreadable }
        guard limit > 0 else { return .uncapped }
        guard let value = minor(limit) else { return .unreadable }
        return .limit(value)
    }

    /// Cents as an `Int`, or nothing. `Int(_:)` traps outside its range and the
    /// only thing that could put a figure there is a corrupt payload, which is
    /// not a bill — so it reports nothing rather than a number or a crash.
    private static func minor(_ cents: Double) -> Int? {
        let rounded = cents.rounded()
        guard rounded.isFinite, rounded.magnitude < 9e15 else { return nil }
        return Int(rounded)
    }

    // MARK: - Raw payload

    /// Both payloads, under the names they were fetched by. Wrapped even when
    /// only one arrived, so what the raw-JSON inspector shows has one shape
    /// rather than two that depend on whether a best-effort call answered.
    private static func rawJSON(usage: [String: Any], summary: [String: Any]?) -> String? {
        let payload: [String: Any] = ["usage": usage, "summary": summary ?? [:]]
        guard JSONSerialization.isValidJSONObject(payload) else { return nil }
        return try? JSONSerialization.data(withJSONObject: payload).base64EncodedString()
    }
}
