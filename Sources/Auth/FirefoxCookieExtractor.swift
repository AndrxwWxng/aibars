import Foundation
import SQLite3

/// Reads cookies from Firefox profiles.
///
/// Firefox cookies are not encrypted, so this returns usable values without
/// keychain access. It does keep them in a WAL database, which is why the read
/// goes through `SQLiteSnapshot`.
public final class FirefoxCookieExtractor: CookieExtractor {
    public let browser: BrowserCookie.Browser = .firefox

    private let profileDirs: [URL]

    public init?() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Firefox/Profiles")
        guard let contents = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return nil
        }
        // Largest database first: a machine accumulates abandoned profiles, and
        // the one the user actually browses in is the one with cookies in it.
        self.profileDirs = contents
            .filter { $0.hasDirectoryPath }
            .map { (url: $0, size: Self.cookieDatabaseSize(in: $0)) }
            .filter { $0.size > 0 }
            .sorted { $0.size > $1.size }
            .map(\.url)
    }

    private static func cookieDatabaseSize(in profile: URL) -> Int {
        let file = profile.appendingPathComponent("cookies.sqlite")
        let attributes = try? FileManager.default.attributesOfItem(atPath: file.path)
        return (attributes?[.size] as? Int) ?? 0
    }

    public var isAvailable: Bool {
        !profileDirs.isEmpty
    }

    public func cookies(for domain: String) throws -> [BrowserCookie] {
        try cookies(forAnyOf: [domain], allowingKeychainPrompt: false)
    }

    /// Firefox needs no key, so the prompt policy is irrelevant here.
    public func cookies(forAnyOf domains: [String], allowingKeychainPrompt: Bool) throws -> [BrowserCookie] {
        guard !domains.isEmpty else { return [] }
        var all: [BrowserCookie] = []
        for profile in profileDirs {
            let cookiesFile = profile.appendingPathComponent("cookies.sqlite")
            guard FileManager.default.fileExists(atPath: cookiesFile.path) else { continue }
            guard let snapshot = try? SQLiteSnapshot(of: cookiesFile) else { continue }
            defer { snapshot.close() }

            let clause = domains.map { _ in "host LIKE ?" }.joined(separator: " OR ")
            try? snapshot.query(
                "SELECT name, value, host, path, expiry FROM moz_cookies WHERE \(clause);",
                bind: domains.map { "%\($0)%" }
            ) { row in
                guard let name = SQLiteSnapshot.text(row, 0),
                      let value = SQLiteSnapshot.text(row, 1) else { return }
                let expirySeconds = sqlite3_column_int64(row, 4)
                all.append(BrowserCookie(
                    name: name,
                    value: value,
                    domain: SQLiteSnapshot.text(row, 2) ?? "",
                    path: SQLiteSnapshot.text(row, 3) ?? "/",
                    expiresAt: expirySeconds > 0 ? Date(timeIntervalSince1970: TimeInterval(expirySeconds)) : nil,
                    source: .firefox
                ))
            }
        }
        return all
    }
}
