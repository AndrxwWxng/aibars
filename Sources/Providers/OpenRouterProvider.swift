import Foundation
import SwiftUI

/// Tracks the prepaid credit balance and spend on an OpenRouter account.
///
/// Auth: an inference API key (`sk-or-v1-…`), pasted by the user. OpenRouter's
/// dashboard sits behind a Clerk session and exposes no cookie-authenticated
/// usage route, so a browser session buys nothing here — the two REST endpoints
/// below carry everything aibars renders.
///
/// OpenRouter sells no subscription: billing is prepaid credits, so the headline
/// figure is a balance with no ceiling, reported status-only. A per-key spend cap
/// is the one real used/limit pair the API offers, and only when the user set one.
public final class OpenRouterProvider: ObservableObject, UsageProvider {
    public let id: String
    /// The account this instance follows, when a service is signed into more
    /// than once. Nil is the only-account case.
    public let accountID: String?
    public var serviceID: String { "openrouter" }
    public let displayName = "OpenRouter"
    public let iconName = "arrow.triangle.branch"
    public let accentColor: Color = Color(red: 0.42, green: 0.40, blue: 0.94)

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false

    private let session = SessionStore.shared
    private let userDefaults = UserDefaults.standard
    private let enabledKey: String

    public init(accountID: String? = nil) {
        self.accountID = accountID
        self.id = accountID.map { "openrouter#\($0)" } ?? "openrouter"
        self.enabledKey = "aibars.\(self.id).enabled"
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = SessionStore.shared.hasCredential(for: self.id)
            || Self.environmentToken(accountID: accountID, id: self.id) != nil
    }

    public var dashboardURL: URL? { URL(string: "https://openrouter.ai/activity") }

    public var webLogin: WebLoginConfig? {
        WebLoginConfig(
            // Signed out, this page bounces through Clerk and lands back here,
            // so it is one destination for both states.
            startURL: URL(string: "https://openrouter.ai/settings/keys")!,
            capture: .tokenShownOnPage,
            hint: "Click “Create Key”, copy the sk-or-v1-… value, then paste it below — it is only shown once.",
            dataDomains: ["openrouter.ai"]
        )
    }

    public func fetchUsage() async throws -> UsageData {
        guard let token = resolvedToken else {
            throw ProviderError.notAuthenticated
        }

        let http = ProviderHTTP(headers: [
            "Authorization": "Bearer \(token)",
            // Courtesy headers OpenRouter accepts on every route; they are what
            // names aibars in the account's own activity log.
            "HTTP-Referer": "https://github.com/aibars/aibars",
            "X-Title": "aibars"
        ])

        // Best-effort, and fetched first so the balance route decides the
        // outcome: /key carries the period spend, the key cap and the free-tier
        // flag, none of which is worth failing a refresh over.
        let key = try? await jsonObject(from: http, at: keyURL)

        do {
            let credits = try await jsonObject(from: http, at: creditsURL)
            return try OpenRouterUsageParser.parse(credits, key: key)
        } catch let error as ProviderError {
            // /credits is annotated "Management key required" and does 403 on
            // some accounts. ProviderHTTP folds 401 and 403 into
            // sessionExpired, so a rejected key and a refused route are
            // indistinguishable here — but /key answering proves the key is
            // good, and what it returned is enough to render.
            if let key, !key.isEmpty, let data = try? OpenRouterUsageParser.parse([:], key: key) {
                return data
            }
            // A revoked key has to drop the flag, or the row keeps claiming it
            // is connected and never offers to paste a new one.
            if error.isAuth {
                await MainActor.run { self.isAuthenticated = false }
            }
            throw error
        }
    }

    public func authenticate() async throws {
        if resolvedToken != nil {
            await MainActor.run { self.isAuthenticated = true }
        }
    }

    public func signOut() async throws {
        session.clear(id)
        await MainActor.run { self.isAuthenticated = false }
    }

