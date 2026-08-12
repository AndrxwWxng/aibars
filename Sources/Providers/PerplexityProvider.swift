import Foundation
import SwiftUI

/// Tracks Perplexity Pro/Max credit usage.
///
/// Auth: the Auth.js session cookie from perplexity.ai. Perplexity migrated from
/// NextAuth to Auth.js, so which of four cookie names is present depends on when
/// the user last signed in — `authenticate()` accepts all of them.
///
/// This is the consumer credit pool only. A Sonar API key (api.perplexity.ai)
/// bills against a separate ledger and tells you nothing about a Pro/Max
/// subscription, so it is deliberately not used here.
public final class PerplexityProvider: ObservableObject, UsageProvider {
    public let id: String
    /// The account this instance follows, when a service is signed into more
    /// than once. Nil is the only-account case.
    public let accountID: String?
    public var serviceID: String { "perplexity" }
    public let displayName = "Perplexity"
    public let iconName = "magnifyingglass.circle.fill"

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var lastError: ProviderError?

    /// What a fresh login writes, and the one name `WebLoginConfig.capture` can
    /// carry — the rest ride along as its alternates.
    private static let primaryCookieName = "__Secure-authjs.session-token"
    /// In priority order. The `next-auth` pair lingers on accounts that signed
    /// in before the migration and is still honoured by the server.
    private let cookieNames = [
        PerplexityProvider.primaryCookieName,
        "authjs.session-token",
        "__Secure-next-auth.session-token",
        "next-auth.session-token"
    ]
    /// Only the `__Secure-` spellings are sent back. The site is https-only, so
    /// those are the names the server reads, and a JWE session token repeated
    /// under every candidate name builds a Cookie header large enough to be
    /// rejected before it reaches the app.
    private var outgoingCookieNames: [String] {
        let secure = cookieNames.filter { $0.hasPrefix("__Secure-") }
        return secure.isEmpty ? cookieNames : secure
    }

    /// Every extractor matches host substrings, so the bare apex picks up
    /// `www.perplexity.ai` and `.perplexity.ai` in one pass over each browser's
    /// store — and one pass is worth having, since a pass copies the whole
    /// cookie database and decrypts every row it returns.
    private static let cookieDomain = "perplexity.ai"

    private let session = SessionStore.shared
    private let userDefaults = UserDefaults.standard
    private let enabledKey: String

    public init(accountID: String? = nil) {
        self.accountID = accountID
        self.id = accountID.map { "perplexity#\($0)" } ?? "perplexity"
        self.enabledKey = "aibars.\(self.id).enabled"
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = SessionStore.shared.hasCredential(for: id)
    }

    /// The internal /account/usage route the credits endpoint belongs to is not
    /// a page a user can be sent to, so the click-through goes to the settings
    /// page that shows the same subscription.
    public var dashboardURL: URL? { URL(string: "https://www.perplexity.ai/settings/account") }

    public var webLogin: WebLoginConfig? {
        // Perplexity has no /login route — the marketing page shows a sign-in
        // modal, so that is where the user is sent.
        WebLoginConfig(
            startURL: URL(string: "https://www.perplexity.ai/")!,
            capture: .cookie(name: Self.primaryCookieName, domainSuffix: Self.cookieDomain),
            hint: "Sign in as usual — aibars picks up the session automatically.",
            dataDomains: ["perplexity.ai", "www.perplexity.ai"],
            alternateCookieNames: Array(cookieNames.dropFirst())
        )
    }

