import Foundation
import SwiftUI

/// Tracks Google Gemini compute-credit usage — the rolling 5-hour window and the
/// weekly ceiling that gemini.google.com/usage renders.
///
/// Auth: the Google SID cookie family on `.google.com`. `__Secure-1PSID` is the
/// cookie aibars keys on, but sending it alone is not enough: without `SIDCC`
/// and both `__Secure-1PAPISID` / `__Secure-3PAPISID`, Google answers with a
/// logged-out HTML shell. The whole family therefore goes out on every request.
///
/// `__Secure-1PSIDTS` rotates every few minutes, so the browser cookie jar is
/// re-read on each fetch rather than snapshotted once. The value in the Keychain
/// is only a marker that the user connected this provider, plus the fallback for
/// a manually pasted session.
public final class GoogleGeminiProvider: ObservableObject, UsageProvider {
    public let id: String
    /// The account this instance follows, when a service is signed into more
    /// than once. Nil is the only-account case.
    public let accountID: String?
    public var serviceID: String { "gemini" }
    public let displayName = "Gemini"
    public let iconName = "sparkle"

    @Published public var isEnabled: Bool = true
    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var lastError: ProviderError?

    private let session = SessionStore.shared
    private let userDefaults = AppDefaults.current
    private let enabledKey: String

    /// The cookie that decides whether a Google session exists at all.
    private static let primaryCookieName = "__Secure-1PSID"

    /// Sent in this order. Everything past the first four is belt-and-braces:
    /// Google's own page sends the lot and the endpoint is picky about which
    /// combination it accepts.
    private static let cookieFamily = [
        "__Secure-1PSID", "__Secure-1PSIDTS", "__Secure-1PSIDCC", "__Secure-1PAPISID",
        "__Secure-3PSID", "__Secure-3PSIDTS", "__Secure-3PSIDCC", "__Secure-3PAPISID",
        "SID", "SIDCC", "HSID", "SSID", "APISID", "SAPISID", "NID"
    ]

    /// The cookie extractors match hosts by substring, so `google.com` also
    /// returns `mail.google.com` rows. Only jars that gemini.google.com would
    /// actually receive are kept.
    private static let cookieHosts: Set<String> = [
        "google.com", ".google.com", "gemini.google.com", ".gemini.google.com"
    ]

    /// The internal RPC the /usage page calls for itself. Obfuscated ids like
    /// this one get rotated; the parser matches on payload shape rather than on
    /// the id, so a rotation costs a wrong-id 400 and nothing worse.
    private static let usageRPCID = "jSf9Qc"

    /// The aibars agent string gets Google's HTML shell instead of the app.
    private static let chromeUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36"

    /// The three tokens the SSR page carries for its own RPCs.
    private struct PageTokens {
        /// `SNlM0e`, the XSRF token. Only rendered for a signed-in session.
        let at: String
        /// `cfb2h`, the frontend build label.
        let bl: String
        /// `FdrFJe`, the session id.
        let sid: String
        let capturedAt: Date
    }

    /// Scraping the page costs an extra round trip, so the tokens are held for a
    /// few minutes. Dropped whenever the RPC rejects them.
    private var cachedTokens: PageTokens?
    private static let tokenLifetime: TimeInterval = 10 * 60

    public init(accountID: String? = nil) {
        self.accountID = accountID
        self.id = accountID.map { "gemini#\($0)" } ?? "gemini"
        self.enabledKey = "aibars.\(self.id).enabled"
        self.isEnabled = userDefaults.object(forKey: enabledKey) as? Bool ?? true
        self.isAuthenticated = SessionStore.shared.hasCredential(for: id)
    }

    public var dashboardURL: URL? { URL(string: "https://gemini.google.com/usage") }

    public var webLogin: WebLoginConfig? {
        // Signing out and back in at /usage is the shortest path to a fresh
        // cookie set, and Google redirects to accounts.google.com by itself.
        // Google does frequently refuse its own sign-in inside an embedded web
        // view ("this browser or app may not be secure"), which is why the hint
        // points at the browser import as the real path.
        WebLoginConfig(
            startURL: URL(string: "https://gemini.google.com/usage")!,
            capture: .cookie(name: Self.primaryCookieName, domainSuffix: "google.com"),
            hint: "Sign in to Google as usual. If Google refuses to sign in here, log in to gemini.google.com in Chrome, Safari or Firefox instead — aibars reads the session from the browser.",
            dataDomains: ["google.com", "gemini.google.com", "accounts.google.com"]
        )
    }

