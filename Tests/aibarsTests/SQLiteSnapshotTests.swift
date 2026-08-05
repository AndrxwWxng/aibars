import XCTest
import SQLite3
@testable import aibarsCore

final class SQLiteSnapshotTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapshot-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Firefox keeps cookies in WAL mode, and a WAL database cannot be opened
    /// read-only without creating its `-shm` sidecar — the previous
    /// implementation failed on exactly this and silently reported no cookies,
    /// which made browser sign-in impossible for Firefox users. Rows that live
    /// only in the write-ahead log have to come back too.
    func testReadsRowsHeldInTheWriteAheadLog() throws {
        let database = directory.appendingPathComponent("cookies.sqlite")

        var handle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK
        )
        let source = try XCTUnwrap(handle)
        exec(source, "PRAGMA journal_mode=WAL;")
        // Without this, closing or even committing may fold the log back into
        // the main file and the test would pass for the wrong reason.
        exec(source, "PRAGMA wal_autocheckpoint=0;")
        exec(source, "CREATE TABLE moz_cookies (name TEXT, value TEXT, host TEXT, path TEXT, expiry INTEGER);")
        exec(source, "INSERT INTO moz_cookies VALUES ('sessionKey', 'abc123', '.claude.ai', '/', 4102444800);")
        exec(source, "INSERT INTO moz_cookies VALUES ('other', 'zzz', '.example.com', '/', 0);")

        XCTAssertTrue(
            FileManager.default.fileExists(atPath: database.path + "-wal"),
            "the fixture is not actually in WAL mode, so this asserts nothing"
        )

        // The source connection stays open, as a running browser's would be.
        let snapshot = try SQLiteSnapshot(of: database)
        defer { snapshot.close() }

        var rows: [(String, String, String)] = []
        try snapshot.query(
            "SELECT name, value, host FROM moz_cookies WHERE host LIKE ?;",
            bind: ["%claude.ai%"]
        ) { row in
            rows.append((
                SQLiteSnapshot.text(row, 0) ?? "",
                SQLiteSnapshot.text(row, 1) ?? "",
                SQLiteSnapshot.text(row, 2) ?? ""
            ))
        }
        sqlite3_close(source)

        XCTAssertEqual(rows.count, 1, "the LIKE filter should exclude example.com")
        XCTAssertEqual(rows.first?.0, "sessionKey")
        XCTAssertEqual(rows.first?.1, "abc123")
        XCTAssertEqual(rows.first?.2, ".claude.ai")
    }

    func testMissingDatabaseThrowsRatherThanReturningNothing() {
        let missing = directory.appendingPathComponent("absent.sqlite")
        XCTAssertThrowsError(try SQLiteSnapshot(of: missing)) { error in
            // A caller has to be able to tell "no such profile" from "no cookies".
            XCTAssertTrue(error is ProviderError, "got \(type(of: error))")
        }
    }

    func testSnapshotCleansUpAfterItself() throws {
        let database = directory.appendingPathComponent("small.sqlite")
        var handle: OpaquePointer?
        XCTAssertEqual(
            sqlite3_open_v2(database.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil),
            SQLITE_OK
        )
        exec(try XCTUnwrap(handle), "CREATE TABLE t (a INTEGER);")
        sqlite3_close(handle)

        let before = temporaryCopyCount()
        let snapshot = try SQLiteSnapshot(of: database)
        XCTAssertGreaterThan(temporaryCopyCount(), before)
        snapshot.close()
        XCTAssertEqual(temporaryCopyCount(), before)
    }

    // MARK: - Helpers

    private func exec(_ handle: OpaquePointer, _ sql: String) {
        var error: UnsafeMutablePointer<CChar>?
        let status = sqlite3_exec(handle, sql, nil, nil, &error)
        if status != SQLITE_OK {
            XCTFail("\(sql) failed: \(error.map { String(cString: $0) } ?? "code \(status)")")
        }
        sqlite3_free(error)
    }

    private func temporaryCopyCount() -> Int {
        let contents = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        )) ?? []
        return contents.filter { $0.hasPrefix("aibars-cookies-") }.count
    }
}
