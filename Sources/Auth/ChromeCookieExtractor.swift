import Foundation
import SQLite3

/// Reads cookies from a Chromium-based browser (Chrome, Edge, Brave, Arc).
///
/// Chromium stores cookies in a SQLite database with the value encrypted.
/// `ChromeCookieCrypto` handles the key, which lives in the login keychain —
/// the first read prompts the user to allow access. If they decline, or the
/// encryption scheme is one we don't recognise, the affected cookies come back
/// with an empty value and the caller falls back to manual entry.
public final class ChromeCookieExtractor: CookieExtractor {
    public let browser: BrowserCookie.Browser
    /// Every profile's cookie database, not just Default. Chrome profiles are
    /// how one person keeps several accounts for the same service signed in at
    /// once — reading only Default found one of four Claude sessions here.
    private let databases: [(profile: String, url: URL)]
    public let variant: ChromeBasedBrowser
    /// Derived lazily and only once: each miss is a keychain round trip, and a
    /// denied prompt should not be re-asked for every cookie in the table.
    private var cachedKey: Result<Data, Error>?

    public init?(variant: ChromeBasedBrowser) {
        self.variant = variant
        self.browser = variant.browserEnum
        let found = variant.cookieDatabases()
        guard !found.isEmpty else { return nil }
        self.databases = found
    }

    /// Whether a key is already in hand, so a read can proceed without putting
    /// a keychain dialog on screen.
    var hasCachedKey: Bool {
        (try? cachedKey?.get()) != nil
    }

    /// Clears a remembered refusal so the next explicit request asks again. A
    /// key that worked is kept, so approving one browser doesn't re-prompt for
    /// the others.
    func forgetFailedKey() {
        guard let cachedKey, (try? cachedKey.get()) == nil else { return }
        self.cachedKey = nil
    }

    private func decryptionKey(allowingPrompt: Bool) -> Data? {
        if let cachedKey { return try? cachedKey.get() }
        // Deriving the key is what triggers the dialog, so a background sweep
        // stops here rather than interrupting the user.
        guard allowingPrompt else { return nil }
        let result = Result {
            try ChromeCookieCrypto.deriveKey(
                from: try ChromeCookieCrypto.storageKey(
                    service: variant.safeStorageService,
                    account: variant.safeStorageAccount
                )
            )
        }
        cachedKey = result
        return try? result.get()
    }

    public var isAvailable: Bool { !databases.isEmpty }

    /// Silent by default. A caller that wants the keychain prompt has to say so
    /// through `cookies(forAnyOf:allowingKeychainPrompt:)`.
    public func cookies(for domain: String) throws -> [BrowserCookie] {
        try cookies(forAnyOf: [domain], allowingKeychainPrompt: false)
    }

    public func cookies(forAnyOf domains: [String], allowingKeychainPrompt: Bool) throws -> [BrowserCookie] {
        guard !domains.isEmpty else { return [] }
        var cookies: [BrowserCookie] = []
        for database in databases {
            guard let found = try? profileCookies(database, domains: domains, allowingKeychainPrompt: allowingKeychainPrompt) else { continue }
            cookies.append(contentsOf: found)
        }
        return cookies
    }

    private func profileCookies(
        _ database: (profile: String, url: URL),
        domains: [String],
        allowingKeychainPrompt: Bool
    ) throws -> [BrowserCookie] {
        let snapshot = try SQLiteSnapshot(of: database.url)
        defer { snapshot.close() }

        let clause = domains.map { _ in "host_key LIKE ?" }.joined(separator: " OR ")
        var cookies: [BrowserCookie] = []
        try snapshot.query(
            "SELECT name, host_key, path, expires_utc, value, encrypted_value FROM cookies WHERE \(clause);",
            bind: domains.map { "%\($0)%" }
        ) { row in
            // Chromium leaves `value` empty and puts the real thing in
            // `encrypted_value` for everything it has migrated.
            var value = SQLiteSnapshot.text(row, 4) ?? ""
            if value.isEmpty, let blob = SQLiteSnapshot.blob(row, 5), let key = decryptionKey(allowingPrompt: allowingKeychainPrompt) {
                value = (try? ChromeCookieCrypto.decrypt(blob, key: key)) ?? ""
            }
            // Chromium timestamps are microseconds since 1601.
            let expiresMicroseconds = sqlite3_column_int64(row, 3)
            let expiresAt: Date? = expiresMicroseconds > 0
                ? Date(timeIntervalSince1970: TimeInterval(expiresMicroseconds) / 1_000_000 - 11_644_473_600)
                : nil
            cookies.append(BrowserCookie(
                name: SQLiteSnapshot.text(row, 0) ?? "",
                value: value,
                domain: SQLiteSnapshot.text(row, 1) ?? "",
                path: SQLiteSnapshot.text(row, 2) ?? "/",
                expiresAt: expiresAt,
                source: browser,
                profile: database.profile
            ))
        }
        return cookies
    }
}

