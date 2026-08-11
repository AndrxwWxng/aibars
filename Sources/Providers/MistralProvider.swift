import Foundation
import SwiftUI

/// Tracks month-to-date API spend, credit balance, and coding-plan quota for a
/// Mistral account.
///
/// Auth: the Ory Kratos session cookie that admin.mistral.ai is signed in with.
/// Mistral does publish an official usage API (`GET /v1/admin/usage` on
/// api.mistral.ai, `x-api-key`), and it returns the same field names as the
/// console endpoint used here — but that key is Enterprise-only, in preview, and
/// minted in a separate Backoffice, while an ordinary La Plateforme key from
/// console.mistral.ai returns nothing at all for billing. The session cookie is
/// the only route an ordinary signed-in user has.
///
/// The session cookie's name carries a project slug (`ory_session_<slug>`), so
/// there is no fixed name to look up: the credential stored for this provider is
/// a whole `Cookie` header, the way GrokProvider's is.
public final class MistralProvider: ObservableObject, UsageProvider {
    public let id: String
    /// The account this instance follows, when a service is signed into more
    /// than once. Nil is the only-account case.
    public let accountID: String?
    public var serviceID: String { "mistral" }
    public let displayName = "Mistral"
    public let iconName = "wind"
    /// Mistral's #FA500F.
    public let accentColor: Color = Color(red: 0.98, green: 0.31, blue: 0.06)

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var lastError: ProviderError?

    /// Ory Network names the session cookie after the project
    /// (`ory_session_<slug>`), and a Kratos deployment can slug the older name
    /// the same way, so both are matched as prefixes rather than listed.
    private static let sessionCookiePrefixes = ["ory_session", "ory_kratos_session"]
    /// The unslugged names, which are what a bare pasted value has to be sent
    /// under and the only ones an exact-name cookie search can find.
    private static let fixedSessionCookieNames = ["ory_kratos_session", "ory_session"]
    /// Stands in for a name aibars cannot know until it has seen the jar: the
    /// login window shows it and the shared sweep searches for it, and both
    /// match exactly. `authenticate()` does the prefix search this cannot.
    private static let capturedCookieName = "ory_session_"

    /// Chromium matches `host_key` on a substring, so the bare apex covers
    /// admin, auth, and console in a single pass over each cookie store — and a
    /// pass copies the whole database, so one is worth having.
    private static let cookieDomain = "mistral.ai"

    private let session = SessionStore.shared
    private let userDefaults = UserDefaults.standard
    private let enabledKey: String

    public init(accountID: String? = nil) {
        self.accountID = accountID
        self.id = accountID.map { "mistral#\($0)" } ?? "mistral"
        self.enabledKey = "aibars.\(self.id).enabled"
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = SessionStore.shared.hasCredential(for: id)
    }

    public var dashboardURL: URL? { URL(string: "https://admin.mistral.ai/organization/usage") }

    public var webLogin: WebLoginConfig? {
        // Signed-out requests to admin.mistral.ai land on Ory's hosted login and
        // come back to the usage page, which is when the session is written.
        guard let startURL = URL(string: "https://auth.mistral.ai/self-service/login/browser?return_to=https%3A%2F%2Fadmin.mistral.ai%2Forganization%2Fusage") else {
            return nil
        }
        return WebLoginConfig(
            startURL: startURL,
            capture: .cookie(name: Self.capturedCookieName, domainSuffix: Self.cookieDomain),
            hint: "Sign in as usual. If aibars doesn't pick the session up, open admin.mistral.ai and paste its whole cookie header below — Mistral names the session cookie after your project, so there is no fixed name to look for.",
            dataDomains: ["mistral.ai", "admin.mistral.ai", "auth.mistral.ai", "console.mistral.ai"],
            alternateCookieNames: Self.fixedSessionCookieNames
        )
    }

