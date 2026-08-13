import Foundation
import SwiftUI

/// Tracks Claude (Anthropic) usage for Pro and Max plans.
///
/// Auth: `sessionKey` cookie from claude.ai. The provider tries the
/// installed browsers first; if none returns a usable token, the user
/// is asked to paste it via the Settings sheet.
///
/// Two calls per refresh, in this order: `/api/organizations` names the
/// organisation, the plan tier and the account, and `/api/organizations/<id>/usage`
/// carries every window. Which organisation is a question with more than one
/// answer for anyone in several of them, so the browser's own `lastActiveOrg`
/// cookie breaks the tie — see `activeOrganizationHint(matching:)`.
public final class ClaudeProvider: ObservableObject, UsageProvider {
    public let id: String
    /// The account this instance follows, when a service is signed into more
    /// than once. Nil is the only-account case.
    public let accountID: String?
    public var serviceID: String { "claude" }
    public let displayName = "Claude"
    public let iconName = "sparkles"

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var lastError: ProviderError?

    private let cookieName = "sessionKey"
    private let session = SessionStore.shared
    /// `AppDefaults.current`, which is `.standard` in the app and a domain of the
    /// test process's own under XCTest. Every provider here holds this line and
    /// the reason is the same for all fifteen: the key is `aibars.<id>.enabled`,
    /// a switch the user threw in Settings, and a provider constructed by a test
    /// both reads and writes it. `MultiAccountTests` calls `setEnabled(false)` on
    /// a real service id — which used to turn that service off in the install
    /// running the suite, and stay off.
    private let userDefaults = AppDefaults.current
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

        let http = ProviderHTTP(headers: [
            "Cookie": "\(cookieName)=\(token)",
            "Origin": "https://claude.ai",
            // The page both of these calls belong to. A Referer naming no real
            // page is one of the cheapest signals an edge has for scripted
            // traffic, and the usage settings page is where someone reading
            // these numbers by hand would be standing.
            "Referer": "https://claude.ai/settings/usage"
        ])

        let org = try await organization(token: token, using: http)
        // The id reaches a URL path and can come from a cookie the browser
        // wrote, so it is escaped rather than trusted.
        guard let escaped = org.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let usageURL = URL(string: "https://claude.ai/api/organizations/\(escaped)/usage")
        else {
            throw ProviderError.parse("Organization id is not usable in a URL")
        }

        let usageData = try await Self.fetch(usageURL, using: http)
        let raw = (try? JSONSerialization.jsonObject(with: usageData)) as? [String: Any] ?? [:]
        return try ClaudeUsageParser.parse(raw, planName: org.tier, orgName: org.name)
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

    // MARK: - Which organization

    private static let organizationsURL = URL(string: "https://claude.ai/api/organizations")!

    /// The organisation to ask for usage, with its name and plan tier when they
    /// are available.
    ///
    /// `/api/organizations` goes first because it is the only route that names
    /// the plan and the account, and it is one request either way. The browser
    /// cookie then decides *which* entry of that list is the answer, which is
    /// the part that used to be wrong: `orgs.first` is array order, and array
    /// order is not the organisation the user is working in.
    private func organization(token: String, using http: ProviderHTTP) async throws -> ClaudeOrganization {
        do {
            let data = try await Self.fetch(Self.organizationsURL, using: http)
            let organizations = ClaudeOrganization.list(in: try? JSONSerialization.jsonObject(with: data))
            // Only read the cookie jar when there is a tie to break: a cookie
            // read copies a browser's whole cookie database, and this runs on
            // the refresh cycle.
            let hint = organizations.count > 1 ? activeOrganizationHint(matching: token) : nil
            if let chosen = ClaudeOrganization.choose(from: organizations, hint: hint) {
                return chosen
            }
            throw ProviderError.parse("No organization in the Claude response")
        } catch let error as ProviderError {
            switch error {
            case .sessionExpired, .notAuthenticated, .blocked, .rateLimited:
                // Nothing further down the ladder can succeed where this
                // failed: it is the same session against the same edge, and
                // three more refused requests only make the refusal firmer.
                throw error
            default:
                break
            }
            guard let fallback = await fallbackOrganization(token: token, using: http) else {
                throw error
            }
            return fallback
        }
    }