    /// Unofficial on both legs. Nothing here is a documented API: the tokens are
    /// regexed out of the SSR HTML of /usage, and the numbers come from
    /// `jSf9Qc`, an internal batchexecute RPC. Google can rotate the rpcid or
    /// change the positional payload without notice, so treat a parse failure as
    /// "the shape moved", not "the account has no usage".
    public func fetchUsage() async throws -> UsageData {
        guard session.token(for: id) != nil else {
            throw ProviderError.notAuthenticated
        }
        guard let cookieHeader = await currentCookieHeader() else {
            // A stored marker with no readable cookie jar means the browser
            // session went away underneath us.
            await report(.sessionExpired)
            throw ProviderError.sessionExpired
        }

        do {
            let tokens = try await pageTokens(cookieHeader: cookieHeader)
            let usage: UsageData
            do {
                usage = try await requestUsage(tokens: tokens, cookieHeader: cookieHeader)
            } catch let error as ProviderError where Self.isStaleTokenRejection(error) {
                cachedTokens = nil
                let fresh = try await pageTokens(cookieHeader: cookieHeader)
                usage = try await requestUsage(tokens: fresh, cookieHeader: cookieHeader)
            }
            // Without this a one-off failure leaves the row showing an error it
            // has already recovered from.
            await MainActor.run { self.lastError = nil }
            return usage
        } catch let error as ProviderError {
            await report(error)
            throw error
        }
    }

    public func authenticate() async throws {
        let found = await Task.detached(priority: .utility) { [wanted = session.token(for: id)] in
            GoogleGeminiProvider.browserCookies(matching: wanted)
        }.value
        guard let found else { return }

        try session.setToken(found.sid, for: id, source: .browserCookie, accountHint: found.browser.displayName)
        cachedTokens = nil
        await MainActor.run {
            self.isAuthenticated = true
            self.lastError = nil
        }
    }

    public func signOut() async throws {
        session.clear(id)
        cachedTokens = nil
        await MainActor.run {
            self.isAuthenticated = false
            self.lastError = nil
        }
    }

    public func saveTokenManually(_ token: String, source: SessionSource = .manualPaste) throws {
        try session.setToken(token, for: id, source: source)
        cachedTokens = nil
        Task { @MainActor in self.isAuthenticated = true }
    }

    public func setEnabled(_ enabled: Bool) {
        isEnabled = enabled
        userDefaults.set(enabled, forKey: enabledKey)
    }

    // MARK: - Requests

    private func pageTokens(cookieHeader: String) async throws -> PageTokens {
        if let cachedTokens, Date().timeIntervalSince(cachedTokens.capturedAt) < Self.tokenLifetime {
            return cachedTokens
        }

        let url = URL(string: "https://gemini.google.com/usage?pli=1")!
        let (data, _) = try await ProviderHTTP(headers: [
            "Cookie": cookieHeader,
            "User-Agent": Self.chromeUserAgent,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9"
        ]).get(url)

        guard let html = String(data: data, encoding: .utf8) else {
            throw ProviderError.parse("gemini.google.com/usage returned a body that isn't text")
        }
        // A signed-out request still returns HTTP 200 with cfb2h and FdrFJe
        // present — SNlM0e is the only reliable signed-in signal.
        guard let at = Self.wizValue("SNlM0e", in: html) else {
            throw ProviderError.sessionExpired
        }

        // The page sometimes carries the signed-in address and sometimes does
        // not — it varies by account and by whatever variant Google serves. When
        // it is there it is worth far more than "Firefox · Profile 1", so take
        // it opportunistically and leave the name the user typed to win either way.
        if let email = Self.signedInEmail(in: html) {
            discoveredAccount = email
        }

        let tokens = PageTokens(
            at: at,
            bl: Self.wizValue("cfb2h", in: html) ?? "",
            sid: Self.wizValue("FdrFJe", in: html) ?? "",
            capturedAt: Date()
        )
        cachedTokens = tokens
        return tokens
    }

