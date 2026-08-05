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
    private let dbURL: URL
    public let variant: ChromeBasedBrowser
    /// Derived lazily and only once: each miss is a keychain round trip, and a
    /// denied prompt should not be re-asked for every cookie in the table.
    private var cachedKey: Result<Data, Error>?

    public init?(variant: ChromeBasedBrowser) {
        self.variant = variant
        self.browser = variant.browserEnum
        guard let url = variant.cookiesURL() else { return nil }
        self.dbURL = url
    }

    private func decryptionKey() -> Data? {
        if let cachedKey { return try? cachedKey.get() }
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

    public var isAvailable: Bool {
        FileManager.default.fileExists(atPath: dbURL.path)
    }

    public func cookies(for domain: String) throws -> [BrowserCookie] {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibars-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try FileManager.default.copyItem(at: dbURL, to: tmp)

        var db: OpaquePointer?
        guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            throw ProviderError.configuration("Could not open \(variant.rawValue) cookies database.")
        }
        defer { sqlite3_close(db) }

        let sql = "SELECT name, host_key, path, expires_utc, value, encrypted_value FROM cookies WHERE host_key LIKE ?;"
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProviderError.configuration("Could not query cookies.")
        }
        let like = "%" + domain + "%"
        sqlite3_bind_text(statement, 1, like, -1, SQLITE_TRANSIENT)

        var cookies: [BrowserCookie] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let name = columnText(statement, 0) ?? ""
            let host = columnText(statement, 1) ?? ""
            let path = columnText(statement, 2) ?? "/"
            let expiresUS = sqlite3_column_int64(statement, 3)
            // Chromium leaves `value` empty and puts the real thing in
            // `encrypted_value` for everything it has migrated.
            var value = columnText(statement, 4) ?? ""
            if value.isEmpty, let blob = columnBlob(statement, 5), let key = decryptionKey() {
                value = (try? ChromeCookieCrypto.decrypt(blob, key: key)) ?? ""
            }
            let expiresAt: Date? = expiresUS > 0
                ? Date(timeIntervalSince1970: TimeInterval(expiresUS) / 1_000_000 - 11_644_473_600)
                : nil
            cookies.append(BrowserCookie(
                name: name, value: value, domain: host, path: path,
                expiresAt: expiresAt, source: browser
            ))
        }
        return cookies
    }

    private func columnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: cString)
    }

    private func columnBlob(_ stmt: OpaquePointer?, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(stmt, index) else { return nil }
        let count = Int(sqlite3_column_bytes(stmt, index))
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
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
        guard let rel = cookiesRelativePath else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(rel)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}

// SQLite3 needs SQLITE_TRANSIENT for binding text.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