    /// Everything left after the organizations list: the cookie the browser
    /// wrote, then the three other routes that mention an organisation
    /// somewhere.
    ///
    /// Only the id comes out of these — none of them carries `rate_limit_tier` —
    /// so a row resolved this way keeps every meter and loses its plan pill,
    /// which is the right way round.
    private func fallbackOrganization(token: String, using http: ProviderHTTP) async -> ClaudeOrganization? {
        if let hint = activeOrganizationHint(matching: token) {
            return ClaudeOrganization(id: hint)
        }
        for path in ["/api/bootstrap", "/api/auth/current_account", "/api/account"] {
            guard let url = URL(string: "https://claude.ai" + path),
                  let data = try? await Self.fetch(url, using: http),
                  let id = ClaudeOrganization.identifier(in: try? JSONSerialization.jsonObject(with: data))
            else { continue }
            return ClaudeOrganization(id: id)
        }
        return nil
    }

    /// The organisation the browser is actually working in, out of the cookie
    /// jar and with no request at all.
    ///
    /// claude.ai writes the active organisation into `lastActiveOrg`; sessions
    /// that predate it carry the same id as `routingHint`.
    ///
    /// The cookie has to come from the same browser profile as the session this
    /// account was adopted from. Two Chrome profiles signed into two Claude
    /// accounts each write their own `lastActiveOrg`, and pairing the wrong one
    /// with this token asks for usage on an organisation the session cannot
    /// see — which is a 403, on a session that was working.
    private func activeOrganizationHint(matching token: String) -> String? {
        let jar = CookieExtractors.searchAll([
            CookieExtractors.Query(key: "session", names: [cookieName], domain: "claude.ai"),
            CookieExtractors.Query(key: "org", names: ["lastActiveOrg", "routingHint"], domain: "claude.ai")
        ])
        let candidates = jar["org"] ?? []
        guard !candidates.isEmpty else { return nil }

        if let mine = jar["session"]?.first(where: { $0.value == token }),
           let paired = candidates.first(where: { $0.source == mine.source && $0.profile == mine.profile }) {
            return Self.organizationID(fromCookie: paired.value)
        }
        // `searchAll` dedupes on the value, so two profiles pointing at one
        // organisation leave a single row filed under whichever browser was
        // read first, and the pairing above can miss it. One distinct value is
        // one answer, and there is nothing left to be wrong about.
        let values = Set(candidates.compactMap { Self.organizationID(fromCookie: $0.value) })
        return values.count == 1 ? values.first : nil
    }

    /// A cookie value that is safe to put in a URL path. Browsers hand back
    /// whatever the site wrote, and a value carrying a slash would climb out of
    /// the organisations path into somewhere else entirely.
    private static func organizationID(fromCookie value: String) -> String? {
        let decoded = value.removingPercentEncoding ?? value
        let trimmed = decoded.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'"))
        guard !trimmed.isEmpty, trimmed.count <= 128, !trimmed.contains("/") else { return nil }
        return trimmed
    }

    // MARK: - Requests

    /// A GET that keeps the status code and the body.
    ///
    /// `ProviderHTTP.get` answers every 401 and 403 with `.sessionExpired` and
    /// drops the body, and here the body is the whole difference between two
    /// 403s: one names `account_session_invalid` and is a session that really
    /// has gone, the other is Anthropic's edge refusing this request — a
    /// challenge, a captive portal, a bad afternoon. Treating the second as an
    /// expiry deletes a session that still works. The shared session and its
    /// headers are reused, so this is the same request with the reading of the
    /// response done here.
    private static func fetch(_ url: URL, using http: ProviderHTTP) async throws -> Data {
        var request = URLRequest(url: url)
        for (field, value) in http.defaultHeaders {
            request.setValue(value, forHTTPHeaderField: field)
        }
        do {
            let (data, response) = try await http.session.data(for: request)
            guard let status = (response as? HTTPURLResponse)?.statusCode else {
                throw ProviderError.network("Non-HTTP response")
            }
            if let failure = ClaudeUsageParser.failure(status: status, body: data) {
                throw failure
            }
            return data
        } catch let error as ProviderError {
            throw error
        } catch {
            throw ProviderError.network(error.localizedDescription)
        }
    }
}