    private func requestUsage(tokens: PageTokens, cookieHeader: String) async throws -> UsageData {
        guard var components = URLComponents(string: "https://gemini.google.com/_/BardChatUi/data/batchexecute") else {
            throw ProviderError.configuration("Could not build the Gemini usage URL")
        }
        var query = [
            URLQueryItem(name: "rpcids", value: Self.usageRPCID),
            URLQueryItem(name: "source-path", value: "/usage"),
            URLQueryItem(name: "hl", value: "en"),
            URLQueryItem(name: "_reqid", value: String(Int.random(in: 100_000...999_999))),
            URLQueryItem(name: "rt", value: "c"),
            // authuser has to be in the query string; the x-goog-authuser header
            // alone gets a 400. Only the default account is supported — a
            // multi-account setup would need tokens scraped from /u/N/usage.
            URLQueryItem(name: "authuser", value: "0")
        ]
        if !tokens.bl.isEmpty { query.append(URLQueryItem(name: "bl", value: tokens.bl)) }
        if !tokens.sid.isEmpty { query.append(URLQueryItem(name: "f.sid", value: tokens.sid)) }
        components.queryItems = query
        guard let url = components.url else {
            throw ProviderError.configuration("Could not build the Gemini usage URL")
        }

        let request = "[[[\"\(Self.usageRPCID)\",\"[]\",null,\"generic\"]]]"
        // The trailing "&" is not cosmetic: batchexecute rejects the body without it.
        let body = "f.req=\(Self.formEncode(request))&at=\(Self.formEncode(tokens.at))&"

        let (data, _) = try await ProviderHTTP(headers: [
            "Cookie": cookieHeader,
            "Content-Type": "application/x-www-form-urlencoded;charset=UTF-8",
            "Origin": "https://gemini.google.com",
            "Referer": "https://gemini.google.com/usage",
            "X-Same-Domain": "1",
            "User-Agent": Self.chromeUserAgent,
            "Accept": "*/*"
        ]).post(url, body: Data(body.utf8))

        guard let text = String(data: data, encoding: .utf8) else {
            throw ProviderError.parse("Gemini batchexecute returned a body that isn't text")
        }
        let usage = try GoogleGeminiUsageParser.parse(GoogleGeminiUsageParser.envelope(text))
        guard let account = discoveredAccount else { return usage }
        // Re-wrap rather than thread the address through the parser: the parser's
        // job is the usage envelope, and the address came from a different page.
        return UsageData(
            providerID: usage.providerID,
            fetchedAt: usage.fetchedAt,
            planName: usage.planName,
            primary: usage.primary,
            secondary: usage.secondary,
            accountLabel: account,
            rawJSON: usage.rawJSON
        )
    }

    // MARK: - Cookies

    private struct ResolvedCookies {
        let header: String
        let sid: String
        let browser: BrowserCookie.Browser
    }

    /// Prefers whatever the browsers hold right now, because `__Secure-1PSIDTS`
    /// in the Keychain is stale within minutes. Falls back to a pasted value.
    private func currentCookieHeader() async -> String? {
        // No token, no session. This used to fall through to "any Google session
        // in any browser" and store it, which meant signing out did nothing: the
        // next refresh, seconds later, claimed a session again and the row came
        // back. Adopting a session is AppState's job and happens once, where the
        // user's choice to sign out can be honoured.
        guard let stored = session.token(for: id)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !stored.isEmpty
        else { return nil }

        // Google rotates __Secure-1PSIDTS within minutes, so the browser is
        // still consulted every fetch — but only for this account's own profile.
        let wanted = stored.contains("=") ? nil : stored
        let lookup = Task.detached(priority: .utility) { [wanted] in
            GoogleGeminiProvider.browserCookies(matching: wanted)
        }
        if let live = await lookup.value {
            return live.header
        }

        // A paste is either a whole Cookie header copied from DevTools or a bare
        // __Secure-1PSID value. The bare value will usually earn a logged-out
        // shell, which surfaces as .sessionExpired.
        return stored.contains("=") ? stored : "\(Self.primaryCookieName)=\(stored)"
    }

    /// Resolves the cookie family for one account.
    ///
    /// `matching` is the account's own `__Secure-1PSID`. Without it this took the
    /// first profile it found for every instance, so several Gemini accounts all
    /// read one session — same usage, same address — and each overwrote its own
    /// stored token with that session's. Cookies must be grouped by profile and
    /// the group matched to the account, because a profile holds exactly one
    /// Google session and the family only makes sense taken together.
    private static func browserCookies(matching sid: String?) -> ResolvedCookies? {
        var fallback: ResolvedCookies?
        for extractor in CookieExtractors.available() {
            guard let cookies = try? extractor.cookies(for: "google.com") else { continue }
            for profile in Set(cookies.map { $0.profile ?? "" }).sorted() {
                var byName: [String: String] = [:]
                for cookie in cookies
                where (cookie.profile ?? "") == profile
                    && cookieFamily.contains(cookie.name)
                    && cookieHosts.contains(cookie.domain.lowercased())
                    && !cookie.value.isEmpty {
                    if byName[cookie.name] == nil { byName[cookie.name] = cookie.value }
                }
                guard let found = byName[primaryCookieName] else { continue }
                let header = cookieFamily
                    .compactMap { name in byName[name].map { "\(name)=\($0)" } }
                    .joined(separator: "; ")
                let resolved = ResolvedCookies(header: header, sid: found, browser: extractor.browser)
                if let sid {
                    if found == sid { return resolved }
                } else {
                    // No account to match yet: remember the first and keep looking
                    // in case a later profile is an exact match.
                    if fallback == nil { fallback = resolved }
                }
            }
        }
        return fallback
    }

