import Foundation
import SwiftUI

/// Tracks Codex usage: the rolling windows OpenAI enforces on Codex itself.
///
/// This is not `ChatGPTProvider` under a second name. That card reports what
/// the account's ChatGPT subscription *is*, because ChatGPT publishes no
/// message allowance anywhere you can ask for one. Codex does publish one —
/// two windows, each with a percentage, a length and a reset — at
/// `/backend-api/wham/usage`, and they are the numbers a Codex user actually
/// watches.
///
/// Auth is a ladder, tried in order, each rung independent of the last:
///
///   1. whatever the user gave this row themselves, pasted or captured.
///   2. the ChatGPT browser session aibars already holds, traded for a bearer
///      token through `ChatGPTSession`. Whether `wham/usage` accepts a web
///      token is unverified. It comes before the CLI only because it costs the
///      user nothing — they are already signed in — and a 401 falls straight
///      through to the rung below.
///   3. the `codex` CLI's own login, through `CodexAuth`: the auth files first
///      and the keychain item only if none of them parsed. Documented, and
///      certain.
public final class CodexProvider: ObservableObject, UsageProvider {
    public let id: String
    /// The account this instance follows, when a service is signed into more
    /// than once. Nil is the only-account case.
    public let accountID: String?
    public var serviceID: String { "codex" }
    public let displayName = "Codex"
    public let iconName = "terminal"
    public let accentColor: Color = Color(red: 0.42, green: 0.44, blue: 0.47)

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var lastError: ProviderError?

    private let session = SessionStore.shared
    private let userDefaults = UserDefaults.standard
    private let enabledKey: String

    public init(accountID: String? = nil) {
        self.accountID = accountID
        self.id = accountID.map { "codex#\($0)" } ?? "codex"
        self.enabledKey = "aibars.\(self.id).enabled"
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = SessionStore.shared.hasCredential(for: self.id)
            || Self.hasAmbientCredential(id: self.id, accountID: accountID)
    }

    public var dashboardURL: URL? { URL(string: "https://chatgpt.com/codex/settings/usage") }

    public var webLogin: WebLoginConfig? {
        guard let start = URL(string: "https://chatgpt.com/auth/login") else { return nil }
        return WebLoginConfig(
            startURL: start,
            capture: .cookie(name: ChatGPTSession.cookieName, domainSuffix: "chatgpt.com"),
            hint: "Log in as usual — aibars picks up the session automatically. "
                + "Signing in with `codex` in a terminal works just as well.",
            dataDomains: ["chatgpt.com", "openai.com", "auth.openai.com"]
        )
    }

    /// Walks the ladder until a rung answers.
    ///
    /// Any failure falls through to the next rung, not only an auth one: the
    /// rungs are separate credentials for the same account, and what one of
    /// them says about the state of the world tells you nothing about the next.
    /// The last failure is what gets reported, so a machine with no credential
    /// at all still shows the message its final rung produced rather than a
    /// generic one.
    public func fetchUsage() async throws -> UsageData {
        var failure = ProviderError.notAuthenticated

        for rung in ladder() {
            do {
                let usage = try await attempt(rung)
                await MainActor.run {
                    self.isAuthenticated = true
                    self.lastError = nil
                }
                return usage
            } catch let error as ProviderError {
                failure = error
            } catch {
                failure = .network(error.localizedDescription)
            }
        }

        let outcome = failure
        await MainActor.run {
            if outcome.isAuth { self.isAuthenticated = false }
            self.lastError = outcome
        }
        throw outcome
    }