    /// Unofficial: this is the endpoint the perplexity.ai /account/usage page
    /// calls for itself. There is no documented plan or subscription endpoint,
    /// which is why the plan name is inferred from the recurring grant size.
    public func fetchUsage() async throws -> UsageData {
        guard let token = session.token(for: id) else {
            throw ProviderError.notAuthenticated
        }

        let url = URL(string: "https://www.perplexity.ai/rest/billing/credits?version=2.18&source=default")!
        let http = ProviderHTTP(headers: [
            "Cookie": cookieHeader(for: token),
            "Origin": "https://www.perplexity.ai",
            "Referer": "https://www.perplexity.ai/account/usage",
            // The default aibars agent string gets this endpoint a 403.
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"
        ])

        do {
            let (data, _) = try await http.get(url)
            // A bot check answers 200 with HTML, so a failed decode is reported
            // as itself rather than as a missing balance.
            guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw ProviderError.parse("Credits endpoint returned \(data.count) bytes that are not a JSON object")
            }
            let usage = try PerplexityUsageParser.parse(raw)
            await MainActor.run { self.lastError = nil }
            return usage
        } catch let error as ProviderError {
            await MainActor.run {
                self.lastError = error
                // An expired session has to put the row back to "Sign in";
                // otherwise it shows an error it can never recover from.
                if error.isAuth { self.isAuthenticated = false }
            }
            throw error
        }
    }

    public func authenticate() async throws {
        guard let found = Self.resolveSessionCookie(names: cookieNames, domain: Self.cookieDomain) else { return }
        try session.setToken(found.value, for: id, source: .browserCookie, accountHint: found.browser.displayName)
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

    // MARK: - Cookie plumbing

    /// The shared search handles the whole-cookie case. Auth.js also splits a
    /// value past the 4KB per-cookie limit into `<name>.0`, `<name>.1`, … which
    /// no name lookup can match, so those are reassembled here as a fallback.
    private static func resolveSessionCookie(
        names: [String],
        domain: String
    ) -> (value: String, browser: BrowserCookie.Browser)? {
        if let cookie = CookieExtractors.firstAvailableCookie(named: names, for: domain) {
            return (cookie.value, cookie.source)
        }
        for extractor in CookieExtractors.available() {
            let jar = (try? extractor.cookies(for: domain)) ?? []
            for name in names {
                let chunks = jar
                    .compactMap { cookie -> (Int, String)? in
                        guard cookie.name.hasPrefix(name + "."),
                              let index = Int(cookie.name.dropFirst(name.count + 1)),
                              !cookie.value.isEmpty
                        else { return nil }
                        return (index, cookie.value)
                    }
                    .sorted { $0.0 < $1.0 }
                if !chunks.isEmpty {
                    return (chunks.map { $0.1 }.joined(), extractor.browser)
                }
            }
        }
        return nil
    }

    /// A stored token is a bare JWT with no record of which cookie name it came
    /// from, so it goes out under each outgoing name — the server reads the one
    /// it expects and ignores the rest. A token that already carries any of the
    /// known names is passed through, wherever in the string that pair sits:
    /// pasting a whole `document.cookie` dump is the common way this arrives.
    private func cookieHeader(for token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if cookieNames.contains(where: { trimmed.contains($0 + "=") }) { return trimmed }
        return outgoingCookieNames.map { "\($0)=\(trimmed)" }.joined(separator: "; ")
    }
}