    // MARK: - Helpers

    /// Pulls `"<key>":"<value>"` out of the inline WIZ_global_data blob.
    /// The most recently seen address for this account, if the page named one.
    private var discoveredAccount: String?

    /// Google's own domains appear as addresses all over the markup, so those
    /// are excluded rather than reported as the user's account.
    private static func signedInEmail(in html: String) -> String? {
        guard let regex = try? NSRegularExpression(
            pattern: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[a-z]{2,10}"#
        ) else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var found: String?
        regex.enumerateMatches(in: html, range: range) { match, _, stop in
            guard let match, let r = Range(match.range, in: html) else { return }
            let candidate = String(html[r])
            let lower = candidate.lowercased()
            guard !lower.hasSuffix("google.com"),
                  !lower.contains("gstatic"),
                  !lower.contains("googleapis"),
                  !lower.contains("example")
            else { return }
            found = candidate
            stop.pointee = true
        }
        return found
    }

    private static func wizValue(_ key: String, in html: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "\"\(key)\":\"([^\"]+)\"") else { return nil }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        guard let match = regex.firstMatch(in: html, range: range),
              match.numberOfRanges > 1,
              let valueRange = Range(match.range(at: 1), in: html) else { return nil }
        return String(html[valueRange])
    }

    /// The one failure a second round trip can fix: batchexecute refusing the
    /// scraped at/bl pair, which arrives as a wire error behind an HTTP 200. A
    /// rate limit or a timeout is reported as itself — retrying either would
    /// double the traffic Google has already pushed back on.
    private static func isStaleTokenRejection(_ error: ProviderError) -> Bool {
        guard case .parse(let message) = error else { return false }
        return message.hasPrefix(GoogleGeminiUsageParser.wireErrorPrefix)
    }

    private static func formEncode(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
    }

    private func report(_ error: ProviderError) async {
        await MainActor.run {
            self.lastError = error
            if error.isAuth {
                // Scraped tokens are worthless once the session is gone.
                self.cachedTokens = nil
                self.isAuthenticated = false
            }
        }
    }
}

public enum GoogleGeminiUsageParser {
    /// How the message thrown for a rejected at/bl pair opens. The provider
    /// matches on it to decide whether re-scraping the page is worth a round
    /// trip, so the two have to agree.
    public static let wireErrorPrefix = "Gemini batchexecute reported error"

    /// Stage 2 of the wire format, as captured from a live Pro account:
    ///
    ///   [2, [[46815, 0.03241196, 2, [[1779799240, 527944000]]],
    ///        [2396, 0.01,       1, [[1779428440, 527781000]]]], false]
    ///
    /// That is `[planTier, [bucket…], flag]`, and each bucket is
    /// `[creditsRemaining, fractionUsed, windowType, [[resetSeconds, nanos]]]`
    /// where windowType 1 is the rolling ~5-hour window and 2 is the week.
    /// Bucket order is not stable, so windows are matched on the type field.
    ///
    /// Accepted wrappers: the decoded payload under `payload` / `data` /
    /// `result` / `response` / `usage` / the rpcid, or an undecoded wire body
    /// under `body` / `raw` / `text`. Anything else gets a structural search.
    public static func parse(_ raw: [String: Any]) throws -> UsageData {
        let container = try payloadContainer(in: raw)
        let found = buckets(in: container).sorted { $0.type < $1.type }
        guard !found.isEmpty else {
            throw ProviderError.parse(
                "No usage window in the Gemini payload — expected [remaining, fraction, type, [[reset, nanos]]]"
            )
        }

        let fiveHour = found.first { $0.type == 1 }
        let weekly = found.first { $0.type == 2 }

        var lanes: [UsageMetric] = []
        if let fiveHour { lanes.append(percentMetric(fiveHour, label: "5 Hours", window: "5h window")) }
        if let weekly { lanes.append(percentMetric(weekly, label: "Weekly", window: "7d window")) }
        // A window type we don't have a name for, but which carries a reset, is
        // still real usage — surface it rather than drop it.
        for other in found where other.type != 1 && other.type != 2 {
            lanes.append(percentMetric(other, label: "Window \(other.type)", window: nil))
        }

        guard let primary = lanes.first else {
            throw ProviderError.parse("Gemini payload had windows but none could be rendered")
        }

        var secondary = Array(lanes.dropFirst())
        // Credits remaining has no ceiling in the payload (the total is only
        // implied by remaining / (1 - fraction)), so it stays status-only.
        if let fiveHour, fiveHour.remaining > 0 {
            secondary.append(UsageMetric(label: "5h credits left", used: fiveHour.remaining, limit: 0, unit: "credits"))
        }
        if let weekly, weekly.remaining > 0 {
            secondary.append(UsageMetric(label: "Weekly credits left", used: weekly.remaining, limit: 0, unit: "credits"))
        }

        return UsageData(
            providerID: "gemini",
            planName: planTier(in: container).flatMap(planName),
            primary: primary,
            secondary: secondary,
            rawJSON: encoded(raw)
        )
    }