    public func authenticate() async throws {
        if let cookie = CookieExtractors.firstAvailableCookie(named: ChatGPTSession.cookieName, for: "chatgpt.com"),
           !cookie.value.isEmpty {
            try session.setToken(cookie.value, for: id, source: .browserCookie, accountHint: cookie.source.displayName)
            await MainActor.run {
                self.isAuthenticated = true
                self.lastError = nil
            }
            return
        }

        // No browser session is not the end of it: a machine can be signed in
        // to the CLI and nothing else, and that login needs no credential of
        // ours at all. `CodexAuth.load` may reach the keychain, which is why it
        // is called here and not on the launch path — the user has just asked
        // to connect, which is the one moment an access dialog is something
        // they are expecting.
        guard accountID == nil, CodexAuth.load() != nil else { return }
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
        // Whatever is stored goes into an Authorization header verbatim, and a
        // token copied out of auth.json arrives with whitespace around it.
        try session.setToken(token.trimmingCharacters(in: .whitespacesAndNewlines), for: id, source: source)
        Task { @MainActor in self.isAuthenticated = true }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: enabledKey)
    }

    // MARK: - The ladder

    /// A token that can be spent at `wham/usage`, and who it belongs to.
    private struct Bearer {
        let token: String
        /// Handed back as `ChatGPT-Account-Id`. Absent is normal: an account
        /// with a single workspace is served without it.
        let accountID: String?
        /// The signed-in address, when the rung that produced this knew one.
        let accountLabel: String?
    }

    /// One rung, as its *source* rather than as a credential. Resolving is what
    /// costs something — a network exchange for the browser session, a possible
    /// access dialog for the CLI's keychain fallback — and a rung that is never
    /// reached must never pay it.
    private enum Rung {
        case stored(Bearer)
        case chatGPTCookie(String)
        case codexCLI
    }

    private func ladder() -> [Rung] {
        var rungs: [Rung] = []

        // What the user gave this row themselves outranks anything found lying
        // around the machine.
        if let stored = Self.trimmed(session.token(for: id)) {
            let source = session.credential(for: id)?.source ?? .manualPaste
            rungs.append(source == .browserCookie
                ? .chatGPTCookie(stored)
                : .stored(Bearer(token: stored, accountID: nil, accountLabel: nil)))
        }

        // Everything below is adopted rather than given, so a deliberate sign
        // out has to outrank it — otherwise signing out would last exactly one
        // refresh.
        guard !AppState.signedOutProviders.contains(id) else { return rungs }

        if let cookie = Self.trimmed(session.token(for: chatGPTID)) {
            rungs.append(.chatGPTCookie(cookie))
        }

        // There is one `codex` login on a machine, so only the first account
        // takes it. A second account inheriting the same auth.json would report
        // the first account's numbers twice.
        if accountID == nil { rungs.append(.codexCLI) }
        return rungs
    }

    private func attempt(_ rung: Rung) async throws -> UsageData {
        switch rung {
        case .stored(let bearer):
            return try await request(bearer: bearer)
        case .chatGPTCookie(let cookie):
            let identity = try await ChatGPTSession.identity(sessionToken: cookie)
            return try await request(bearer: Bearer(
                token: identity.accessToken,
                accountID: identity.accountID,
                accountLabel: identity.email
            ))
        case .codexCLI:
            return try await cliUsage()
        }
    }

    /// The ChatGPT row this Codex row shares a login with. Same account slot:
    /// the second Codex account pairs with the second ChatGPT account, not the
    /// first.
    private var chatGPTID: String { Self.chatGPTID(for: accountID) }

    private static func chatGPTID(for accountID: String?) -> String {
        accountID.map { "chatgpt#\($0)" } ?? "chatgpt"
    }

    /// Whether there is a credential to try without asking the user for one.
    ///
    /// Only the existence of an auth file is checked, never `CodexAuth.load`:
    /// that falls through to the keychain, whose first read can raise a dialog,
    /// and this question is asked at launch before anybody has clicked
    /// anything.
    private static func hasAmbientCredential(id: String, accountID: String?) -> Bool {
        guard !AppState.signedOutProviders.contains(id) else { return false }
        if SessionStore.shared.hasCredential(for: chatGPTID(for: accountID)) { return true }
        guard accountID == nil else { return false }
        return CodexAuth
            .authFileURLs(
                environment: ProcessInfo.processInfo.environment,
                home: FileManager.default.homeDirectoryForCurrentUser
            )
            .contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        return value
    }

    // MARK: - The CLI's login

    /// Fetches with the credential the `codex` CLI left behind, rotating it
    /// when it needs rotating.
    ///
    /// Two moments, and only two. Ahead of expiry, when the access token's own
    /// `exp` says it is nearly out — the same five-minute slack the CLI uses,
    /// so the two tools rotate at the same instant rather than racing. And on a
    /// 401, which for a token whose `exp` could not be read is the only
    /// evidence that exists.
    private func cliUsage(now: Date = Date()) async throws -> UsageData {
        guard let loaded = CodexAuth.load() else { throw ProviderError.notAuthenticated }

        if CodexAuth.needsRefresh(loaded.tokens, now: now) {
            return try await request(bearer: bearer(for: try await refreshed(loaded)))
        }

        do {
            return try await request(bearer: bearer(for: loaded))
        } catch let error as ProviderError where error.isAuth {
            guard loaded.tokens.refreshToken != nil else { throw error }
            return try await request(bearer: bearer(for: try await refreshed(loaded)))
        }
    }

    private func bearer(for loaded: CodexAuth.Loaded) -> Bearer {
        Bearer(token: loaded.tokens.accessToken, accountID: loaded.tokens.accountID, accountLabel: nil)
    }

    /// Spends the refresh token and puts the result back where it came from, so
    /// the CLI's next run starts from the live credential rather than one this
    /// app rotated away from under it.
    ///
    /// A keychain login has no file and `CodexAuth` refuses to write one; the
    /// rotation still serves this fetch, it is simply not persisted. A write
    /// that fails — a read-only home, a file the user owns differently — is not
    /// allowed to fail the fetch either: the token in hand is good regardless.
    private func refreshed(_ loaded: CodexAuth.Loaded) async throws -> CodexAuth.Loaded {
        guard let refreshToken = loaded.tokens.refreshToken else { throw ProviderError.sessionExpired }

        let (data, _) = try await ProviderHTTP(headers: ["Content-Type": CodexAuth.refreshContentType])
            .post(CodexAuth.refreshEndpoint, body: CodexAuth.refreshBody(refreshToken: refreshToken))

        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderError.parse("The token endpoint returned \(data.count) bytes that are not a JSON object")
        }
        // A 2xx carrying no access token is a dead session rather than a
        // transport failure: the remedy is running `codex` again, not retrying.
        guard let rotated = CodexAuth.rotated(loaded.tokens, from: raw) else {
            throw ProviderError.sessionExpired
        }

        if let file = loaded.file { try? CodexAuth.write(rotated, toAuthFile: file) }
        return CodexAuth.Loaded(tokens: rotated, file: loaded.file)
    }

    // MARK: - The request

    /// `URL(string:)` on a literal cannot fail. The coalesce exists only because
    /// the initialiser is optional; the fallback is deliberately inert, so a
    /// mistake here fails at the first request rather than quietly pointing
    /// somewhere else.
    private static let usageURL: URL =
        URL(string: "https://chatgpt.com/backend-api/wham/usage") ?? URL(fileURLWithPath: "/dev/null")

    /// `wham/` also exposes a route that *spends* one of the account's
    /// rate-limit reset credits to clear its windows early. It is deliberately
    /// absent: aibars reads an account, it does not spend from it, and a menu
    /// bar item should never be one mis-click away from an irreversible
    /// purchase.
    private func request(bearer: Bearer) async throws -> UsageData {
        var headers = [
            "Authorization": "Bearer \(bearer.token)",
            "Accept": "application/json"
        ]
        if let accountID = bearer.accountID, !accountID.isEmpty {
            headers["ChatGPT-Account-Id"] = accountID
        }

        let (data, response) = try await ProviderHTTP(headers: headers).get(Self.usageURL)
        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderError.parse("wham/usage returned \(data.count) bytes that are not a JSON object")
        }
        return try CodexUsageParser.parse(
            raw,
            headers: Self.headerFields(response),
            account: bearer.accountLabel
        )
    }

    /// Header names are case-insensitive and `HTTPURLResponse` hands back
    /// whatever casing the server sent, so the parser is given a dictionary of
    /// strings rather than a response to interrogate.
    private static func headerFields(_ response: HTTPURLResponse) -> [String: String] {
        var fields: [String: String] = [:]
        for (name, value) in response.allHeaderFields {
            guard let name = name as? String, let value = value as? String else { continue }
            fields[name] = value
        }
        return fields
    }

}