/// One organisation, as claude.ai describes it.
///
/// Its name and tier are the only source of a Claude row's account label and
/// plan pill, which is why the list is still fetched even when the browser has
/// already said which organisation is active.
public struct ClaudeOrganization: Equatable {
    public let id: String
    public let name: String
    /// `rate_limit_tier`, e.g. `Default_Claude_Max_20X`. Nil on every route
    /// except the organizations list, which is the only one that reports it.
    public let tier: String?

    public init(id: String, name: String = "", tier: String? = nil) {
        self.id = id
        self.name = name
        self.tier = tier
    }

    /// The array form: `/api/organizations`.
    public static func list(in payload: Any?) -> [ClaudeOrganization] {
        guard let array = payload as? [Any] else { return [] }
        return array.compactMap { entry in
            guard let object = entry as? [String: Any],
                  // `uuid` is what claude.ai answers with, `id` is what the
                  // other routes call the same field. Decoding only the first
                  // meant one renamed key lost the whole list.
                  let id = string(object["uuid"]) ?? string(object["id"])
            else { return nil }
            return ClaudeOrganization(
                id: id,
                name: string(object["name"]) ?? "",
                tier: string(object["rate_limit_tier"])
            )
        }
    }

    /// Which of them to ask about.
    ///
    /// The hint is the browser's active organisation and wins whenever the
    /// account can actually see that organisation. A hint matching nothing in
    /// the list loses to the list: an id this session has no membership in is
    /// not somewhere to go asking for usage, whatever wrote it.
    public static func choose(from organizations: [ClaudeOrganization], hint: String?) -> ClaudeOrganization? {
        if let hint, let match = organizations.first(where: { $0.id == hint }) {
            return match
        }
        return organizations.first
    }

    /// The organisation id buried in the routes that are not a list of them —
    /// `/api/bootstrap`, `/api/auth/current_account`, `/api/account`. Each
    /// spells it differently and any of them may be the only one answering.
    public static func identifier(in payload: Any?) -> String? {
        if payload is [Any] { return list(in: payload).first?.id }
        guard let object = payload as? [String: Any] else { return nil }

        if let id = string(object["organization_id"]) ?? string(object["org_id"]) { return id }
        if let id = list(in: object["organizations"]).first?.id { return id }

        guard let account = object["account"] as? [String: Any] else { return nil }
        // Bootstrap names the active organisation outright, which is the same
        // fact the cookie carries and worth more than the first membership.
        if let id = string(account["lastActiveOrgId"]) { return id }
        for entry in (account["memberships"] as? [Any]) ?? [] {
            guard let membership = entry as? [String: Any],
                  let organization = membership["organization"] as? [String: Any],
                  let id = string(organization["uuid"]) ?? string(organization["id"])
            else { continue }
            return id
        }
        return nil
    }

    /// A non-empty string, trimmed. A key present and blank is a key that is
    /// not there.
    private static func string(_ value: Any?) -> String? {
        guard let text = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty
        else { return nil }
        return text
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

        // Older responses carry one object per window at the top level instead.
        if windows.isEmpty {
            windows = legacyWindows(in: raw)
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
            rawJSON: rawJSON(raw),
            spend: spend(in: raw)
        )
    }