    public func saveTokenManually(_ token: String, source: SessionSource = .manualPaste) throws {
        // Keys are copied off a page that puts a newline after the value, and
        // whatever is stored goes into an Authorization header verbatim.
        try session.setToken(token.trimmingCharacters(in: .whitespacesAndNewlines), for: id, source: .apiKey)
        Task { @MainActor in self.isAuthenticated = true }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: enabledKey)
    }

    // MARK: - Endpoints

    private static let defaultBaseURL = URL(string: "https://openrouter.ai/api/v1")!

    /// Overridable because a corporate gateway or a local proxy in front of the
    /// API is the normal way this service is reached from a managed machine.
    /// Anything that is not an http(s) host is ignored rather than attempted:
    /// `URL(string:)` accepts "credits" as a relative path and a mistyped
    /// variable would turn a working default into an unexplained failure.
    private var baseURL: URL {
        let override = ProcessInfo.processInfo.environment["OPENROUTER_API_URL"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let override, !override.isEmpty,
              let url = URL(string: override),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              url.host != nil
        else { return Self.defaultBaseURL }
        return url
    }

    private var creditsURL: URL { baseURL.appendingPathComponent("credits") }
    private var keyURL: URL { baseURL.appendingPathComponent("key") }

    private func jsonObject(from http: ProviderHTTP, at url: URL) async throws -> [String: Any] {
        let (data, _) = try await http.get(url)
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderError.parse("\(url.lastPathComponent) returned \(data.count) bytes that are not a JSON object")
        }
        return raw
    }

    // MARK: - Credential

    /// Trimmed on the way out as well as on the way in: keys stored by earlier
    /// builds kept whatever whitespace was pasted with them, and an all-blank
    /// value is not a credential.
    private var resolvedToken: String? {
        let stored = session.token(for: id) ?? Self.environmentToken(accountID: accountID, id: id)
        guard let token = stored?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return nil
        }
        return token
    }

    /// `OPENROUTER_API_KEY` is the variable every OpenRouter client reads, so a
    /// machine that already has one set needs no setup at all. Only the first
    /// account takes it — a second one inheriting the same key would report the
    /// first account's numbers twice — and a deliberate sign-out outranks it,
    /// otherwise signing out would appear to do nothing.
    private static func environmentToken(accountID: String?, id: String) -> String? {
        guard accountID == nil, !AppState.signedOutProviders.contains(id) else { return nil }
        let value = ProcessInfo.processInfo.environment["OPENROUTER_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (value?.isEmpty ?? true) ? nil : value
    }
}

