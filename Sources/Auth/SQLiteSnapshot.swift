import Foundation
import SQLite3

/// A private, writable copy of a browser's cookie database.
///
/// Two things make this necessary rather than just opening the original:
///
/// 1. The browser holds the file open. Copying first avoids contending with it
///    and avoids any chance of writing to a live profile.
/// 2. Firefox keeps cookies in WAL mode, and SQLite cannot open a WAL database
///    read-only without being able to create its `-shm` sidecar — it fails with
///    `SQLITE_CANTOPEN`. Copying the `-wal` and `-shm` files alongside the main
///    database and opening the copy read-write lets SQLite replay the log, which
///    also matters for correctness: a session cookie written moments ago — the
///    exact thing a login flow is waiting for — may exist only in the WAL.
struct SQLiteSnapshot {
    let handle: OpaquePointer
    private let directory: URL

    /// Sidecars are copied when present; a database in rollback-journal mode
    /// simply won't have them.
    private static let sidecarSuffixes = ["-wal", "-shm"]

    init(of original: URL) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("aibars-cookies-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        self.directory = directory

        let copy = directory.appendingPathComponent(original.lastPathComponent)
        do {
            try FileManager.default.copyItem(at: original, to: copy)
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw ProviderError.configuration("Could not copy \(original.lastPathComponent): \(error.localizedDescription)")
        }
        for suffix in Self.sidecarSuffixes {
            let sidecar = URL(fileURLWithPath: original.path + suffix)
            guard FileManager.default.fileExists(atPath: sidecar.path) else { continue }
            try? FileManager.default.copyItem(
                at: sidecar,
                to: URL(fileURLWithPath: copy.path + suffix)
            )
        }

        var handle: OpaquePointer?
        let status = sqlite3_open_v2(copy.path, &handle, SQLITE_OPEN_READWRITE, nil)
        guard status == SQLITE_OK, let handle else {
            let message = handle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "code \(status)"
            sqlite3_close(handle)
            try? FileManager.default.removeItem(at: directory)
            throw ProviderError.configuration("Could not open \(original.lastPathComponent): \(message)")
        }
        self.handle = handle
    }

    /// Runs a single-statement query, handing each row to `row`.
    func query(_ sql: String, bind text: [String] = [], row: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw ProviderError.configuration("Could not prepare query: \(String(cString: sqlite3_errmsg(handle)))")
        }
        for (index, value) in text.enumerated() {
            sqlite3_bind_text(statement, Int32(index + 1), value, -1, SQLITE_TRANSIENT)
        }
        while sqlite3_step(statement) == SQLITE_ROW, let statement {
            row(statement)
        }
    }

    func close() {
        sqlite3_close(handle)
        try? FileManager.default.removeItem(at: directory)
    }

    static func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    static func blob(_ statement: OpaquePointer, _ index: Int32) -> Data? {
        guard let bytes = sqlite3_column_blob(statement, index) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, index))
        guard count > 0 else { return nil }
        return Data(bytes: bytes, count: count)
    }
}

// SQLite3 needs SQLITE_TRANSIENT for binding text.
let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