public enum CodexUsageParser {
    /// Reads `/backend-api/wham/usage`:
    ///
    ///     { plan_type: "pro",
    ///       rate_limit: {
    ///         primary_window:   { used_percent: 41.2, limit_window_seconds: 18000,
    ///                             reset_at: 1765400000, reset_after_seconds: 7200 },
    ///         secondary_window: { used_percent: 8, limit_window_seconds: 604800, … } },
    ///       additional_rate_limits: [
    ///         { limit_name: "GPT-5.3-Codex-Spark", metered_feature: "spark",
    ///           rate_limit: { primary_window: …, secondary_window: … } } ],
    ///       credits: { balance: 821.4, has_credits: true } }
    ///
    /// `headers` is the response's own. Three of them —
    /// `x-codex-primary-used-percent`, `x-codex-secondary-used-percent` and
    /// `x-codex-credits-balance` — duplicate a body field, and are the only
    /// source left when the body omits one.
    public static func parse(
        _ raw: [String: Any],
        headers: [String: String],
        account: String? = nil,
        now: Date = Date()
    ) throws -> UsageData {
        let fields = normalised(headers)

        var rows = windows(
            in: raw["rate_limit"] as? [String: Any],
            scope: nil,
            headerPercents: (
                primary: percent(fields["x-codex-primary-used-percent"]),
                secondary: percent(fields["x-codex-secondary-used-percent"])
            ),
            now: now
        )
        rows.append(contentsOf: sparkWindows(in: raw, now: now))

        // Busiest first, so the headline figure is the window actually at risk.
        // A 5-hour window at 4% says nothing while the weekly cap sits at 88%.
        rows.sort { $0.percent > $1.percent }

        if let count = creditCount(in: raw, headers: fields) {
            // Prepaid credit has no ceiling, so the limit stays 0: that marks
            // the metric status-only and keeps a healthy balance from rendering
            // as fully consumed. Zero is a measured zero, not missing data.
            rows.append(UsageMetric(
                label: "Credits",
                used: Double(count * creditCents) / 100,
                limit: 0,
                unit: "USD"
            ))
        }

        guard let primary = rows.first else {
            throw ProviderError.parse("No usage windows or credit balance in the Codex response")
        }

        return UsageData(
            providerID: "codex",
            planName: planName(raw["plan_type"]),
            primary: primary,
            secondary: Array(rows.dropFirst()),
            accountLabel: account,
            rawJSON: rawJSON(raw)
        )
    }