    /// Unofficial: `/api/billing/v2/usage` is what the admin.mistral.ai usage
    /// page calls for itself, and the only one of the three requests here that
    /// may fail the refresh. The balance and the coding-plan quota are
    /// best-effort — the balance because it is a second row rather than the
    /// point, the quota because it depends on a CSRF cookie that may not be in
    /// the jar we were handed.
    ///
    /// The `/v2/` in that path means `v1` was retired once already, so expect
    /// this to need maintenance.
    public func fetchUsage() async throws -> UsageData {
        guard let token = session.token(for: id) else {
            throw ProviderError.notAuthenticated
        }
        guard let usageURL = Self.usageURL(for: Date()) else {
            throw ProviderError.configuration("Could not build the Mistral usage URL for this month.")
        }

        let header = cookieHeader(for: token)
        let csrf = Self.csrfToken(in: header)

        do {
            let (data, _) = try await ProviderHTTP(
                headers: adminHeaders(cookie: header, csrf: csrf, page: "usage")
            ).get(usageURL)

            // Ory answers a signed-out request with a redirect to a login page,
            // which arrives as HTML with a 200. Reporting that as itself is the
            // difference between "session expired" and blaming the parser.
            guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw ProviderError.parse("Usage endpoint returned \(data.count) bytes that are not a JSON object")
            }

            let credits = await balancePayload(cookie: header, csrf: csrf)
            let vibe = await vibePayload(cookie: Self.consoleCookieHeader(from: header), csrf: csrf)
            let usage = try MistralUsageParser.parse(raw, credits: credits, vibe: vibe)
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
        let lookup = Task.detached(priority: .utility) {
            MistralProvider.resolveCookieHeader()
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

    // MARK: - Endpoints

    /// The month is read in UTC. The endpoint buckets by UTC month, so a local
    /// calendar asks for the wrong one for part of the first and last day of
    /// every month — and gets an empty answer rather than an error.
    public static func usageURL(for date: Date) -> URL? {
        var calendar = Calendar(identifier: .gregorian)
        guard let utc = TimeZone(identifier: "UTC") else { return nil }
        calendar.timeZone = utc
        let parts = calendar.dateComponents([.year, .month], from: date)
        guard let year = parts.year, let month = parts.month else { return nil }
        return URL(string: "https://admin.mistral.ai/api/billing/v2/usage?month=\(month)&year=\(year)")
    }

    private static let creditsURL = URL(string: "https://admin.mistral.ai/api/billing/credits")
    /// The tRPC batch envelope the console's own client sends, percent-encoded
    /// exactly as it appears there — the route rejects a plainer query.
    private static let vibeURL = URL(string: "https://console.mistral.ai/api-ui/trpc/billing.vibeUsage?batch=1&input=%7B%220%22%3A%7B%22json%22%3Anull%2C%22meta%22%3A%7B%22values%22%3A%5B%22undefined%22%5D%2C%22v%22%3A1%7D%7D%7D")

    private func adminHeaders(cookie: String, csrf: String?, page: String) -> [String: String] {
        var headers = [
            "Cookie": cookie,
            "Origin": "https://admin.mistral.ai",
            "Referer": "https://admin.mistral.ai/organization/\(page)",
            "Accept": "*/*",
            // A console endpoint behind Cloudflare; the default aibars agent
            // string is the shape its bot rules look for.
            "User-Agent": Self.browserUserAgent
        ]
        // Upper-cased for admin.mistral.ai and mixed-case for the console. The
        // difference is what Mistral's own client sends, so it is copied rather
        // than normalised.
        if let csrf { headers["X-CSRFTOKEN"] = csrf }
        return headers
    }

    /// Four seconds, not the usual fifteen: this is a secondary row, and a slow
    /// balance must not hold up usage that has already arrived.
    private func balancePayload(cookie: String, csrf: String?) async -> [String: Any]? {
        guard let url = Self.creditsURL else { return nil }
        let http = ProviderHTTP(
            headers: adminHeaders(cookie: cookie, csrf: csrf, page: "billing"),
            timeout: 4
        )
        guard let payload = (try? await http.get(url))?.0 else { return nil }
        return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }

    /// The console route is mandatory-CSRF, so there is nothing to try without
    /// the cookie. The response is a tRPC batch — an array, not an object — so
    /// this hands back `Any` and lets the parser unwrap it.
    private func vibePayload(cookie: String, csrf: String?) async -> Any? {
        guard let url = Self.vibeURL, let csrf, !cookie.isEmpty else { return nil }
        let http = ProviderHTTP(headers: [
            "Cookie": cookie,
            "Origin": "https://console.mistral.ai",
            "Referer": "https://console.mistral.ai/",
            "Accept": "*/*",
            "X-CSRFToken": csrf,
            "User-Agent": Self.browserUserAgent
        ], timeout: 4)
        guard let payload = (try? await http.get(url))?.0 else { return nil }
        return try? JSONSerialization.jsonObject(with: payload)
    }

    // MARK: - Cookie plumbing

    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    private struct ResolvedCookies {
        let header: String
        let browser: BrowserCookie.Browser
    }

    /// Walks every installed browser for a session cookie whose name starts with
    /// `ory_session`, taking the first browser that has one. The CSRF cookie rides
    /// along because the console quota route refuses a request without it.
    ///
    /// Silent: no keychain prompt. A sweep the user did not explicitly ask for
    /// must not put a password dialog on screen.
    private static func resolveCookieHeader() -> ResolvedCookies? {
        for extractor in CookieExtractors.available() {
            let jar = (try? extractor.cookies(for: cookieDomain)) ?? []
            guard let sessionCookie = jar.first(where: { isSessionCookie($0.name) && !$0.value.isEmpty }) else {
                continue
            }
            var pairs = ["\(sessionCookie.name)=\(sessionCookie.value)"]
            if let csrf = jar.first(where: { isCSRFCookie($0.name) && !$0.value.isEmpty }) {
                pairs.append("\(csrf.name)=\(csrf.value)")
            }
            return ResolvedCookies(header: pairs.joined(separator: "; "), browser: extractor.browser)
        }
        return nil
    }

    private static func isSessionCookie(_ name: String) -> Bool {
        sessionCookiePrefixes.contains { name.hasPrefix($0) }
    }

    /// The admin endpoints accept the session on its own; the console tRPC route
    /// refuses a request that carries no CSRF cookie. Ory writes that token under
    /// whichever of `csrf_token`, `__HOST-csrf_token` or `csrf_token_<hash>` its
    /// deployment calls for, so the name is matched rather than listed.
    private static func isCSRFCookie(_ name: String) -> Bool {
        name.lowercased().contains("csrf")
    }

    /// A stored credential is normally a whole `Cookie` header — either built by
    /// `authenticate()` or pasted from `document.cookie` — and goes out
    /// untouched. A bare value can only be sent under a guessed name, and the
    /// real one carries a project slug we cannot reconstruct, so both fixed Ory
    /// names are tried; if the account's cookie is `ory_session_<slug>` the
    /// service will reject it and the row falls back to asking for a paste.
    ///
    /// Testing for a bare "=" would not do: an Ory session value is base64 and
    /// can carry its own padding, and a header of nothing but that value is sent
    /// under no name at all — a session the server never sees, and a row that
    /// cannot be made to work by pasting harder. A pair whose name we recognise,
    /// or more than one pair, is a header; anything else is a value.
    private func cookieHeader(for token: String) -> String {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = Self.pairs(in: trimmed)
        let named = parsed.contains { Self.isSessionCookie($0.name) || Self.isCSRFCookie($0.name) }
        if named || parsed.count > 1 { return trimmed }
        return Self.fixedSessionCookieNames.map { "\($0)=\(trimmed)" }.joined(separator: "; ")
    }

    /// Only the session and CSRF pairs, for the console request.
    ///
    /// A pasted `document.cookie` dump carries analytics and consent cookies for
    /// whichever host it came from, and admin's jar is not console's — sending
    /// the lot cross-host is how the wrong session ends up being presented.
    private static func consoleCookieHeader(from header: String) -> String {
        pairs(in: header)
            .filter { isSessionCookie($0.name) || isCSRFCookie($0.name) }
            .map { "\($0.name)=\($0.value)" }
            .joined(separator: "; ")
    }

    private static func csrfToken(in header: String) -> String? {
        pairs(in: header).first { isCSRFCookie($0.name) }?.value
    }

    /// Splits at the first `=` only: a cookie value may contain more of them.
    private static func pairs(in header: String) -> [(name: String, value: String)] {
        header.split(separator: ";").compactMap { piece in
            let text = piece.trimmingCharacters(in: .whitespaces)
            guard let separator = text.firstIndex(of: "=") else { return nil }
            let name = String(text[text.startIndex..<separator])
            let value = String(text[text.index(after: separator)...])
            guard !name.isEmpty, !value.isEmpty else { return nil }
            return (name, value)
        }
    }
}

public enum MistralUsageParser {
    /// `GET /api/billing/v2/usage?month=&year=`, which returns the same field
    /// names as the documented `GET /v1/admin/usage`:
    ///
    ///     { "completion": { "models": { "<model>": { "input":  [entry],
    ///                                               "output": [entry],
    ///                                               "cached": [entry] } } },
    ///       "chat": …, "ocr": …, "connectors": …, "audio": …,
    ///       "libraries_api": { "pages":    { "models": {…} },
    ///                          "tokens":   { "models": {…} } },
    ///       "fine_tuning":   { "training": { "<model>": {…} },
    ///                          "storage":  { "<model>": {…} } },
    ///       "vibe_usage": 3, "start_date": "…", "end_date": "…",
    ///       "currency": "USD", "currency_symbol": "$",
    ///       "prices": [ { "event_type": "…", "billing_metric": "…",
    ///                     "billing_group": "…", "price": "0.000002" } ] }
    ///
    /// where an `entry` is
    ///
    ///     { "usage_type": "…", "event_type": "…", "billing_metric": "…",
    ///       "billing_display_name": "…", "billing_group": "…",
    ///       "timestamp": "<ISO8601>", "value": 1000, "value_paid": 800 }
    ///
    /// The categories above are the ones documented, not the ones summed: every
    /// top-level container that is not the price table is walked, because Mistral
    /// bills event types that appear here without ever being written down.
    ///
    /// No cost is returned: each entry is joined to `prices` on the
    /// (event_type, billing_metric, billing_group) triple and multiplied out
    /// here. Every category and every field inside one is optional.
    ///
    /// The `start_date`/`end_date` pair is the only window length any of these
    /// responses states, so the spend and token rows are the only ones that
    /// carry a `windowDuration`. The quota knows when it resets but never over
    /// what, and a balance is not a window at all.
    ///
    /// `credits` is `GET /api/billing/credits`; `vibe` is the console's
    /// `billing.vibeUsage` tRPC batch. Both are best-effort and may be nil.
    public static func parse(
        _ raw: [String: Any],
        credits: [String: Any]? = nil,
        vibe: Any? = nil,
        now: Date = Date()
    ) throws -> UsageData {
        let root = unwrap(raw)
        let prices = priceTable(root["prices"] ?? root["price_table"] ?? root["priceTable"])
        let entries = usageEntries(in: billableSubtrees(in: root))

        var cost: Double = 0
        var tokens: Double = 0
        for entry in entries {
            cost += entryCost(entry, prices: prices)
            guard countsTokens(entry) else { continue }
            // Tokens are reported from `value`, not `value_paid`: the question a
            // token count answers is how much was used, not how much of it was
            // billed.
            tokens += number(entry, "value", "Value") ?? 0
        }

        let balance = credits.flatMap { availableBalance($0) }
        let quota = vibe.flatMap { vibeQuota($0) }
        let reportedVibe = number(root, "vibe_usage", "vibeUsage")

        // A month with no spend yet is a real answer — a category present and
        // empty says so. A response with no category container, nothing billed,
        // no balance and no quota is not this endpoint's response at all; most
        // often it is Ory's login page or an error body arriving with a 200.
        let namesACategory = knownCategoryKeys.contains { tree(root[$0]) != nil }
        guard namesACategory || !entries.isEmpty || balance != nil || quota != nil || reportedVibe != nil else {
            throw ProviderError.parse("No usage categories, balance, or quota in Mistral billing response")
        }

        let currency = (string(root, "currency", "currency_code", "currencyCode")
                        ?? balance?.currency
                        ?? "USD").uppercased()
        // The billing month's own end, when the response names it; a spend
        // figure with no window attached reads as a lifetime total.
        let periodEnd = string(root, "end_date", "endDate", "next_month", "nextMonth")
            .flatMap { ProviderDate.parse($0) }
        let periodStart = string(root, "start_date", "startDate").flatMap { ProviderDate.parse($0) }
        let periodLength = billingPeriod(from: periodStart, to: periodEnd)

        // Spend has no ceiling here — a spend limit exists only on the
        // Enterprise admin API — so it stays status-only rather than being
        // rendered as a fraction of a number we invented. Floored at zero: a
        // refund is settled on the invoice rather than fed back through usage,
        // so a negative month-to-date is arithmetic noise, and "-0" in a menu bar
        // row reads as a bug.
        let spend = UsageMetric(
            label: "Spend",
            used: rounded(max(cost, 0)),
            limit: 0,
            unit: currency,
            resetDate: periodEnd,
            windowLabel: "Month to date",
            // The period this response states the two ends of, and nothing when
            // it states fewer than two of them. The month aibars asked for is
            // not evidence of the month the account is billed on.
            windowDuration: periodLength,
            windowKey: "billing_period_spend"
        )

        let vibeMetric = quota.map {
            UsageMetric(
                label: "Vibe quota",
                used: $0.percent,
                limit: 100,
                unit: "%",
                resetDate: $0.resetAt,
                windowLabel: "Monthly",
                // The console gives the instant this resets and never the
                // window's length. "Monthly" above is Mistral's own wording for
                // the plan, not a duration it stated, so there is nothing here
                // to hang a pace notch on.
                windowDuration: nil,
                windowKey: "vibe_usage_percentage"
            )
        }

        // The coding-plan percentage is the only real bar Mistral reports, so it
        // leads when it is there. Everything else is a figure without a ceiling.
        let primary = vibeMetric ?? spend
        var secondary: [UsageMetric] = []
        if vibeMetric != nil { secondary.append(spend) }
        if let balance {
            secondary.append(UsageMetric(
                label: "Balance",
                used: rounded(balance.amount),
                limit: 0,
                unit: balance.currency,
                // A wallet is not a window: it never resets, so it has no
                // length and no pace to keep. Written out rather than left to
                // the default so nobody fills it in later.
                windowDuration: nil,
                windowKey: "credit_balance"
            ))
        }
        if tokens > 0 {
            secondary.append(UsageMetric(
                label: "Tokens",
                used: tokens,
                limit: 0,
                unit: "tokens",
                resetDate: periodEnd,
                windowLabel: "Month to date",
                // The same billing period the spend row is measured over,
                // because it is the same response's dates.
                windowDuration: periodLength,
                windowKey: "billing_period_tokens"
            ))
        }
        // `vibe_usage` in the usage payload is a bare number with no documented
        // unit, so it is only worth showing when the console percentage — which
        // is unambiguous — could not be read.
        if quota == nil, let reportedVibe, reportedVibe > 0 {
            secondary.append(UsageMetric(
                label: "Vibe",
                used: reportedVibe,
                limit: 0,
                // Keyed apart from the console percentage above even though the
                // two never appear together: one is a share of an allowance and
                // the other a bare count, and filing them as one series would
                // put 3 and 42.5 on the same chart line.
                windowKey: "vibe_usage"
            ))
        }

        return UsageData(
            providerID: "mistral",
            fetchedAt: now,
            // Nothing in any of these responses names a plan, and the endpoint
            // that would is Enterprise-only, so the row shows none rather than
            // inferring one from how much has been spent.
            planName: nil,
            primary: primary,
            secondary: secondary,
            accountLabel: accountLabel(root, credits),
            rawJSON: try? JSONSerialization.data(withJSONObject: raw).base64EncodedString()
        )
    }

    /// `GET /api/billing/credits`:
    /// `{ "wallet_amount": 50, "credit_notes_amount": 5,
    ///    "ongoing_usage_balance": 2.5, "currency": "USD" }`
    ///
    /// Available balance is wallet + credit notes − usage not yet drawn down,
    /// floored at zero: an account that has overspent its wallet reports a
    /// negative here, and "−$4 left" is not a balance.
    ///
    /// A credit figure — the wallet or the notes — has to be there. On its own,
    /// `ongoing_usage_balance` is a debit with nothing to draw it against, and
    /// subtracting it from an assumed zero wallet reports "0 left" to an account
    /// whose balance this response never stated.
    public static func availableBalance(_ raw: [String: Any]) -> (amount: Double, currency: String)? {
        let root = creditsRoot(raw)
        let wallet = money(root, "wallet_amount", "walletAmount", "wallet", "balance")
        let notes = money(root, "credit_notes_amount", "creditNotesAmount", "credit_notes")
        guard wallet != nil || notes != nil else { return nil }
        let ongoing = money(root, "ongoing_usage_balance", "ongoingUsageBalance", "ongoing_usage") ?? 0
        let available = max((wallet ?? 0) + (notes ?? 0) - ongoing, 0)
        guard available.isFinite else { return nil }
        return (available, (string(root, "currency", "currency_code", "currencyCode") ?? "USD").uppercased())
    }

    /// Unwraps the console's tRPC batch:
    /// `[ { "result": { "data": { "json": { "usage_percentage": 42.5,
    ///                                      "reset_at": "<ISO8601>" } } } } ]`
    ///
    /// Clamped to 100 rather than refused above it: an account past its allowance
    /// is exactly the account that needs this row, and dropping the only real bar
    /// Mistral reports because the number went over the ceiling leaves it with a
    /// spend figure and no quota at all. The bar is full either way, so the
    /// overshoot is the one part not worth carrying.
    ///
    /// Nil for a negative, and nil past `impossiblePercent`, where the field
    /// cannot be the percentage its name claims.
    public static func vibeQuota(_ raw: Any) -> (percent: Double, resetAt: Date?)? {
        let head = (raw as? [Any])?.first ?? raw
        guard var node = head as? [String: Any] else { return nil }
        // Descended one key at a time so a flatter response — or the same
        // payload without the batch wrapper — still resolves.
        for key in ["result", "data", "json"] {
            if let next = node[key] as? [String: Any] { node = next }
        }
        guard let percent = number(node, "usage_percentage", "usagePercentage", "percentage", "percent"),
              percent >= 0, percent <= impossiblePercent
        else { return nil }
        let resetAt = string(node, "reset_at", "resetAt", "resets_at", "resetsAt").flatMap { ProviderDate.parse($0) }
        return (min(percent, 100), resetAt)
    }

    /// How long the billing period is, from the two dates the usage response
    /// states itself — the one window Mistral publishes a length for.
    ///
    /// Both ends are required. A month inferred from `end_date` alone would be
    /// a calendar assumption dressed up as a reading, and the pace notch drawn
    /// against it would put a mark on the meter that no response ever supported.
    /// A period running backwards, or one long enough to be a Unix epoch
    /// arriving in a date field, is refused for the same reason.
    private static func billingPeriod(from start: Date?, to end: Date?) -> TimeInterval? {
        guard let start, let end else { return nil }
        let length = end.timeIntervalSince(start)
        guard length > 0, length.isFinite, length <= longestBillingPeriod else { return nil }
        return length
    }

    /// A year. Mistral bills monthly and the endpoint is asked for one month at
    /// a time, so anything past this is a malformed pair rather than a period.
    private static let longestBillingPeriod: TimeInterval = 366 * 24 * 60 * 60

    /// Ten times an allowance. Nobody documents a bound; this is only far enough
    /// past the ceiling that the field has to be counting something rather than
    /// measuring a share of it, and a guess at which would be worse than nothing.
    private static let impossiblePercent: Double = 1_000

    // MARK: - Categories

    /// The categories this endpoint is known to send. One of them present as a
    /// container is what tells its response apart from a login page or an error
    /// body served with a 200; the list is not what gets summed.
    private static let knownCategoryKeys = [
        "completion", "completions", "chat", "ocr", "connectors", "audio",
        "embeddings", "moderations", "agents",
        "libraries_api", "librariesApi", "fine_tuning", "fineTuning"
    ]

    /// Three spellings of one subtree. They hold the same per-model entries, so
    /// summing more than one double-counts the month.
    private static let completionKeys = ["completion", "completions", "chat"]

    /// Not usage: the price table joined against below, and nothing else at the
    /// top level is a container.
    private static let nonUsageKeys: Set<String> = ["prices", "price_table", "priceTable"]

    /// Every top-level container except those, whether or not this build has
    /// heard of it.
    ///
    /// A hard-coded list of categories was the wrong shape. Mistral bills event
    /// types that are not in the documented payload above — embeddings and agents
    /// among them — and every one it adds is spend a fixed list quietly leaves out
    /// of the figure the user checks against Mistral's own console.
    private static func billableSubtrees(in root: [String: Any]) -> [Any] {
        let completion = completionKeys.first { tree(root[$0]) != nil }
        return root.compactMap { (key, value) -> Any? in
            guard !nonUsageKeys.contains(key) else { return nil }
            guard !completionKeys.contains(key) || key == completion else { return nil }
            return tree(value)
        }
    }

    /// Anything that could contain entries. A category present as a string or a
    /// number is not a category, which is what lets `parse` tell this endpoint's
    /// response from a login page or an error body arriving with a 200.
    private static func tree(_ value: Any?) -> Any? {
        guard let value else { return nil }
        if value is [String: Any] || value is [Any] { return value }
        return nil
    }

    /// Every usage entry under `value`, wherever it sits.
    ///
    /// The nesting differs per category — `completion.models.<model>.input[]`
    /// against `fine_tuning.training.<model>` — and every level is optional, so
    /// the walk looks for the entry's own shape instead of a fixed path. The
    /// depth cap is well past the deepest documented path, counting the list of
    /// subtrees this is handed as a level of its own, and only stops an
    /// unexpected shape from becoming an expensive walk.
    private static func usageEntries(in value: Any, depth: Int = 0) -> [[String: Any]] {
        guard depth < 8 else { return [] }
        if let dict = value as? [String: Any] {
            if isEntry(dict) { return [dict] }
            return dict.values.flatMap { usageEntries(in: $0, depth: depth + 1) }
        }
        if let list = value as? [Any] {
            return list.flatMap { usageEntries(in: $0, depth: depth + 1) }
        }
        return []
    }

    private static func isEntry(_ dict: [String: Any]) -> Bool {
        let quantified = dict["value"] != nil || dict["value_paid"] != nil || dict["valuePaid"] != nil
        let billed = dict["event_type"] != nil || dict["eventType"] != nil
            || dict["billing_metric"] != nil || dict["billingMetric"] != nil
        return quantified && billed
    }

    /// Only what says it is billed per token. Now that every category is summed,
    /// including ones this build has not heard of, an entry that names no metric
    /// cannot be assumed to be tokens — pages, seconds and GB-hours would all
    /// join the count.
    ///
    /// Fine-tuning is billed per training token and is deliberately out: it is
    /// not usage anyone budgets in tokens, and folding it into the inference
    /// figure makes that figure unrecognisable next to Mistral's console.
    private static func countsTokens(_ entry: [String: Any]) -> Bool {
        guard let metric = string(entry, "billing_metric", "billingMetric"),
              metric.lowercased().contains("token")
        else { return false }
        let event = (string(entry, "event_type", "eventType") ?? "").lowercased()
        return !event.contains("fine") && !event.contains("train")
    }

    // MARK: - Cost

    /// `value_paid` first, so usage covered by the free tier or by a grant is
    /// not billed twice — once by Mistral's ledger and once here.
    private static func entryCost(_ entry: [String: Any], prices: [String: Double]) -> Double {
        let quantity = number(entry, "value_paid", "valuePaid") ?? number(entry, "value", "Value") ?? 0
        guard let price = price(for: entry, in: prices) else { return 0 }
        return finite(quantity * price)
    }

    /// The price table, keyed on the full triple and on two coarser forms.
    ///
    /// A coarser key is only registered when every row that shares it agrees on
    /// the price — the fallback exists for a response that stops sending
    /// `billing_group`, not to resolve an ambiguity to whichever row came last.
    private static func priceTable(_ value: Any?) -> [String: Double] {
        guard let rows = value as? [[String: Any]] else { return [:] }
        var candidates: [String: [Double]] = [:]
        for row in rows {
            guard let price = money(row, "price", "unit_price", "unitPrice", "amount") else { continue }
            let event = string(row, "event_type", "eventType") ?? ""
            let metric = string(row, "billing_metric", "billingMetric") ?? ""
            let group = string(row, "billing_group", "billingGroup") ?? ""
            for key in [priceKey(event, metric, group), priceKey(event, metric, ""), priceKey(event, "", "")] {
                candidates[key, default: []].append(price)
            }
        }
        return candidates.compactMapValues { values in
            let distinct = Set(values)
            return distinct.count == 1 ? distinct.first : nil
        }
    }

    /// The price is per unit of `billing_metric`, so the multiplication is
    /// direct — this table does not carry the per-million figures the public
    /// pricing page quotes.
    private static func price(for entry: [String: Any], in prices: [String: Double]) -> Double? {
        let event = string(entry, "event_type", "eventType") ?? ""
        let metric = string(entry, "billing_metric", "billingMetric") ?? ""
        let group = string(entry, "billing_group", "billingGroup") ?? ""
        for key in [priceKey(event, metric, group), priceKey(event, metric, ""), priceKey(event, "", "")] {
            if let price = prices[key] { return price }
        }
        return nil
    }

    private static func priceKey(_ event: String, _ metric: String, _ group: String) -> String {
        "\(event)|\(metric)|\(group)"
    }

    // MARK: - Internals

    /// The payload is flat today, but a wrapper key is the most common way an
    /// undocumented endpoint changes shape.
    private static func unwrap(_ raw: [String: Any]) -> [String: Any] {
        let markers = knownCategoryKeys + [
            "prices", "price_table", "priceTable",
            "vibe_usage", "vibeUsage", "start_date", "startDate"
        ]
        if markers.contains(where: { raw[$0] != nil }) { return raw }
        for key in ["data", "usage", "result", "billing"] {
            if let nested = raw[key] as? [String: Any] { return nested }
        }
        return raw
    }

    /// The credits payload's own wrapper, shared so a nested one is read for the
    /// account label as well as for the balance.
    private static func creditsRoot(_ raw: [String: Any]) -> [String: Any] {
        (raw["credits"] as? [String: Any]) ?? (raw["data"] as? [String: Any]) ?? raw
    }

    /// The organisation behind the session, when one of these responses names
    /// it. With several Mistral accounts in one list, "Connected" leaves open
    /// the question of connected as whom.
    private static func accountLabel(_ root: [String: Any], _ credits: [String: Any]?) -> String? {
        let keys = ["organization_name", "organizationName", "organization", "workspace_name", "workspaceName", "email"]
        for source in [root, credits.map { creditsRoot($0) }].compactMap({ $0 }) {
            for key in keys {
                if let value = source[key] as? String, !value.isEmpty { return value }
            }
        }
        return nil
    }

    /// Every figure in these payloads may arrive as a JSON number or as a string.
    /// A non-finite one is treated as absent rather than passed on: `Double("nan")`
    /// parses, and one NaN reaching a sum turns the whole total into a blank row —
    /// so the check belongs here, once, rather than at each of a dozen call sites.
    private static func number(_ dict: [String: Any], _ keys: String...) -> Double? {
        for key in keys {
            if let value = ProviderNumber.coerce(dict[key]), value.isFinite { return value }
        }
        return nil
    }

    /// As above, for money and prices. Those arrive as strings here (`"0.000002"`),
    /// and a response that starts sending `"$50.00"` or `"1,234.56"` — it already
    /// sends `currency_symbol` — would otherwise drop the figure entirely.
    private static func money(_ dict: [String: Any], _ keys: String...) -> Double? {
        for key in keys {
            if let value = ProviderNumber.coerce(dict[key]), value.isFinite { return value }
            if let text = dict[key] as? String {
                let cleaned = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
                if let value = Double(cleaned), value.isFinite { return value }
            }
        }
        return nil
    }

    private static func string(_ dict: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    /// Both operands can be finite and their product not — a per-unit price
    /// against a token count leaves plenty of room — and one infinity in the
    /// running total renders the whole spend row blank.
    private static func finite(_ value: Double) -> Double {
        value.isFinite ? value : 0
    }

    /// Money to whole cents, so float noise (2.9000000000000004) stays out of
    /// the UI.
    private static func rounded(_ amount: Double) -> Double {
        (amount * 100).rounded() / 100
    }
}
