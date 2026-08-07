import Foundation

/// A cookie extracted from a browser, ready to be applied to a URLRequest.
public struct BrowserCookie: Hashable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let expiresAt: Date?
    public let source: Browser
    /// Which browser profile it came from. Two profiles signed into the same
    /// service are two accounts, and this is the only thing that tells them
    /// apart before either has been queried.
    public var profile: String?

    /// "Chrome" or "Chrome · Work", for showing next to an account.
    public var origin: String {
        guard let profile, !profile.isEmpty, profile != "Default" else { return source.displayName }
        return "\(source.displayName) · \(profile)"
    }

    public init(
        name: String,
        value: String,
        domain: String,
        path: String,
        expiresAt: Date?,
        source: Browser,
        profile: String? = nil
    ) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expiresAt = expiresAt
        self.source = source
        self.profile = profile
    }

    public enum Browser: String, Codable, CaseIterable {
        case chrome, safari, firefox, edge, brave, arc

        public var displayName: String {
            switch self {
            case .chrome: return "Chrome"
            case .safari: return "Safari"
            case .firefox: return "Firefox"
            case .edge: return "Edge"
            case .brave: return "Brave"
            case .arc: return "Arc"
            }
        }
    }
}

/// Extracts cookies for a given domain from installed browsers.
///
/// This is intentionally permissive about failure: any browser that is not
/// installed, not unlocked, or stored in a format we can't read is silently
/// skipped. Callers should fall back to manual token entry.
public protocol CookieExtractor {
    var browser: BrowserCookie.Browser { get }
    var isAvailable: Bool { get }
    func cookies(for domain: String) throws -> [BrowserCookie]
    /// Several domains in a single read. Worth overriding wherever a read is
    /// expensive — for the SQLite-backed browsers that's one database copy
    /// instead of one per domain.
    ///
    /// `allowingKeychainPrompt` is false for work the user didn't ask for.
    /// Chromium's cookie key lives in the login keychain, and asking for it puts
    /// a system dialog on screen; an app that does that during launch reads as
    /// something trying to steal your passwords. Extractors that need no
    /// keychain access ignore the flag.
    func cookies(forAnyOf domains: [String], allowingKeychainPrompt: Bool) throws -> [BrowserCookie]
}

public extension CookieExtractor {
    func cookies(forAnyOf domains: [String], allowingKeychainPrompt: Bool = false) throws -> [BrowserCookie] {
        try domains.flatMap { try cookies(for: $0) }
    }
}

public enum CookieExtractors {
    /// One query: the names a provider's session may go by, and the domain it
    /// lives on.
    public struct Query {
        public let key: String
        public let names: [String]
        public let domain: String

        public init(key: String, names: [String], domain: String) {
            self.key = key
            self.names = names
            self.domain = domain
        }
    }

    /// Extractors are cached for the life of the process. Rebuilding them per
    /// lookup would throw away each Chromium extractor's derived key, which
    /// means a fresh keychain prompt for every provider on every pass.
    private static let cached = Lock<[CookieExtractor]?>(nil)

    public static func available() -> [CookieExtractor] {
        cached.withLock { store in
            if let store { return store }
            var result: [CookieExtractor] = []
            if let safari = SafariCookieExtractor(), safari.isAvailable {
                result.append(safari)
            }
            if let firefox = FirefoxCookieExtractor(), firefox.isAvailable {
                result.append(firefox)
            }
            for variant in ChromeBasedBrowser.allCases {
                if let chrome = ChromeCookieExtractor(variant: variant), chrome.isAvailable {
                    result.append(chrome)
                }
            }
            store = result
            return result
        }
    }

    /// Forgets the cached extractors, so a browser installed mid-session is
    /// picked up on the next pass. This also discards derived keys, so prefer
    /// `retryLockedKeys()` when the only thing that changed is the user's mind
    /// about a keychain prompt.
    public static func invalidate() {
        cached.withLock { $0 = nil }
    }

    /// Lets a previously refused keychain read be attempted again, without
    /// throwing away the keys that already worked.
    ///
    /// Rebuilding every extractor to retry one refusal meant re-asking for the
    /// browsers that had already been approved — a dialog per browser, every
    /// time the user pressed the button.
    public static func retryLockedKeys() {
        for extractor in available() {
            (extractor as? ChromeCookieExtractor)?.forgetFailedKey()
        }
    }