    /// The flex-credit balance, as money.
    ///
    /// `.measured` because both halves come from Codex: the balance from the
    /// account, the 4¢ from the published price. `.lifetime` because a balance
    /// is not spent against a window and does not reset — it sits there until
    /// it is used or topped up.
    ///
    /// Separate from `parse` because a balance is not a usage window and has no
    /// business being drawn as one; the row `parse` emits is the same figure in
    /// the shape today's list can show.
    public static func credits(in raw: [String: Any], headers: [String: String]) -> SpendReport? {
        guard let count = creditCount(in: raw, headers: normalised(headers)) else { return nil }
        // Whole credits at 4¢ is an exact number of cents, so the money never
        // goes near a Double.
        return SpendReport(
            amountMinor: count * creditCents,
            currency: "USD",
            period: .lifetime,
            confidence: .measured
        )
    }

    /// Whole credits, floored, from the body or from the header that duplicates
    /// it.
    ///
    /// The count is floored *before* anything prices it, which is what Codex
    /// itself does: pricing 821.4 credits at 4¢ gives $32.86 where Codex shows
    /// $32.84, and a dollar figure that disagrees with the service by two cents
    /// is worse than none. A negative balance clamps to zero, and a zero
    /// balance still earns its row — it is a real answer.
    private static func creditCount(in raw: [String: Any], headers: [String: String]) -> Int? {
        var balance: Double?

        if let credits = raw["credits"] as? [String: Any] {
            balance = number(credits["balance"])
            // An account with no credit facility says so rather than reporting
            // a zero, and that is still a measured zero.
            if balance == nil, credits["has_credits"] as? Bool == false { balance = 0 }
        }
        if balance == nil { balance = number(headers["x-codex-credits-balance"]) }

        guard let balance else { return nil }
        // Clamped before the conversion: `Int(_:)` traps above `Int.max`, and a
        // payload is not a promise.
        return Int(min(max(balance, 0), 1e9).rounded(.down))
    }