public enum PerplexityUsageParser {
    /// Every amount in this response is integer cents and every timestamp is
    /// Unix seconds. Credits are surfaced in whole units (cents / 100) because
    /// that's the number the account page shows.
    public static func parse(_ raw: [String: Any], now: Date = Date()) throws -> UsageData {
        let root = unwrap(raw)

        let balance = number(root, "balance_cents", "balanceCents", "balance")
        let reportedUsage = number(root, "total_usage_cents", "totalUsageCents", "total_usage", "usage_cents")
        let reportedPurchased = number(
            root,
            "current_period_purchased_cents", "currentPeriodPurchasedCents", "purchased_cents"
        ) ?? 0
        let renewal = timestamp(
            root["renewal_date_ts"] ?? root["renewalDateTs"] ?? root["renewal_date"] ?? root["next_renewal_ts"]
        )

        let grants = (root["credit_grants"] ?? root["creditGrants"] ?? root["grants"]) as? [[String: Any]] ?? []

        guard reportedUsage != nil || balance != nil || !grants.isEmpty else {
            throw ProviderError.parse("No credit balance or grants in Perplexity billing response")
        }

        func grantTotal(_ wanted: Pool, requireUnexpired: Bool = false) -> Double {
            grants.reduce(0) { total, grant in
                guard pool(of: grant) == wanted else { return total }
                if requireUnexpired, let expiresAt = expiry(of: grant), expiresAt <= now { return total }
                return total + (number(grant, "amount_cents", "amountCents", "amount") ?? 0)
            }
        }

        let recurringTotal = grantTotal(.recurring)
        // Expired promos still ship in the array; counting them inflates the pool.
        let promoTotal = grantTotal(.promotional, requireUnexpired: true)
        // Purchased credits appear as a grant, as a top-level field, or both.
        let purchasedTotal = max(grantTotal(.purchased), reportedPurchased)

        let pools = recurringTotal + promoTotal + purchasedTotal
        // If the server omits total_usage_cents, the remaining balance implies it.
        var unallocated = reportedUsage ?? max(pools - (balance ?? pools), 0)
        func drain(_ capacity: Double) -> Double {
            let used = min(max(unallocated, 0), capacity)
            unallocated -= used
            return used
        }
        // Waterfall order matches perplexity.ai: the subscription pool burns
        // first, then anything bought, then free bonus credits.
        let recurringUsed = drain(recurringTotal)
        let purchasedUsed = drain(purchasedTotal)
        let promoUsed = drain(promoTotal)

        let promoExpiry = grants
            .filter { pool(of: $0) == .promotional }
            .compactMap { expiry(of: $0) }
            .filter { $0 > now }
            .min()

        let recurring = metric(
            label: "Credits",
            pool: .recurring,
            usedCents: recurringUsed,
            totalCents: recurringTotal,
            resetDate: renewal,
            windowLabel: nil,
            windowDuration: periodDuration(root, renewal: renewal)
        )
        let promo = metric(
            label: "Bonus",
            pool: .promotional,
            usedCents: promoUsed,
            totalCents: promoTotal,
            resetDate: nil,
            windowLabel: promoExpiry.map { "exp. \(shortDate.string(from: $0))" },
            // A promo grant runs out, it does not come back, so there is no
            // reset for a pace notch to be measured against even when the
            // response dates both ends of it.
            windowDuration: nil
        )
        // Purchased credits don't expire and don't reset, so no window — and
        // therefore no length either.
        let purchased = metric(
            label: "Purchased",
            pool: .purchased,
            usedCents: purchasedUsed,
            totalCents: purchasedTotal,
            resetDate: nil,
            windowLabel: nil,
            windowDuration: nil
        )

        // A promo-only or purchase-only account must not lead with a 0/0
        // subscription bar — it reads as broken. Lead with the pool that has
        // credits in it instead.
        var lanes: [UsageMetric] = []
        if recurringTotal > 0 { lanes.append(recurring) }
        if promoTotal > 0 { lanes.append(promo) }
        if purchasedTotal > 0 { lanes.append(purchased) }

        // Free accounts have no pools at all; limit 0 keeps that status-only
        // rather than showing as fully consumed. The label carries the whole
        // message, because a status row renders nothing else. No window key: it
        // is not one of Perplexity's pools, so there is no series for it to be
        // filed under, and the day the account starts a subscription its
        // readings belong to the recurring pool rather than behind this.
        let primary = lanes.first ?? UsageMetric(label: "No credit pool", used: 0, limit: 0)

        return UsageData(
            providerID: "perplexity",
            planName: planName(recurringCents: recurringTotal),
            primary: primary,
            secondary: Array(lanes.dropFirst()),
            rawJSON: try? JSONSerialization.data(withJSONObject: raw).base64EncodedString()
        )
    }

    // MARK: - Internals

    private enum Pool {
        case recurring, promotional, purchased

        /// The series this pool's lane is filed under, pinned to the pool rather
        /// than to the label above it. Two things move that the key must not
        /// follow: the labels are this file's own wording, and which pool leads
        /// changes with the account — a promo-only account leads with "Bonus"
        /// and a subscription puts it second. Keyed on the slot or the label,
        /// the day either moves the series forks and every reading behind it is
        /// orphaned.
        var windowKey: String {
            switch self {
            case .recurring:   return "recurring_credits"
            case .promotional: return "promotional_credits"
            case .purchased:   return "purchased_credits"
            }
        }
    }

