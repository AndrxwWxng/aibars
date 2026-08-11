import XCTest
@testable import aibarsCore

/// `Cookies.binarycookies` is an untrusted file that Safari rewrites underneath
/// us while the app is running, so the parser can be handed a truncated or
/// half-written jar at any moment. Every count and offset it reads comes out of
/// the file, and a menu bar app cannot trap on a bad one.
///
/// The fixtures below are built in the real format, which mixes endianness: the
/// file header's page count and page-size table are big-endian, everything
/// inside a page is little-endian. A reader that gets that wrong parses no real
/// Safari jar at all, so the round-trip case is what pins it down.
final class SafariBinaryCookiesTests: XCTestCase {
    func testParsesACookieAndKeepsOnlyTheMatchingDomain() {
        let expiry: Double = 700_000_000
        let jar = jar([page([
            record(url: ".claude.ai", name: "sessionKey", path: "/", value: "abc123", expiry: expiry),
            record(url: ".example.com", name: "other", path: "/", value: "zzz", expiry: expiry)
        ])])

        let cookies = parse(jar)

        XCTAssertEqual(cookies.count, 1, "example.com is not the requested domain")
        XCTAssertEqual(cookies.first?.name, "sessionKey")
        XCTAssertEqual(cookies.first?.value, "abc123")
        XCTAssertEqual(cookies.first?.domain, ".claude.ai")
        XCTAssertEqual(cookies.first?.path, "/")
        XCTAssertEqual(cookies.first?.expiresAt, Date(timeIntervalSinceReferenceDate: expiry))
        XCTAssertEqual(cookies.first?.source, .safari)
    }

    func testEmptyFileYieldsNoCookies() {
        XCTAssertEqual(parse(Data()).count, 0)
    }

    func testFileShorterThanTheHeaderYieldsNoCookies() {
        // The magic on its own, as a jar caught mid-write would be.
        XCTAssertEqual(parse(Data("cook".utf8)).count, 0)
    }

    func testWrongMagicYieldsNoCookies() {
        // The cookies directory is also where unrelated files turn up.
        XCTAssertEqual(parse(Data("SQLite format 3\u{0}".utf8)).count, 0)
    }

    func testZeroPagesYieldsNoCookies() {
        XCTAssertEqual(parse(jar([])).count, 0)
    }

    func testPageSizePastTheEndOfTheFileYieldsNoCookies() {
        // The size table survived the truncation; the page it describes did not.
        let truncated = Data("cook".utf8) + uint32BE(1) + uint32BE(4096)
        XCTAssertEqual(parse(truncated).count, 0)
    }

    func testZeroLengthPageYieldsNoCookies() {
        XCTAssertEqual(parse(Data("cook".utf8) + uint32BE(1) + uint32BE(0)).count, 0)
    }

    func testCookieOffsetPastTheEndOfThePageYieldsNoCookies() {
        var page = Data([0x00, 0x00, 0x01, 0x00])
        page += uint32LE(1)
        page += uint32LE(9_999) // the record this points at is not in the page
        page += Data(repeating: 0, count: 8)
        XCTAssertEqual(parse(jar([page])).count, 0)
    }

    func testStringOffsetsPastTheEndOfTheRecordYieldNoCookies() {
        var record = uint32LE(44)
        record += Data(repeating: 0, count: 12)
        for _ in 0..<4 { record += uint32LE(9_999) } // url, name, path and value
        record += Data(repeating: 0, count: 4)
        record += doubleLE(0)
        XCTAssertEqual(parse(jar([page([record])])).count, 0)
    }

    // MARK: - Helpers

    private func parse(_ data: Data) -> [BrowserCookie] {
        SafariBinaryCookies.parse(data, matching: "claude.ai", source: .safari)
    }

    /// A cookie record: a 44-byte header whose offsets are relative to the
    /// record itself, then the NUL-terminated strings they point at.
    private func record(url: String, name: String, path: String, value: String, expiry: Double) -> Data {
        let strings = [url, name, path, value].map { Data($0.utf8) + Data([0]) }
        var offsets: [UInt32] = []
        var cursor = 44
        for string in strings {
            offsets.append(UInt32(cursor))
            cursor += string.count
        }
        var record = uint32LE(UInt32(cursor)) // record size
        record += Data(repeating: 0, count: 12) // unknown, flags, unknown
        for offset in offsets { record += uint32LE(offset) }
        record += Data(repeating: 0, count: 4) // end of cookie
        record += doubleLE(expiry)
        for string in strings { record += string }
        return record
    }

    /// A page: the fixed page header, a little-endian cookie count and offset
    /// table, a footer, then the records.
    private func page(_ records: [Data]) -> Data {
        var offsets: [UInt32] = []
        var cursor = 8 + records.count * 4 + 4
        for record in records {
            offsets.append(UInt32(cursor))
            cursor += record.count
        }
        var page = Data([0x00, 0x00, 0x01, 0x00])
        page += uint32LE(UInt32(records.count))
        for offset in offsets { page += uint32LE(offset) }
        page += Data(repeating: 0, count: 4)
        for record in records { page += record }
        return page
    }

    /// The file header, and the only big-endian part of the format.
    private func jar(_ pages: [Data]) -> Data {
        var jar = Data("cook".utf8)
        jar += uint32BE(UInt32(pages.count))
        for page in pages { jar += uint32BE(UInt32(page.count)) }
        for page in pages { jar += page }
        return jar
    }

    private func uint32BE(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    private func uint32LE(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    private func doubleLE(_ value: Double) -> Data {
        withUnsafeBytes(of: value.bitPattern.littleEndian) { Data($0) }
    }
}