public enum OpenRouterUsageParser {
    /// `credits` is GET /api/v1/credits, `key` the best-effort GET /api/v1/key.
    /// Either may be empty — a 403 on the credits route still leaves the key
    /// route's spend figures — but not both.
    ///
    /// Documented shapes, each wrapped in `data`:
    ///   /credits { "total_credits": 100.5, "total_usage": 25.75 }
    ///   /key     { "label": "…", "limit": null, "limit_remaining": null,
    ///              "limit_reset": null, "usage": 12.34, "usage_daily": 0.42,
    ///              "usage_weekly": 3.1, "usage_monthly": 12.34,
    ///              "byok_usage": 0, "is_free_tier": false }
    /// There is no balance field: it is total_credits minus total_usage.
    public static func parse(
        _ credits: [String: Any],
        key: [String: Any]? = nil,
        now: Date = Date()
    ) throws -> UsageData {
        let credit = unwrap(credits)

        // The credits route is the one this fetch hangs on, so its error
        // envelope is fatal.
        if let message = errorMessage(in: credits) {
            throw ProviderError.parse("OpenRouter: \(message)")
        }
        // The key route is best-effort. An account whose credits came back fine
        // has to keep rendering when this one is rejected, so the message is
        // held back and only reported if nothing else survives.
        let keyFailure = key.flatMap { errorMessage(in: $0) }
        let keyInfo = keyFailure == nil ? key.map(unwrap) : nil

        let purchased = number(credit, "total_credits", "totalCredits", "credits", "total_granted")
        let spent = number(credit, "total_usage", "totalUsage", "total_spent", "usage")
        // No `balance` key exists today, but subtracting is only the fallback:
        // if one ever appears it is the authoritative figure.
        var balance = number(credit, "balance", "credit_balance", "remaining_credits")
        if balance == nil, let purchased, let spent {
            balance = dollars(purchased - spent)
        }

        // Two lanes can carry a bar; the spend figures below never can.
        var rows: [UsageMetric] = []

        if let balance {
            // Prepaid credit has no ceiling, so limit stays 0: that marks the
            // metric status-only and keeps a healthy balance from rendering as
            // fully consumed. Zero is a measured zero, not missing data.
            let exhausted = balance <= 0 && ((purchased ?? 0) > 0 || (spent ?? 0) > 0)
            rows.append(UsageMetric(
                label: exhausted ? "Balance (exhausted)" : "Balance",
                used: balance,
                limit: 0,
                unit: "USD"
            ))
        } else if let purchased {
            // Credits bought, with no spend figure to subtract from them.
            // Calling that a balance would assert nothing has been spent, which
            // the response did not say.
            rows.append(UsageMetric(label: "Credits purchased", used: purchased, limit: 0, unit: "USD"))
        }

        if let keyInfo, let cap = number(keyInfo, "limit", "credit_limit", "creditLimit"), cap > 0 {
            let remaining = number(keyInfo, "limit_remaining", "limitRemaining")
            // Spend against the cap is the cap minus what's left; the key's
            // lifetime usage only matches when the cap never resets, so it is
            // the fallback rather than the source. With neither, the cap is
            // known and the spend is not, and a bar drawn at zero would be an
            // invention.
            let used = remaining.map { max(cap - $0, 0) } ?? number(keyInfo, "usage", "usage_total")
            if let used {
                let window = resetWindow(keyInfo)
                rows.append(UsageMetric(
                    label: "Key limit",
                    // Not clamped to the cap: a key that went over reads
                    // "12 / 10 USD", and `percent` already tops out at 1.
                    used: dollars(used),
                    limit: dollars(cap),
                    unit: "USD",
                    resetDate: nextReset(window, now: now),
                    windowLabel: window?.label
                ))
            }
        }

        if let spent {
            rows.append(UsageMetric(label: "Spent all time", used: dollars(spent), limit: 0, unit: "USD"))
        } else if let keyInfo, let keySpend = number(keyInfo, "usage", "usage_total") {
            // Account-wide spend needs the credits route. Without it the key's
            // own lifetime figure is the only spend there is, and it is labelled
            // as the key's because it counts one key rather than the account.
            rows.append(UsageMetric(label: "Key spend", used: dollars(keySpend), limit: 0, unit: "USD"))
        }

        if let keyInfo {
            let periods: [(String, [String])] = [
                ("Today", ["usage_daily", "usageDaily"]),
                ("This week", ["usage_weekly", "usageWeekly"]),
                ("This month", ["usage_monthly", "usageMonthly"])
            ]
            for (label, keys) in periods {
                guard let value = number(keyInfo, keys) else { continue }
                rows.append(UsageMetric(label: label, used: dollars(value), limit: 0, unit: "USD"))
            }
            // BYOK is billed separately and is zero for nearly everyone, so it
            // only earns a row once there is something in it.
            if let byok = number(keyInfo, "byok_usage", "byokUsage"), byok > 0 {
                rows.append(UsageMetric(label: "BYOK", used: dollars(byok), limit: 0, unit: "USD"))
            }
        }

        guard let primary = rows.first else {
            // The key route's rejection is the most specific thing known when
            // the credits route said nothing usable either.
            throw ProviderError.parse(
                keyFailure.map { "OpenRouter: \($0)" }
                    ?? "No credit balance or key usage in OpenRouter response"
            )
        }

        return UsageData(
            providerID: "openrouter",
            planName: planName(freeTier: keyInfo.flatMap { boolean($0, "is_free_tier", "isFreeTier", "free_tier") },
                               purchased: purchased),
            primary: primary,
            secondary: Array(rows.dropFirst()),
            // The key's own label is all the API names, and with two keys pasted
            // it is the only thing telling the rows apart.
            accountLabel: keyInfo.flatMap(accountLabel),
            rawJSON: rawJSON(credits: credits, key: key)
        )
    }

    // MARK: - Internals

    /// The credit cap's reset cadence. Documented as midnight UTC, weeks Monday
    /// to Sunday.
    private enum ResetWindow: String {
        case daily, weekly, monthly

        var label: String { rawValue.capitalized }
    }

    /// Both routes wrap their payload in `data`. An unwrapped body is accepted
    /// too, since dropping the envelope is the cheapest way an API like this
    /// changes shape.
    private static func unwrap(_ raw: [String: Any]) -> [String: Any] {
        for wrapper in ["data", "result"] {
            if let nested = raw[wrapper] as? [String: Any] { return nested }
        }
        return raw
    }

    /// A rejected key answers `{"error":{"message":"User not found.","code":401}}`.
    /// Read from the body rather than the status code, because a proxy in front
    /// of the API can pass the envelope through with a 200 — and can pass it
    /// through inside the `data` envelope too, so both levels are checked.
    private static func errorMessage(in raw: [String: Any]) -> String? {
        for level in [raw, unwrap(raw)] {
            if let error = level["error"] as? [String: Any] {
                return (error["message"] as? String) ?? "request rejected with no message"
            }
            if let error = level["error"] as? String, !error.isEmpty { return error }
        }
        return nil
    }