    /// What a response's status and body mean, before anything reads the JSON.
    ///
    /// The 403s are the point. Anthropic answers a dead session with
    /// `account_session_invalid` in the body, and answers a request its edge
    /// does not like with a 403 that says no such thing — and aibars throws a
    /// browser cookie away on `.sessionExpired`, so collapsing the two loses a
    /// working session to a Cloudflare challenge.
    public static func failure(status: Int, body: Data) -> ProviderError? {
        switch status {
        case 200..<300:
            return nil
        case 401:
            return .sessionExpired
        case 403:
            let text = String(data: body.prefix(2048), encoding: .utf8) ?? ""
            // A 403 that is not a dead session is the edge in front of the API
            // refusing the request, and the reason it gives is worth keeping —
            // it is the difference between "log in again" and "you were
            // challenged", which need different things from the user.
            return text.contains("account_session_invalid")
                ? .sessionExpired
                : .blocked(text.isEmpty ? "the endpoint refused the request" : String(text.prefix(200)))
        case 429:
            return .rateLimited
        default:
            let preview = String(data: body.prefix(200), encoding: .utf8) ?? ""
            return .network("HTTP \(status): \(preview)")
        }
    }

    // MARK: - Windows

    private static func metrics(from limits: [[String: Any]]) -> [UsageMetric] {
        limits.compactMap { entry in
            // No percentage is no reading. A model-scoped weekly cap that the
            // seat does not have arrives exactly this way, and a zero would
            // draw a full meter for a limit that does not apply.
            guard let percent = number(entry["percent"]) else { return nil }
            let kind = (entry["kind"] as? String) ?? (entry["group"] as? String) ?? "limit"
            let model = (entry["scope"] as? [String: Any]).flatMap(scopedModelName)
            return metric(
                kind: kind,
                model: model,
                label: label(kind: kind, model: model),
                percent: percent,
                resetsAt: entry["resets_at"]
            )
        }
    }

    /// The shape older accounts still answer with: one object per window at the
    /// top level. `five_hour`, `seven_day`, and a `seven_day_<model>` sibling
    /// for each model-scoped weekly cap.
    ///
    /// Reading only the first two dropped the model-scoped cap on exactly the
    /// accounts that have one. Those keys are siblings at the top level rather
    /// than entries in a limits array, so there was nowhere else it could have
    /// turned up.
    private static func legacyWindows(in raw: [String: Any]) -> [UsageMetric] {
        legacyKeys(in: raw).compactMap { key in
            guard let bucket = raw[key] as? [String: Any] else { return nil }
            // Same rule as the array form: an absent utilization is no data.
            // On Pro and standard seats the model-scoped weekly cap runs on
            // usage credits and is genuinely missing, and a 0% meter there is a
            // claim about a limit the account does not have.
            guard let percent = number(bucket["utilization"]) else { return nil }
            let model = legacyModel(in: key)
            return metric(
                kind: key,
                model: model,
                label: (bucket["label"] as? String) ?? label(kind: key, model: model),
                percent: percent,
                resetsAt: bucket["resets_at"]
            )
        }
    }

    /// The top-level window keys, in a fixed order so two refreshes of the same
    /// payload never disagree about which scoped cap comes first.
    private static func legacyKeys(in raw: [String: Any]) -> [String] {
        let scoped = raw.keys.filter { $0.hasPrefix("seven_day_") }.sorted()
        return ["five_hour", "seven_day"] + scoped
    }

    /// `seven_day_sonnet` is the weekly Sonnet cap, and the model is the only
    /// part of the key that is not boilerplate.
    private static func legacyModel(in key: String) -> String? {
        let prefix = "seven_day_"
        guard key.hasPrefix(prefix) else { return nil }
        let model = key.dropFirst(prefix.count).replacingOccurrences(of: "_", with: " ")
        return model.isEmpty ? nil : model.capitalized
    }

    private static func metric(
        kind: String,
        model: String?,
        label: String,
        percent: Double,
        resetsAt: Any?
    ) -> UsageMetric {
        UsageMetric(
            label: label,
            // A percentage past its own ceiling is a figure the row would print
            // verbatim, and these are all reported out of 100.
            used: min(max(percent, 0), 100),
            limit: 100,
            unit: "%",
            resetDate: date(resetsAt),
            windowLabel: label,
            windowDuration: windowDuration(for: kind),
            windowKey: windowKey(kind: kind, model: model)
        )
    }