    /// What OpenAI charges for one flex credit, in cents.
    private static let creditCents = 4

    // MARK: - Windows

    private static let sessionSeconds = 18_000
    private static let weekSeconds = 604_800
    private static let sessionLabel = "5h session"
    private static let weeklyLabel = "Weekly"

    /// The two windows a `rate_limit` object carries, as meters.
    ///
    /// A slot is not a kind. OpenAI drops one of the two limits from time to
    /// time and promotes the remaining weekly window into `primary_window`; a
    /// reader that trusts the slot then labels a seven-day cap "5h session" and
    /// tells the user their afternoon frees up in six days. So each window is
    /// classified by its own `limit_window_seconds`, and the slot decides only
    /// for a payload that carries no duration at all.
    private static func windows(
        in rateLimit: [String: Any]?,
        scope: String?,
        headerPercents: (primary: Double?, secondary: Double?),
        now: Date
    ) -> [UsageMetric] {
        let slots: [(key: String, isPrimary: Bool, headerPercent: Double?)] = [
            ("primary_window", true, headerPercents.primary),
            ("secondary_window", false, headerPercents.secondary)
        ]

        return slots.compactMap { slot -> UsageMetric? in
            let window = rateLimit?[slot.key] as? [String: Any]
            // The header and the body carry the same percentage; the body is
            // the only source of the duration and the reset. Either can be
            // missing on its own, and a window with no percentage at all is a
            // window this account does not have.
            guard let used = percent(window?["used_percent"]) ?? slot.headerPercent else { return nil }

            let duration = duration(window?["limit_window_seconds"])
            let name = label(duration: duration, isPrimary: slot.isPrimary)
            return UsageMetric(
                label: scope.map { "\($0) · \(name)" } ?? name,
                used: used,
                limit: 100,
                unit: "%",
                resetDate: resetDate(window, now: now),
                windowLabel: name,
                // The window's own figure, never a house guess: the pace notch
                // is drawn against this, and a notch on an inferred duration is
                // an inferred instrument.
                windowDuration: duration
            )
        }
    }

    /// Model-specific limits ride in `additional_rate_limits`, each entry a
    /// named limit whose `rate_limit` reuses the shape above. Only Spark is
    /// surfaced, and only the first entry that names it: the array is a list of
    /// named caps, and two entries matching would draw two rows called the same
    /// thing. An account without the limit simply has no entry, which is the
    /// common case and never an error.
    private static func sparkWindows(in raw: [String: Any], now: Date) -> [UsageMetric] {
        guard let entries = raw["additional_rate_limits"] as? [Any],
              let spark = entries.compactMap({ $0 as? [String: Any] }).first(where: isSpark)
        else { return [] }

        return windows(
            in: spark["rate_limit"] as? [String: Any],
            scope: "Spark",
            headerPercents: (nil, nil),
            now: now
        )
    }

    /// Matched on either name, case-insensitively, so a change of wording on
    /// one of them still resolves the limit.
    private static func isSpark(_ entry: [String: Any]) -> Bool {
        ["limit_name", "metered_feature"]
            .compactMap { entry[$0] as? String }
            .contains { $0.lowercased().contains("spark") }
    }