public enum ChromeBasedBrowser: String, CaseIterable {
    case chrome, edge, brave, arc, chromium, opera

    public var browserEnum: BrowserCookie.Browser {
        switch self {
        case .chrome, .chromium: return .chrome
        case .edge: return .edge
        case .brave: return .brave
        case .arc: return .arc
        case .opera: return .chrome
        }
    }

    public var cookiesRelativePath: String? {
        switch self {
        case .chrome: return "Library/Application Support/Google/Chrome/Default/Cookies"
        case .edge:   return "Library/Application Support/Microsoft Edge/Default/Cookies"
        case .brave:  return "Library/Application Support/BraveSoftware/Brave-Browser/Default/Cookies"
        case .arc:    return "Library/Application Support/Arc/User Data/Default/Cookies"
        case .chromium: return "Library/Application Support/Chromium/Default/Cookies"
        case .opera:  return "Library/Application Support/com.operasoftware.Opera/Cookies"
        }
    }

    /// Keychain coordinates of the browser's Safe Storage password.
    public var safeStorageService: String {
        switch self {
        case .chrome:   return "Chrome Safe Storage"
        case .edge:     return "Microsoft Edge Safe Storage"
        case .brave:    return "Brave Safe Storage"
        case .arc:      return "Arc Safe Storage"
        case .chromium: return "Chromium Safe Storage"
        case .opera:    return "Opera Safe Storage"
        }
    }

    public var safeStorageAccount: String {
        switch self {
        case .chrome:   return "Chrome"
        case .edge:     return "Microsoft Edge"
        case .brave:    return "Brave"
        case .arc:      return "Arc"
        case .chromium: return "Chromium"
        case .opera:    return "Opera"
        }
    }

    /// Bundle identifiers, for matching against the user's default browser.
    public var bundleIdentifiers: [String] {
        switch self {
        case .chrome:   return ["com.google.chrome", "com.google.chrome.beta", "com.google.chrome.canary"]
        case .edge:     return ["com.microsoft.edgemac", "com.microsoft.edgemac.beta"]
        case .brave:    return ["com.brave.browser", "com.brave.browser.beta"]
        case .arc:      return ["company.thebrowser.browser", "company.thebrowser.arc"]
        case .chromium: return ["org.chromium.chromium"]
        case .opera:    return ["com.operasoftware.opera"]
        }
    }

    public func cookiesURL() -> URL? {
        cookieDatabases().first?.url
    }

    /// Chromium keeps one directory per profile beside `Default`, each with its
    /// own cookie database.
    public func cookieDatabases() -> [(profile: String, url: URL)] {
        guard let root = userDataDirectory else { return [] }
        let manager = FileManager.default
        let candidates = ((try? manager.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { $0 == "Default" || $0.hasPrefix("Profile ") }
            .sorted { lhs, rhs in
                // Default first, then numerically rather than "Profile 10" < "Profile 2".
                if lhs == "Default" { return true }
                if rhs == "Default" { return false }
                return (Int(lhs.dropFirst(8)) ?? 0) < (Int(rhs.dropFirst(8)) ?? 0)
            }
        return candidates.compactMap { name in
            let url = root.appendingPathComponent(name).appendingPathComponent("Cookies")
            guard manager.fileExists(atPath: url.path) else { return nil }
            return (name, url)
        }
    }

    /// The directory holding the profile folders.
    private var userDataDirectory: URL? {
        guard let rel = cookiesRelativePath else { return nil }
        // "…/Chrome/Default/Cookies" -> "…/Chrome"
        let full = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(rel)
        return full.deletingLastPathComponent().deletingLastPathComponent()
    }
}