    /// How long a window is.
    ///
    /// Anthropic does not publish this: the payload carries a kind and the
    /// instant the window resets, and the length is what the pace notch is
    /// drawn against. Both kinds are documented product limits — the session
    /// window is five hours and every weekly cap is seven days — so these are
    /// facts about the plan rather than a shape inferred from the data. A kind
    /// that is neither gets no length and draws no notch, which is the honest
    /// answer for a window nobody has stated the size of.
    private static func windowDuration(for kind: String) -> TimeInterval? {
        switch kind {
        case "session", "five_hour":
            return 5 * 3600
        case "weekly_all", "weekly_scoped", "seven_day":
            return 7 * 24 * 3600
        default:
            // `seven_day_sonnet` and its siblings are the older spelling of a
            // model-scoped weekly cap, and just as much a seven-day window.
            return kind.hasPrefix("seven_day_") ? 7 * 24 * 3600 : nil
        }
    }

    /// The series this window is filed under in history, taken from the
    /// payload's own `kind` rather than from its label.
    ///
    /// Anthropic has renamed these windows on screen more than once, and a
    /// series keyed off the label forks on a rename and orphans everything
    /// recorded before it. The two spellings of each window fold into one key
    /// for the same reason: an account whose response moved from `seven_day` to
    /// `weekly_all` did not start a new limit.
    ///
    /// Slugged through the history layer's own function rather than a private
    /// copy of it, so a key stated here and a key derived from a label there
    /// are in the same alphabet.
    private static func windowKey(kind: String, model: String?) -> String {
        switch kind {
        case "session", "five_hour":
            return "session"
        case "weekly_all", "seven_day":
            return "weekly"
        case "weekly_scoped":
            return "weekly-" + (model.map(HistorySeriesID.windowKey(for:)) ?? "scoped")
        default:
            if kind.hasPrefix("seven_day_") {
                return "weekly-" + HistorySeriesID.windowKey(for: String(kind.dropFirst("seven_day_".count)))
            }
            return HistorySeriesID.windowKey(for: kind)
        }
    }