    /// Resolves several providers' sessions in one sweep.
    ///
    /// Each browser is read once for every domain at once. A read copies the
    /// whole cookie database, so doing this per provider turned a nine-provider
    /// discovery pass into nine copies of Chrome's database.
    /// `allowingKeychainPrompt` defaults to false. Chromium's cookie key lives
    /// in the login keychain and asking for it puts a system dialog on screen,
    /// so a caller has to opt into that deliberately — a provider that reads
    /// cookies on its refresh cycle would otherwise prompt every single minute.
    public static func search(
        _ queries: [Query],
        preferring preferred: BrowserCookie.Browser? = nil,
        allowingKeychainPrompt: Bool = false
    ) -> [String: BrowserCookie] {
        guard !queries.isEmpty else { return [:] }
        let extractors = available().sorted { lhs, rhs in
            (lhs.browser == preferred ? 0 : 1) < (rhs.browser == preferred ? 0 : 1)
        }
        let domains = Array(Set(queries.map(\.domain)))

        var found: [String: BrowserCookie] = [:]
        for extractor in extractors {
            let outstanding = queries.filter { found[$0.key] == nil }
            guard !outstanding.isEmpty else { break }
            guard let jar = try? extractor.cookies(
                forAnyOf: domains,
                allowingKeychainPrompt: allowingKeychainPrompt
            ) else { continue }

            for query in outstanding {
                let scoped = jar.filter { matches(domain: $0.domain, query.domain) }
                guard let cookie = resolve(names: query.names, in: scoped) else { continue }
                found[query.key] = cookie
            }
        }
        return found
    }

    /// Sessions that exist but could not be read, per query.
    ///
    /// A Chromium cookie whose value decrypts to nothing is not absent — it is
    /// locked, because deriving the key needs a keychain dialog the silent sweep
    /// will not raise. Counting them is what lets the UI say "three more Claude
    /// accounts are in Chrome" instead of pretending they do not exist.
    public static func lockedSessionCounts(_ queries: [Query]) -> [String: Int] {
        guard !queries.isEmpty else { return [:] }
        let domains = Array(Set(queries.map(\.domain)))

        var counts: [String: Int] = [:]
        for extractor in available() {
            // Silent: the whole point is to report what is locked, not unlock it.
            guard let jar = try? extractor.cookies(forAnyOf: domains, allowingKeychainPrompt: false) else { continue }
            for query in queries {
                let scoped = jar.filter { matches(domain: $0.domain, query.domain) }
                for profile in Set(scoped.map { $0.profile ?? "" }) {
                    let inProfile = scoped.filter { ($0.profile ?? "") == profile }
                    // The name is there, the value is not.
                    let named = inProfile.filter { cookie in
                        query.names.contains { cookie.name == $0 || cookie.name.hasPrefix($0 + ".") }
                    }
                    guard !named.isEmpty, named.allSatisfy({ $0.value.isEmpty }) else { continue }
                    counts[query.key, default: 0] += 1
                }
            }
        }
        return counts
    }

    /// Every distinct session for each query, across every browser and profile.
    ///
    /// One person can be signed into the same service several times — Chrome
    /// profiles are the usual way — and `search` deliberately stops at the
    /// first. This does not stop, and dedupes on the credential itself so the
    /// same session seen twice is still one account.
    public static func searchAll(
        _ queries: [Query],
        allowingKeychainPrompt: Bool = false
    ) -> [String: [BrowserCookie]] {
        guard !queries.isEmpty else { return [:] }
        let domains = Array(Set(queries.map(\.domain)))

        var found: [String: [BrowserCookie]] = [:]
        var seen: Set<String> = []
        for extractor in available() {
            guard let jar = try? extractor.cookies(
                forAnyOf: domains,
                allowingKeychainPrompt: allowingKeychainPrompt
            ) else { continue }

            for query in queries {
                let scoped = jar.filter { matches(domain: $0.domain, query.domain) }
                // Group by profile: one profile holds at most one session per
                // service, and its cookies have to be resolved together so a
                // chunked token isn't stitched across two accounts.
                for profile in Set(scoped.map { $0.profile ?? "" }).sorted() {
                    let inProfile = scoped.filter { ($0.profile ?? "") == profile }
                    guard let cookie = resolve(names: query.names, in: inProfile) else { continue }
                    let fingerprint = "\(query.key)|\(cookie.value)"
                    guard !seen.contains(fingerprint) else { continue }
                    seen.insert(fingerprint)
                    found[query.key, default: []].append(cookie)
                }
            }
        }
        return found
    }