    /// Stage 1: the batchexecute envelope. Returns the decoded RPC payload
    /// wrapped for `parse`.
    ///
    /// The body opens with the `)]}'` anti-hijacking prefix, then alternates
    /// chunk-length lines with JSON arrays. Payload rows look like
    /// `["wrb.fr", "<rpcid>", "<payload as a JSON string>", …]`; failures arrive
    /// as `["er", null, null, null, null, 400, …]` with an HTTP 200 around them.
    public static func envelope(_ body: String) throws -> [String: Any] {
        var payloads: [Any] = []
        var wireError: Int?

        for row in rows(in: body) {
            guard let tag = row.first as? String else { continue }
            if tag == "er" {
                if row.count > 5, let code = ProviderNumber.coerce(row[5]) { wireError = Int(code) }
                continue
            }
            // The rpcid at row[1] is deliberately not checked: Google rotates
            // these ids, and the payload shape is the stronger signal.
            guard tag == "wrb.fr", row.count > 2, let json = row[2] as? String,
                  let decoded = try? JSONSerialization.jsonObject(with: Data(json.utf8))
            else { continue }
            payloads.append(decoded)
        }

        if let usable = payloads.first(where: { !buckets(in: $0).isEmpty }) {
            return ["payload": usable]
        }
        if let wireError {
            throw ProviderError.parse("\(wireErrorPrefix) \(wireError) — stale at/bl token, most likely")
        }
        if let first = payloads.first {
            return ["payload": first]
        }
        throw ProviderError.parse("No wrb.fr payload in the Gemini batchexecute response")
    }

    // MARK: - Internals

    private struct Bucket {
        let remaining: Double
        let fraction: Double
        let type: Int
        let reset: Date?
    }

    private static func payloadContainer(in raw: [String: Any]) throws -> Any {
        for key in ["payload", "data", "result", "response", "usage", "jSf9Qc"] {
            if let value = raw[key] { return value }
        }
        for key in ["body", "raw", "text"] {
            if let text = raw[key] as? String {
                return try envelope(text)["payload"] ?? []
            }
        }
        return raw
    }

    /// Structural search, Voyager-style: find arrays that look like a window
    /// bucket wherever they sit. Positional payloads gain and lose leading
    /// fields between releases, so indexes are never trusted.
    private static func buckets(in value: Any) -> [Bucket] {
        if let array = value as? [Any] {
            if let bucket = bucket(from: array) { return [bucket] }
            return array.flatMap { buckets(in: $0) }
        }
        if let dict = value as? [String: Any] {
            return dict.values.flatMap { buckets(in: $0) }
        }
        return []
    }

    private static func bucket(from array: [Any]) -> Bucket? {
        guard array.count >= 3,
              let remaining = ProviderNumber.coerce(array[0]),
              let fraction = ProviderNumber.coerce(array[1]),
              let rawType = ProviderNumber.coerce(array[2]),
              remaining >= 0, remaining == remaining.rounded(),
              fraction >= 0, fraction <= 1,
              rawType >= 0, rawType < 1_000, rawType == rawType.rounded()
        else { return nil }

        let reset = array.count > 3 ? timestamp(array[3]) : nil
        let type = Int(rawType)
        // Ultra payloads carry an internal type-4 sentinel with no reset. A
        // bucket that is neither a window we know nor timestamped is not usage.
        guard type == 1 || type == 2 || reset != nil else { return nil }
        return Bucket(remaining: remaining, fraction: fraction, type: type, reset: reset)
    }