    private static func label(duration: TimeInterval?, isPrimary: Bool) -> String {
        let bySlot = isPrimary ? sessionLabel : weeklyLabel
        guard let duration else { return bySlot }

        switch Int(duration.rounded()) {
        case sessionSeconds: return sessionLabel
        case weekSeconds:    return weeklyLabel
        default:
            // A window OpenAI has not published before is named after its own
            // length. Forcing it into one of the two familiar names would be
            // the slot mistake again, wearing a duration.
            return durationLabel(duration).map { "\($0) window" } ?? bySlot
        }
    }

    private static func durationLabel(_ seconds: TimeInterval) -> String? {
        guard seconds >= 60 else { return nil }
        let minutes = Int((seconds / 60).rounded())
        if minutes % 1440 == 0 { return "\(minutes / 1440)d" }
        if minutes % 60 == 0 { return "\(minutes / 60)h" }
        return "\(minutes)m"
    }

    /// `reset_at` is an absolute epoch second; `reset_after_seconds` is the
    /// countdown, and is only consulted when the absolute figure is absent —
    /// it is the one that goes stale the moment it is stored.
    private static func resetDate(_ window: [String: Any]?, now: Date) -> Date? {
        guard let window else { return nil }
        if let at = number(window["reset_at"]), at > 0 {
            return Date(timeIntervalSince1970: at)
        }
        if let after = number(window["reset_after_seconds"]), after >= 0 {
            return now.addingTimeInterval(after)
        }
        return nil
    }

    /// A window length, or nothing. Bounded at a year on the way out: it is a
    /// denominator for anything drawing the elapsed share of the window,
    /// `Int(_:)` traps above `Int.max`, and no usage window is that long.
    private static func duration(_ value: Any?) -> TimeInterval? {
        guard let seconds = number(value), seconds > 0, seconds <= 366 * 24 * 60 * 60 else { return nil }
        return seconds
    }

    /// A percentage, already on Codex's own 0…100 scale. Kept verbatim: if the
    /// API reports 1% on an untouched window, the row says 1%.
    private static func percent(_ value: Any?) -> Double? {
        number(value).map { max($0, 0) }
    }

    /// A finite quantity, or nothing.
    ///
    /// Not `ProviderNumber.coerce` on its own: JSON `true` bridges to an
    /// `NSNumber` that reads as 1, which would put a figure nobody sent on a
    /// meter, and `Double("nan")` succeeds — a NaN survives `UsageMetric.percent`
    /// and reaches the meter's layout.
    private static func number(_ value: Any?) -> Double? {
        if let boxed = value as? NSNumber, CFGetTypeID(boxed) == CFBooleanGetTypeID() { return nil }
        guard let coerced = ProviderNumber.coerce(value), coerced.isFinite else { return nil }
        return coerced
    }

    // MARK: - Plumbing

    /// `plan_type` is an identifier: "prolite", "pro", "plus", "business". The
    /// two Pro tiers are the ones nobody could guess — they name the rate
    /// multiplier Codex sells, not a rank — so those two are mapped, and every
    /// other tier is tidied the way every other plan in aibars is.
    private static func planName(_ value: Any?) -> String? {
        guard let raw = (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        switch raw.lowercased() {
        case "prolite": return "Pro 5×"
        case "pro":     return "Pro 20×"
        default:        return PlanName.pretty(raw, service: "Codex")
        }
    }

    /// Header names are case-insensitive, and a caller holding an
    /// `HTTPURLResponse`'s fields has whatever casing the server chose. Lookups
    /// go through one lowercased copy rather than guessing at `X-Codex-…`.
    private static func normalised(_ headers: [String: String]) -> [String: String] {
        Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
    }

    /// `data(withJSONObject:)` raises an Objective-C exception rather than
    /// throwing for a value that is not JSON, and `parse` is public, so the
    /// payload is checked before it is encoded.
    private static func rawJSON(_ raw: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(raw) else { return nil }
        return try? JSONSerialization.data(withJSONObject: raw).base64EncodedString()
    }
}