    /// `kind` is the specific window, `group` the family it belongs to. A
    /// scoped weekly limit applies to particular models, and names them when it
    /// can — "Weekly · Opus" is worth far more than "weekly_scoped".
    private static func label(kind: String, model: String?) -> String {
        switch kind {
        case "session", "five_hour":
            return "5h session"
        case "weekly_all", "seven_day":
            return "Weekly · all models"
        case "weekly_scoped":
            return model.map { "Weekly · \($0)" } ?? "Weekly · per-model"
        default:
            if let model, kind.hasPrefix("seven_day_") { return "Weekly · \(model)" }
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

    // MARK: - Overage spend

    /// What the account has spent past its plan, when overages are switched on.
    ///
    /// Two shapes, and the newer one is explicit about money:
    ///
    ///     spend: { enabled: true,
    ///              used:  { amount_minor: 3284, currency: "USD", exponent: 2 },
    ///              limit: { amount_minor: 10000, currency: "USD", exponent: 2 } }
    ///
    ///     extra_usage: { is_enabled: true, used_credits: 3284,
    ///                    monthly_limit: 10000, decimal_places: 2 }
    ///
    /// `extra_usage: null` is the state worth naming: overages are off, so an
    /// account sitting at 100% of its weekly cap is stopped rather than quietly
    /// billing — which is why a full meter with no spend beside it is not the
    /// same warning as a full meter with one. No report is how that reads.
    private static func spend(in raw: [String: Any]) -> SpendReport? {
        // A `spend` object present is the account's own statement about
        // overages, including when it says there is nothing to report. Falling
        // back to the older field behind it would let two answers disagree.
        if let object = raw["spend"] as? [String: Any] {
            return spend(fromSpend: object)
        }
        return spend(fromExtraUsage: raw["extra_usage"])
    }

    private static func spend(fromSpend object: [String: Any]) -> SpendReport? {
        guard boolean(object["enabled"]) != false,
              let used = object["used"] as? [String: Any],
              let amount = integer(used["amount_minor"]),
              let currency = (used["currency"] as? String)?.trimmingCharacters(in: .whitespaces),
              !currency.isEmpty
        else { return nil }

        return SpendReport(
            amountMinor: amount,
            currency: currency,
            exponent: integer(used["exponent"]) ?? 2,
            ceiling: ceiling(object["limit"]),
            // Extra usage is billed monthly, which is the one thing both shapes
            // agree on: the older field calls its ceiling `monthly_limit`.
            period: .month,
            confidence: .measured,
            resetDate: date(object["resets_at"])
        )
    }

    private static func spend(fromExtraUsage value: Any?) -> SpendReport? {
        guard let object = value as? [String: Any],
              boolean(object["is_enabled"]) != false,
              let amount = integer(object["used_credits"])
        else { return nil }

        return SpendReport(
            amountMinor: amount,
            // Cents unless the payload says otherwise, and dollars because this
            // shape carries no currency at all — Anthropic bills extra usage in
            // USD, and a currency only became something to read in the newer
            // object. Still taken from the payload where it is there.
            currency: (object["currency"] as? String) ?? "USD",
            exponent: integer(object["decimal_places"]) ?? 2,
            ceiling: ceiling(object["monthly_limit"]),
            period: .month,
            confidence: .measured,
            resetDate: date(object["resets_at"])
        )
    }

    /// A ceiling in three states rather than two.
    ///
    /// An absent limit is genuinely uncapped — the account can keep spending —
    /// while a limit that is there and unreadable poisons the whole report
    /// through `SpendReport.init?`, because "no ceiling" is the one wrong answer
    /// a spend row must never give. Zero is the older payload's way of spelling
    /// no cap set, not a cap of nothing.
    private static func ceiling(_ value: Any?) -> SpendReport.Ceiling {
        guard let value, !(value is NSNull) else { return .uncapped }
        if let object = value as? [String: Any] {
            guard let amount = integer(object["amount_minor"]) else { return .unreadable }
            return amount > 0 ? .limit(amount) : .uncapped
        }
        guard let amount = integer(value) else { return .unreadable }
        return amount > 0 ? .limit(amount) : .uncapped
    }

    // MARK: - Plan and account

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

    // MARK: - Reading values

    /// A number, or nothing at all. `ProviderNumber.coerce` alone lets through
    /// two values that would put a figure nobody sent on screen: JSON `true`
    /// bridges to NSNumber and reads as 1, and a NaN survives `percent` all the
    /// way into the meter's layout.
    private static func number(_ value: Any?) -> Double? {
        if let boxed = value as? NSNumber, CFGetTypeID(boxed) == CFBooleanGetTypeID() { return nil }
        guard let coerced = ProviderNumber.coerce(value), coerced.isFinite else { return nil }
        return coerced
    }

    /// A whole number: minor units of money, or a decimal scale. Rejected
    /// outright past a range any of those could occupy, because `Int(_:)` traps
    /// on a value past its own and a payload is not a promise.
    private static func integer(_ value: Any?) -> Int? {
        guard let raw = number(value), abs(raw) < 1e15 else { return nil }
        return Int(raw.rounded())
    }

    /// A JSON boolean, or the 0/1 an API sometimes sends in its place. Nil for
    /// an absent field, which is not the same as false: only an explicit false
    /// is the user having switched overages off.
    private static func boolean(_ value: Any?) -> Bool? {
        if let flag = value as? Bool { return flag }
        guard let coerced = number(value) else { return nil }
        return coerced != 0
    }

    /// `resets_at` is an ISO instant on every payload seen here. A number is
    /// accepted too, in seconds or milliseconds, because the rest of
    /// Anthropic's surface reports instants that way.
    private static func date(_ value: Any?) -> Date? {
        if let text = value as? String, !text.isEmpty { return ProviderDate.parse(text) }
        guard let seconds = number(value), seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds > 1e11 ? seconds / 1000 : seconds)
    }

    /// `data(withJSONObject:)` raises an Objective-C exception rather than
    /// throwing for a value that is not JSON, and `parse` is public, so the
    /// payload is checked before it is encoded.
    private static func rawJSON(_ raw: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(raw) else { return nil }
        return try? JSONSerialization.data(withJSONObject: raw).base64EncodedString()
    }
}