    private static func percentMetric(_ bucket: Bucket, label: String, window: String?) -> UsageMetric {
        UsageMetric(
            label: label,
            used: (bucket.fraction * 1_000).rounded() / 10,
            limit: 100,
            unit: "%",
            resetDate: bucket.reset,
            windowLabel: window,
            windowDuration: windowDuration(forType: bucket.type),
            windowKey: windowKey(forType: bucket.type)
        )
    }

    /// How long a window of this type is, or nil where we have no name for it.
    ///
    /// Not read off the reset dates and not averaged over two fetches: the type
    /// field is what names the window, and the two named types have fixed
    /// lengths — the same claim the window labels above already make in words.
    /// A type we have never seen gets nothing, because the pace notch is drawn
    /// against this and a notch on a guessed length is a guessed instrument.
    private static func windowDuration(forType type: Int) -> TimeInterval? {
        switch type {
        case 1: return 5 * 60 * 60
        case 2: return 7 * 24 * 60 * 60
        default: return nil
        }
    }

    /// The history series key, taken from the payload's own window type.
    ///
    /// The unnamed buckets are the reason this is not left to the label. They
    /// render as "Window 7", a string this file generates and may reword — and
    /// a key derived from a generated label forks the series the day the wording
    /// moves, orphaning every reading behind it. The type is the only name
    /// Google gives these windows, so it is the one thing that can be the key.
    private static func windowKey(forType type: Int) -> String {
        "window_type_\(type)"
    }

    /// The tier sits at index 0 of the payload, ahead of the bucket array.
    private static func planTier(in container: Any) -> Int? {
        if let array = container as? [Any], bucket(from: array) == nil,
           let tier = ProviderNumber.coerce(array.first),
           tier > 0, tier < 100, tier == tier.rounded() {
            return Int(tier)
        }
        if let dict = container as? [String: Any] {
            for key in ["planTier", "plan_tier", "tier", "plan"] {
                if let tier = ProviderNumber.coerce(dict[key]), tier > 0 { return Int(tier) }
            }
        }
        return nil
    }

    /// Only three ids have been observed. The integer for Google AI Plus is not
    /// public, so an unknown id renders as no plan label rather than a guess.
    private static func planName(_ tier: Int) -> String? {
        switch tier {
        case 1: return "Free"
        case 2: return "Google AI Pro"
        case 3, 6: return "Google AI Ultra"
        default: return nil
        }
    }

    /// `[[seconds, nanos]]` in practice, but the nesting has changed before.
    /// Only a plausible epoch is accepted, which also rejects the nanos field.
    private static func timestamp(_ value: Any?) -> Date? {
        if let nested = value as? [Any] {
            for element in nested {
                if let date = timestamp(element) { return date }
            }
            return nil
        }
        guard let seconds = ProviderNumber.coerce(value) else { return nil }
        if seconds > 1_600_000_000, seconds < 4_000_000_000 {
            return Date(timeIntervalSince1970: seconds)
        }
        if seconds > 1_600_000_000_000, seconds < 4_000_000_000_000 {
            return Date(timeIntervalSince1970: seconds / 1_000)
        }
        return nil
    }

    /// Splits the envelope into rows. Chunk lengths are bare integers on their
    /// own line; an array can span several lines, so the buffer is only cleared
    /// once it parses.
    private static func rows(in body: String) -> [[Any]] {
        var text = body
        if let prefix = text.range(of: ")]}'") {
            text = String(text[prefix.upperBound...])
        }

        var rows: [[Any]] = []
        var buffer = ""
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if buffer.isEmpty, Int(trimmed) != nil { continue }
            buffer += trimmed
            guard let object = try? JSONSerialization.jsonObject(with: Data(buffer.utf8)) else { continue }
            if let chunk = object as? [Any] {
                rows.append(contentsOf: chunk.compactMap { $0 as? [Any] })
            }
            buffer = ""
        }
        return rows
    }

    private static func encoded(_ raw: [String: Any]) -> String? {
        guard JSONSerialization.isValidJSONObject(raw) else { return nil }
        return try? JSONSerialization.data(withJSONObject: raw).base64EncodedString()
    }
}