    /// An unnamed key is labelled with the key itself. That is credential
    /// material on screen and it names no account, so it is not used.
    private static func accountLabel(_ keyInfo: [String: Any]) -> String? {
        guard let label = string(keyInfo, "label", "name", "key_label") else { return nil }
        return label.lowercased().hasPrefix("sk-or") ? nil : label
    }

    /// Kept for the debug pane. `data(withJSONObject:)` raises an Objective-C
    /// exception rather than throwing for a value that is not JSON, and `parse`
    /// is public, so the payload is checked before it is encoded.
    private static func rawJSON(credits: [String: Any], key: [String: Any]?) -> String? {
        let payload: [String: Any] = ["credits": credits, "key": key ?? [:]]
        guard JSONSerialization.isValidJSONObject(payload) else { return nil }
        return try? JSONSerialization.data(withJSONObject: payload).base64EncodedString()
    }

    private static func resetWindow(_ dict: [String: Any]) -> ResetWindow? {
        guard let raw = string(dict, "limit_reset", "limitReset", "reset") else { return nil }
        return ResetWindow(rawValue: raw.lowercased())
    }

    /// The cap rolls over at 00:00 UTC, so the reset instant is computed in UTC
    /// rather than the user's calendar — a machine in UTC+13 would otherwise
    /// show the reset most of a day early.
    private static func nextReset(_ window: ResetWindow?, now: Date) -> Date? {
        guard let window, let utc = TimeZone(identifier: "UTC") else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        let today = calendar.startOfDay(for: now)

        switch window {
        case .daily:
            return calendar.date(byAdding: .day, value: 1, to: today)
        case .weekly:
            // .weekday is 1 for Sunday; the next Monday is a week away when
            // today is already Monday.
            let weekday = calendar.component(.weekday, from: today)
            let offset = (9 - weekday) % 7
            return calendar.date(byAdding: .day, value: offset == 0 ? 7 : offset, to: today)
        case .monthly:
            guard let first = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) else {
                return nil
            }
            return calendar.date(byAdding: .month, value: 1, to: first)
        }
    }

    /// OpenRouter sells no tiers, so this is a state rather than a plan:
    /// `is_free_tier` is true until credits are bought. Without the key route,
    /// having ever been granted credits is the only signal left.
    private static func planName(freeTier: Bool?, purchased: Double?) -> String {
        if let freeTier { return freeTier ? "Free" : "Pay-as-you-go" }
        return (purchased ?? 0) > 0 ? "Pay-as-you-go" : "Free"
    }

    /// Subtracting two doubles yields 74.75000000000001, which the formatter
    /// then renders as a number the site never showed.
    private static func dollars(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }

    private static func number(_ dict: [String: Any], _ keys: String...) -> Double? {
        number(dict, keys)
    }

    private static func number(_ dict: [String: Any], _ keys: [String]) -> Double? {
        for key in keys {
            // `null` arrives as NSNull for every unlimited field, which coerces
            // to nothing and correctly falls through.
            if let value = amount(dict[key]) { return value }
        }
        return nil
    }

    /// A dollar figure, or nothing at all. `ProviderNumber.coerce` alone lets
    /// through two values that would put a number nobody sent on screen:
    /// JSON `true` bridges to NSNumber and reads as 1, and `Double("nan")` and
    /// `Double("inf")` both succeed — a NaN survives `percent` and reaches the
    /// meter's layout.
    private static func amount(_ value: Any?) -> Double? {
        if let boxed = value as? NSNumber, CFGetTypeID(boxed) == CFBooleanGetTypeID() { return nil }
        // Anything Double(_: String) already understood is taken at its word or
        // discarded; salvaging it would read "1e400" as 1400.
        if let coerced = ProviderNumber.coerce(value) { return coerced.isFinite ? coerced : nil }
        // A symbol-prefixed or thousands-separated string: "$1,234.56".
        guard let text = value as? String else { return nil }
        let cleaned = text.filter { $0.isNumber || $0 == "." || $0 == "-" }
        guard let salvaged = Double(cleaned), salvaged.isFinite else { return nil }
        return salvaged
    }

    private static func string(_ dict: [String: Any], _ keys: String...) -> String? {
        for key in keys {
            if let value = dict[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func boolean(_ dict: [String: Any], _ keys: String...) -> Bool? {
        for key in keys {
            if let value = dict[key] as? Bool { return value }
            if let value = dict[key] as? NSNumber { return value.boolValue }
            if let value = dict[key] as? String {
                switch value.lowercased() {
                case "true", "1", "yes": return true
                case "false", "0", "no": return false
                default: continue
                }
            }
        }
        return nil
    }
}