    /// Try each available extractor, returning the first cookie that actually
    /// has a value. `preferred` is checked first — during a login flow that's
    /// the browser the user just logged in with.
    public static func firstAvailableCookie(
        named name: String,
        for domain: String,
        preferring preferred: BrowserCookie.Browser? = nil,
        allowingKeychainPrompt: Bool = false
    ) -> BrowserCookie? {
        firstAvailableCookie(
            named: [name],
            for: domain,
            preferring: preferred,
            allowingKeychainPrompt: allowingKeychainPrompt
        )
    }

    /// True when a browser's cookies can be read without putting a keychain
    /// dialog on screen — either it needs no key, or the key is already derived.
    public static func canReadSilently(_ browser: BrowserCookie.Browser) -> Bool {
        available().contains { extractor in
            guard extractor.browser == browser else { return false }
            guard let chromium = extractor as? ChromeCookieExtractor else { return true }
            return chromium.hasCachedKey
        }
    }

    /// As above, for services that write one of several cookie names depending
    /// on when the account last signed in.
    public static func firstAvailableCookie(
        named names: [String],
        for domain: String,
        preferring preferred: BrowserCookie.Browser? = nil,
        allowingKeychainPrompt: Bool = false
    ) -> BrowserCookie? {
        search(
            [Query(key: "single", names: names, domain: domain)],
            preferring: preferred,
            allowingKeychainPrompt: allowingKeychainPrompt
        )["single"]
    }

    // MARK: - Matching

    private static func matches(domain cookieDomain: String, _ wanted: String) -> Bool {
        let host = cookieDomain.hasPrefix(".") ? String(cookieDomain.dropFirst()) : cookieDomain
        return host == wanted || host.hasSuffix("." + wanted) || host.contains(wanted)
    }

    /// Prefers a whole cookie, then falls back to reassembling a chunked one.
    private static func resolve(names: [String], in jar: [BrowserCookie]) -> BrowserCookie? {
        for name in names {
            // An empty value means the row was found but not decryptable, which
            // is not a usable session.
            if let whole = jar.first(where: { $0.name == name && !$0.value.isEmpty }) {
                return whole
            }
            if let joined = reassembleChunks(named: name, in: jar) {
                return joined
            }
        }
        return nil
    }

    /// NextAuth and Auth.js split a session token that exceeds the 4KB
    /// per-cookie limit into `<name>.0`, `<name>.1`, … Nothing matching the
    /// bare name is in the jar at all, which is why ChatGPT looked like a
    /// signed-out account while the session was sitting right there.
    private static func reassembleChunks(named name: String, in jar: [BrowserCookie]) -> BrowserCookie? {
        let chunks = jar
            .compactMap { cookie -> (index: Int, cookie: BrowserCookie)? in
                guard cookie.name.hasPrefix(name + "."),
                      let index = Int(cookie.name.dropFirst(name.count + 1)),
                      !cookie.value.isEmpty
                else { return nil }
                return (index, cookie)
            }
            .sorted { $0.index < $1.index }
        guard !chunks.isEmpty, let first = chunks.first?.cookie else { return nil }
        return BrowserCookie(
            name: name,
            value: chunks.map(\.cookie.value).joined(),
            domain: first.domain,
            path: first.path,
            expiresAt: first.expiresAt,
            source: first.source
        )
    }
}

/// Minimal mutex. The extractor cache is touched from whichever thread a
/// discovery pass happens to run on.
final class Lock<Value>: @unchecked Sendable {
    private var value: Value
    private let mutex = NSLock()

    init(_ value: Value) {
        self.value = value
    }

    func withLock<Result>(_ body: (inout Value) -> Result) -> Result {
        mutex.lock()
        defer { mutex.unlock() }
        return body(&value)
    }
}