    /// The endpoint returns credits at the top level, but a wrapper key is the
    /// most common way an API like this changes shape.
    private static func unwrap(_ raw: [String: Any]) -> [String: Any] {
        if raw["credit_grants"] != nil || raw["balance_cents"] != nil || raw["total_usage_cents"] != nil {
            return raw
        }
        for key in ["data", "billing", "credits", "result"] {
            if let nested = raw[key] as? [String: Any] { return nested }
        }
        return raw
    }

    /// Grant `type` strings are not documented anywhere, so the match is on
    /// substrings: a rename to "monthly_subscription" or "promo_credit" still
    /// lands in the right pool. Anything unrecognised — including a grant with
    /// no type at all — counts towards the subscription pool, because dropping
    /// it would show a paying account an empty bar and a "Free" plan badge.
    private static func pool(of grant: [String: Any]) -> Pool {
        let type = (grant["type"] as? String
                    ?? grant["grant_type"] as? String
                    ?? grant["kind"] as? String ?? "").lowercased()
        if type.contains("promo") || type.contains("bonus") || type.contains("gift") || type.contains("trial") {
            return .promotional
        }
        if type.contains("purchas") || type.contains("top") || type.contains("paid") || type.contains("one_time") {
            return .purchased
        }
        return .recurring
    }

    private static func expiry(of grant: [String: Any]) -> Date? {
        timestamp(grant["expires_at_ts"] ?? grant["expiresAtTs"] ?? grant["expires_at"])
    }

    private static func number(_ dict: [String: Any], _ keys: String...) -> Double? {
        for key in keys {
            if let value = ProviderNumber.coerce(dict[key]) { return value }
        }
        return nil
    }

    /// Seconds by contract, but accept milliseconds and ISO strings rather than
    /// render a reset date in 1970 or 55000 AD.
    private static func timestamp(_ value: Any?) -> Date? {
        if let string = value as? String, Double(string) == nil {
            return ProviderDate.parse(string)
        }
        guard let seconds = ProviderNumber.coerce(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds)
    }

    private static func metric(
        label: String,
        pool: Pool,
        usedCents: Double,
        totalCents: Double,
        resetDate: Date?,
        windowLabel: String?,
        windowDuration: TimeInterval?
    ) -> UsageMetric {
        UsageMetric(
            label: label,
            used: credits(fromCents: usedCents),
            limit: credits(fromCents: totalCents),
            unit: "credits",
            resetDate: resetDate,
            windowLabel: windowLabel,
            windowDuration: windowDuration,
            windowKey: pool.windowKey
        )
    }

    /// How long the subscription period is, and only when the response names
    /// both of its edges.
    ///
    /// The recurring pool is the one lane here that is a window: it refills at
    /// `renewal_date_ts`, so the meter can draw a pace notch on it — but only
    /// against a length Perplexity states. The renewal date alone gives the far
    /// edge and nothing gives the near one, and filling that in with a flat 30
    /// days would put the notch most of a day out on every 31-day month and
    /// three days out in February. Both edges or neither, as with the promo
    /// expiry above: half a period is not a period.
    private static func periodDuration(_ root: [String: Any], renewal: Date?) -> TimeInterval? {
        guard let renewal else { return nil }
        let start = timestamp(
            root["current_period_start_ts"] ?? root["currentPeriodStartTs"]
                ?? root["current_period_start"] ?? root["period_start_ts"]
        )
        guard let start else { return nil }
        let length = renewal.timeIntervalSince(start)
        // A non-positive length is not a short period, it is a pair of dates
        // that cannot be divided by; the same goes for what an "inf" in the
        // JSON would produce.
        guard length > 0, length.isFinite else { return nil }
        return length
    }

    /// Rounding to whole cents first keeps a part-spent credit exact and float
    /// noise (27.499999999999996) out of the UI.
    private static func credits(fromCents cents: Double) -> Double {
        cents.rounded() / 100
    }

    /// There is no plan field in this response. Pro grants a small monthly pool,
    /// Max grants ~100 credits; Enterprise and Education seats are
    /// indistinguishable here and will read as one of the two.
    private static func planName(recurringCents: Double) -> String {
        if recurringCents <= 0 { return "Free" }
        return recurringCents < 5_000 ? "Pro" : "Max"
    }

    private static let shortDate: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d"
        return f
    }()
}
