import Foundation
import SQLite3

/// Reads cookies from Firefox profiles.
///
/// Firefox cookies are not encrypted by default, so this can return
/// usable values without keychain access.
public final class FirefoxCookieExtractor: CookieExtractor {
    public let browser: BrowserCookie.Browser = .firefox

    private let profileDirs: [URL]

    public init?() {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Firefox/Profiles")
        guard let contents = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else {
            return nil
        }
        self.profileDirs = contents.filter { $0.hasDirectoryPath }
    }

    public var isAvailable: Bool {
        !profileDirs.isEmpty
    }

    public func cookies(for domain: String) throws -> [BrowserCookie] {
        var all: [BrowserCookie] = []
        for profile in profileDirs {
            let cookiesFile = profile.appendingPathComponent("cookies.sqlite")
            guard FileManager.default.fileExists(atPath: cookiesFile.path) else { continue }

            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("aibars-ff-\(UUID().uuidString).sqlite")
            try? FileManager.default.copyItem(at: cookiesFile, to: tmp)
            defer { try? FileManager.default.removeItem(at: tmp) }

            var db: OpaquePointer?
            guard sqlite3_open_v2(tmp.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { continue }
            defer { sqlite3_close(db) }

            let sql = "SELECT name, value, host, path, expiry FROM moz_cookies WHERE host LIKE ?;"
            var statement: OpaquePointer?
            defer { sqlite3_finalize(statement) }
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { continue }
            sqlite3_bind_text(statement, 1, "%\(domain)%", -1, SQLITE_TRANSIENT)

            while sqlite3_step(statement) == SQLITE_ROW {
                let name = String(cString: sqlite3_column_text(statement, 0))
                let value = String(cString: sqlite3_column_text(statement, 1))
                let host = String(cString: sqlite3_column_text(statement, 2))
                let path = String(cString: sqlite3_column_text(statement, 3))
                let expirySec = sqlite3_column_int64(statement, 4)
                let expiresAt: Date? = expirySec > 0
                    ? Date(timeIntervalSince1970: TimeInterval(expirySec))
                    : nil
                all.append(BrowserCookie(
                    name: name, value: value, domain: host, path: path,
                    expiresAt: expiresAt, source: .firefox
                ))
            }
        }
        return all
    }
}
