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
        var counts: [String: Int] = [:]
        for row in census(queries, of: available(), allowingKeychainPrompt: false) where row.isLocked {
            counts[row.queryKey, default: 0] += 1
        }
        return counts
    }

    // MARK: - Per-browser sources

    /// One browser aibars can read sessions out of, and what is in it.
    ///
    /// The browser is the unit because it is the unit of everything the user has
    /// to do: a Chromium cookie key is per browser and costs one keychain dialog,
    /// Full Disk Access is Safari's alone, and Firefox needs neither. A single
    /// line naming the default browser could not say any of that truthfully — the
    /// sweep reads every browser installed, so "unlock 4 more" was speaking for
    /// browsers it had not named.
    public struct BrowserSource: Identifiable {
        /// Stable per-browser identity, and what `unlock(_:for:)` takes. Not the
        /// `BrowserCookie.Browser` enum: Chrome, Chromium and Opera all report
        /// `.chrome` and share none of each other's keychain keys.
        public let id: String
        public let browser: BrowserCookie.Browser
        /// What to call it on screen — "Microsoft Edge", not "edge".
        public let name: String
        /// Sessions readable right now, counted per profile per query.
        public let readable: Int
        /// Sessions that are there and cannot be read: a Chromium value behind a
        /// key nobody has asked for, or a cookie the browser wrote empty. Only
        /// `requirement` says which, so only it can promise a button would help.
        public let locked: Int
        /// What stands between aibars and this browser's sessions, if anything.
        public let requirement: Requirement?
        /// The same counts split by profile, for the browsers that have them.
        /// Empty for Safari, which has one jar and no profile names to report.
        public let profiles: [Profile]

        /// One browser profile's share of the counts. Two profiles signed into
        /// the same service are two accounts, and naming the profile is the only
        /// thing that says which one the locked session is in — a keychain dialog
        /// certainly won't.
        public struct Profile: Identifiable {
            public var id: String { name }
            public let name: String
            public let readable: Int
            public let locked: Int
        }

        public enum Requirement: Equatable {
            /// A Chromium browser whose cookie key is in the login keychain.
            /// Asking for it is one dialog, about this browser only.
            case keychainKey
            /// Safari keeps its jar in a TCC-protected container.
            case fullDiskAccess
        }

        /// Sessions found, readable or not.
        public var total: Int { readable + locked }
    }

    /// What each installed browser holds, so a UI can offer one row and one
    /// action per browser instead of one line about the default one.
    ///
    /// Silent, like `lockedSessionCounts`: it reports what is there and unlocks
    /// nothing. Safari appears even with no extractor behind it — its jar is
    /// TCC-protected, so without Full Disk Access the file reads as absent and
    /// the browser would simply be missing from a list built from `available()`,
    /// which is the one case the user most needs told about.
    public static func sessionSources(_ queries: [Query]) -> [BrowserSource] {
        // Nothing to look for is not the same answer as nothing to find, and a
        // row reading "nothing signed in here" would be a lie either way.
        guard !queries.isEmpty else { return [] }
        let extractors = available()
        let rows = census(queries, of: extractors, allowingKeychainPrompt: false)

        var sources = extractors.map { extractor -> BrowserSource in
            let id = identifier(of: extractor)
            let mine = rows.filter { $0.sourceID == id }
            let locked = mine.filter(\.isLocked).count
            let readable = mine.count - locked
            return BrowserSource(
                id: id,
                browser: extractor.browser,
                name: displayName(of: extractor),
                readable: readable,
                locked: locked,
                requirement: requirement(of: extractor, readable: readable, locked: locked),
                profiles: profiles(in: mine)
            )
        }
        if let safari = unreachableSafari() { sources.append(safari) }
        // Whatever holds something goes first: this list exists to be acted on,
        // and a browser with nothing in it is the line nobody needs to read.
        return sources.sorted {
            ($0.total > 0 ? 0 : 1, $0.name) < ($1.total > 0 ? 0 : 1, $1.name)
        }
    }

    /// Asks one browser for its cookie key, and asks no other browser anything.
    ///
    /// A sweep with prompts allowed walks every extractor, so it can raise a
    /// keychain dialog per Chromium browser installed with nothing on screen
    /// saying which one is being asked about. This reads exactly the browser the
    /// user pressed Unlock on. The key it derives is cached for the life of the
    /// process, so the ordinary silent sweep picks those sessions up afterwards —
    /// the caller does not have to allow prompts a second time, and must not.
    ///
    /// Returns how many sessions that browser can answer now, so a caller can
    /// tell an approval from a dismissed dialog. Zero for a refusal even when the
    /// browser holds sessions that were readable all along: a Chromium profile
    /// signed in before the browser encrypted anything reads without a key, and
    /// counting those would report a dismissed dialog as an unlock.
    @discardableResult
    public static func unlock(_ sourceID: String, for queries: [Query]) -> Int {
        let targets = available().filter { identifier(of: $0) == sourceID }
        let chromium = targets.compactMap { $0 as? ChromeCookieExtractor }
        // A remembered refusal is what would otherwise make the second press do
        // nothing at all. Only this browser's failed key goes.
        for target in chromium {
            target.forgetFailedKey()
        }
        let readable = census(queries, of: targets, allowingKeychainPrompt: true)
            .filter { !$0.isLocked }
            .count
        // The dialog is the only thing that can put a key in hand, so no key
        // after a read that was allowed to ask for one means it was refused.
        guard chromium.isEmpty || chromium.contains(where: \.hasCachedKey) else { return 0 }
        return readable
    }

    /// One session, as found in one profile of one browser: either readable or
    /// locked. `lockedSessionCounts`, `sessionSources` and `unlock` all want this
    /// same traversal counted differently, and sharing it is what keeps a row
    /// that reports "locked" from disagreeing with a sweep that finds a session.
    private struct CensusRow {
        let sourceID: String
        let profile: String
        let queryKey: String
        let isLocked: Bool
    }

    private static func census(
        _ queries: [Query],
        of extractors: [CookieExtractor],
        allowingKeychainPrompt: Bool
    ) -> [CensusRow] {
        guard !queries.isEmpty, !extractors.isEmpty else { return [] }
        let domains = Array(Set(queries.map(\.domain)))

        var rows: [CensusRow] = []
        for extractor in extractors {
            guard let jar = try? extractor.cookies(
                forAnyOf: domains,
                allowingKeychainPrompt: allowingKeychainPrompt
            ) else { continue }
            let sourceID = identifier(of: extractor)

            for query in queries {
                let scoped = jar.filter { matches(domain: $0.domain, query.domain) }
                // Grouped by profile for the same reason `searchAll` groups: one
                // profile holds at most one session per service.
                for profile in Set(scoped.map { $0.profile ?? "" }).sorted() {
                    let inProfile = scoped.filter { ($0.profile ?? "") == profile }
                    if resolve(names: query.names, in: inProfile) != nil {
                        rows.append(CensusRow(sourceID: sourceID, profile: profile, queryKey: query.key, isLocked: false))
                        continue
                    }
                    // The name is there, the value is not.
                    let named = inProfile.filter { cookie in
                        query.names.contains { cookie.name == $0 || cookie.name.hasPrefix($0 + ".") }
                    }
                    guard !named.isEmpty, named.allSatisfy({ $0.value.isEmpty }) else { continue }
                    rows.append(CensusRow(sourceID: sourceID, profile: profile, queryKey: query.key, isLocked: true))
                }
            }
        }
        return rows
    }

    /// What stands between aibars and one browser's sessions.
    ///
    /// Nothing until something is actually locked, and nothing an ask can fix
    /// once the key is in hand: Chrome's app-bound cookies decrypt to nothing
    /// with the Safe Storage key already derived, so offering to request a key we
    /// hold is a button that raises no dialog and moves no count.
    private static func requirement(
        of extractor: CookieExtractor,
        readable: Int,
        locked: Int
    ) -> BrowserSource.Requirement? {
        if let chromium = extractor as? ChromeCookieExtractor {
            return (locked > 0 && !chromium.hasCachedKey) ? .keychainKey : nil
        }
        // A Safari that holds nothing and a Safari we are forbidden to read look
        // identical from the counts — the extractor exists either way, because
        // TCC denies the `open` rather than the `stat` the extractor initialises
        // from. Only an actual read tells them apart, and "nothing signed in
        // here" is the wrong thing to say about the second one.
        guard extractor.browser == .safari, readable == 0, locked == 0 else { return nil }
        return canOpenSafariJar() ? nil : .fullDiskAccess
    }

    /// Per-profile counts, for the profiles that are actually named. Safari's
    /// cookies carry no profile at all, and an unnamed row on screen is worse
    /// than none.
    private static func profiles(in rows: [CensusRow]) -> [BrowserSource.Profile] {
        Set(rows.map(\.profile))
            .subtracting([""])
            // Numeric-aware, or twelve Chrome profiles list as 1, 10, 11, 12, 2 —
            // which reads as a sorting bug to the one person who has them.
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name in
                let mine = rows.filter { $0.profile == name }
                let locked = mine.filter(\.isLocked).count
                return BrowserSource.Profile(name: name, readable: mine.count - locked, locked: locked)
            }
    }

    /// Safari when macOS will not let us look inside it.
    ///
    /// Without Full Disk Access the cookie file reads as absent, so
    /// `SafariCookieExtractor` refuses to initialise and `available()` never
    /// mentions Safari — the browser vanishes from the list rather than saying
    /// what it needs. Nil once an extractor exists, or on a machine with no
    /// Safari to speak of.
    private static func unreachableSafari() -> BrowserSource? {
        guard !available().contains(where: { $0.browser == .safari }) else { return nil }
        let manager = FileManager.default
        guard safariApps.contains(where: { manager.fileExists(atPath: $0) }) else { return nil }
        return BrowserSource(
            id: BrowserCookie.Browser.safari.rawValue,
            browser: .safari,
            name: BrowserCookie.Browser.safari.displayName,
            readable: 0,
            locked: 0,
            // A jar we can open and still have no extractor for is a path
            // problem, not a permission one, and telling the user to grant access
            // they already granted is worse than saying nothing.
            requirement: canOpenSafariJar() ? nil : .fullDiskAccess,
            profiles: []
        )
    }

    /// Whether Safari's jar will actually open, which is the only honest test for
    /// Full Disk Access. `fileExists` and `isReadableFile` both answer from the
    /// file's metadata, and TCC does not deny that — it denies the `open`, so a
    /// jar that reports readable still throws the moment anything reads it.
    private static func canOpenSafariJar() -> Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return safariCookieJars.contains { relative in
            guard let handle = try? FileHandle(forReadingFrom: home.appendingPathComponent(relative)) else {
                return false
            }
            try? handle.close()
            return true
        }
    }

    /// Both places Safari's jar has lived: the old home-Library path
    /// `SafariCookieExtractor` reads, and the sandboxed container it moved to.
    private static let safariCookieJars = [
        "Library/Cookies/Cookies.binarycookies",
        "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies"
    ]

    /// Where Safari itself lives. macOS 13 moved it into a cryptex and left
    /// `/Applications/Safari.app` behind as a firmlink, which is present on a
    /// normal install and is not something to rely on alone.
    private static let safariApps = [
        "/Applications/Safari.app",
        "/System/Cryptexes/App/System/Applications/Safari.app"
    ]

    /// Stable identity for one browser's cookie store. The `Browser` enum will
    /// not do: Chrome, Chromium and Opera all map to `.chrome`, and each keeps
    /// its own Safe Storage key under its own name.
    private static func identifier(of extractor: CookieExtractor) -> String {
        guard let chromium = extractor as? ChromeCookieExtractor else {
            return extractor.browser.rawValue
        }
        return chromium.variant.rawValue
    }

    /// The name to put on the row. `browser.displayName` would call Chromium and
    /// Opera "Chrome", which is exactly the lie a per-browser list is here to
    /// stop telling.
    private static func displayName(of extractor: CookieExtractor) -> String {
        guard let chromium = extractor as? ChromeCookieExtractor else {
            return extractor.browser.displayName
        }
        switch chromium.variant {
        case .chrome:   return "Chrome"
        case .edge:     return "Microsoft Edge"
        case .brave:    return "Brave"
        case .arc:      return "Arc"
        case .chromium: return "Chromium"
        case .opera:    return "Opera"
        }
    }

    /// Every distinct session for each query, across every browser and profile.
    ///
    /// One person can be signed into the same service several times — Chrome
    /// profiles are the usual way — and `search` deliberately stops at the
    /// first. This does not stop, and dedupes on the credential itself so the
    /// same session seen twice is still one account.
    ///
    /// `extractors` exists so the dedupe can be driven by a test. It defaults to
    /// `available()`, and a default argument is only evaluated when the argument
    /// is omitted — so a caller that passes its own list does not build the real
    /// extractors, and cannot seed the process-lifetime cache behind
    /// `available()` with a stub that would then leak into every later lookup.
    public static func searchAll(
        _ queries: [Query],
        allowingKeychainPrompt: Bool = false,
        extractors: [CookieExtractor] = available()
    ) -> [String: [BrowserCookie]] {
        guard !queries.isEmpty else { return [:] }
        let domains = Array(Set(queries.map(\.domain)))

        var found: [String: [BrowserCookie]] = [:]
        var seen: Set<String> = []
        for extractor in extractors {
            guard let jar = try? extractor.cookies(
                forAnyOf: domains,
                allowingKeychainPrompt: allowingKeychainPrompt
            ) else { continue }

            for query in queries {
                let scoped = jar.filter { matches(domain: $0.domain, query.domain) }
                // Group by profile: one profile holds at most one session per
                // service, and its cookies have to be resolved together so a
                // chunked token isn't stitched across two accounts. Sorted,
                // because when two profiles do hold one session they collapse to
                // a single account below, and the survivor's `origin` would
                // otherwise be whichever row the database handed back first.
                for profile in Set(scoped.map { $0.profile ?? "" }).sorted() {
                    let inProfile = scoped.filter { ($0.profile ?? "") == profile }
                    guard let cookie = resolve(names: query.names, in: inProfile) else { continue }
                    // Keyed by query as well as by value. Two queries can resolve
                    // to one string — a service that writes its session and its
                    // organisation into cookies with the same contents, or two
                    // accounts that are genuinely the same login — and on the
                    // value alone the second query would silently find nothing,
                    // which reads on screen as one of the two services being
                    // signed out. The value alone is only the right key within
                    // one query, which is what this pair says.
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
        return host == wanted || host.hasSuffix("." + wanted)
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
            source: first.source,
            profile: first.profile
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
