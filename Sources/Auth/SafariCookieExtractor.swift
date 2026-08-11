import Foundation

/// Reads cookies from Safari's binary cookies file.
///
/// The binary format is documented and unencrypted, but Safari only
/// allows access if the user has granted Full Disk Access to the
/// reading app. We surface a clear error in that case.
public final class SafariCookieExtractor: CookieExtractor {
    public let browser: BrowserCookie.Browser = .safari

    private let cookieJars: [URL]

    /// Both places Safari's jar has lived, in the order worth trusting. Safari
    /// keeps its cookies in its sandbox container now; the home-Library path is
    /// CFNetwork's shared jar for non-sandboxed processes, which still exists on
    /// a modern Mac while holding nothing of Safari's — so it is the fallback for
    /// older systems, never the first pick.
    private static let jarPaths = [
        "Library/Containers/com.apple.Safari/Data/Library/Cookies/Cookies.binarycookies",
        "Library/Cookies/Cookies.binarycookies"
    ]

    public init?() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let jars = Self.jarPaths
            .map { home.appendingPathComponent($0) }
            .filter { Self.canOpen($0) }
        guard !jars.isEmpty else { return nil }
        self.cookieJars = jars
    }

    public var isAvailable: Bool {
        cookieJars.contains { Self.canOpen($0) }
    }

    public func cookies(for domain: String) throws -> [BrowserCookie] {
        var found: [BrowserCookie] = []
        var opened = false
        // Every jar that opens, not the first that exists: the legacy path is
        // usually present and usually empty, so picking one loses the sessions.
        for jar in cookieJars {
            guard let data = try? Data(contentsOf: jar) else { continue }
            opened = true
            found.append(contentsOf: SafariBinaryCookies.parse(data, matching: domain, source: .safari))
        }
        guard opened else {
            throw ProviderError.configuration("Cannot read Safari cookies. Grant Full Disk Access in System Settings → Privacy & Security.")
        }
        return found
    }

    /// `fileExists` and `isReadableFile` both answer from the file's metadata,
    /// and TCC does not deny that — it denies the `open`. Opening is the only
    /// honest test for whether we can read a jar.
    private static func canOpen(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        try? handle.close()
        return true
    }
}

/// Parses Safari's Cookies.binarycookies format.
///
/// Every offset and count below is read out of the file itself, so all of them
/// are bounds-checked before use: a truncated or half-written jar must come back
/// empty, not take the menu bar down with a range trap.
///
/// Reference: https://github.com/nickchenct123/Safari-Cookie-Extractor
public enum SafariBinaryCookies {
    public static func parse(_ data: Data, matching domain: String, source: BrowserCookie.Browser) -> [BrowserCookie] {
        guard data.count > 8 else { return [] }
        let magic = data.subdata(in: 0..<4)
        guard String(data: magic, encoding: .ascii) == "cook" else { return [] }

        let numPages = Int(readUInt32BE(data, at: 4))
        guard 8 + numPages * 4 <= data.count else { return [] }
        var pageSizes: [Int] = []
        for i in 0..<numPages {
            pageSizes.append(Int(readUInt32BE(data, at: 8 + i * 4)))
        }

        var cookies: [BrowserCookie] = []
        var offset = 8 + numPages * 4
        for size in pageSizes {
            guard size > 0, offset + size <= data.count else { break }
            let pageData = data.subdata(in: offset..<(offset + size))
            cookies.append(contentsOf: parsePage(pageData, matching: domain, source: source))
            offset += size
        }
        return cookies
    }

    private static func parsePage(_ data: Data, matching domain: String, source: BrowserCookie.Browser) -> [BrowserCookie] {
        guard data.count > 4 else { return [] }
        // Page header: 4-byte page header, 0x00000100
        let numCookies = Int(readUInt32(data, at: 4))
        guard 8 + numCookies * 4 <= data.count else { return [] }
        var cookieOffsets: [Int] = []
        for i in 0..<numCookies {
            cookieOffsets.append(readInt32(data, at: 8 + i * 4))
        }
        var result: [BrowserCookie] = []
        for off in cookieOffsets {
            // An offset past the end would make an inverted range, which traps
            // separately from a plain out-of-bounds one.
            guard off <= data.count else { continue }
            if let cookie = parseCookie(data.subdata(in: off..<data.count), matching: domain, source: source) {
                result.append(cookie)
            }
        }
        return result
    }

    private static func parseCookie(_ data: Data, matching domain: String, source: BrowserCookie.Browser) -> BrowserCookie? {
        // cookie: 4 size, 4 unknown, 4 flags, 4 unknown, 4 urlOffset, 4 nameOffset, 4 pathOffset, 4 valueOffset, 8 endOfCookie, 8 expiry
        guard data.count >= 44 else { return nil }
        let urlOffset = readInt32(data, at: 16)
        let nameOffset = readInt32(data, at: 20)
        let pathOffset = readInt32(data, at: 24)
        let valueOffset = readInt32(data, at: 28)
        let expiry = readDouble(data, at: 36)

        let url = readString(data, at: urlOffset)
        let name = readString(data, at: nameOffset)
        let path = readString(data, at: pathOffset)
        let value = readString(data, at: valueOffset)

        // Filter by domain
        let cookieDomain = URL(string: url)?.host ?? url
        if !cookieDomain.contains(domain.replacingOccurrences(of: "https://", with: "")
                                          .replacingOccurrences(of: "http://", with: "")) {
            return nil
        }

        // Mac epoch is 2001-01-01; expiry 0 means session
        let expiresAt: Date? = expiry > 0
            ? Date(timeIntervalSinceReferenceDate: expiry)
            : nil

        return BrowserCookie(
            name: name,
            value: value,
            domain: cookieDomain,
            path: path,
            expiresAt: expiresAt,
            source: source
        )
    }

    // MARK: - Binary helpers
    //
    // `loadUnaligned` rather than `baseAddress!.advanced(by:).load(as:)`: the
    // expiry double sits at offset 36, which is not 8-byte aligned, and the
    // force-unwrap traps on empty `Data`.

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).littleEndian }
    }

    /// The file header's page count and page-size table are big-endian. Only the
    /// fields inside a page — cookie count, cookie offsets, expiry — are little.
    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self).bigEndian }
    }

    private static func readInt32(_ data: Data, at offset: Int) -> Int {
        Int(readUInt32(data, at: offset))
    }

    private static func readDouble(_ data: Data, at offset: Int) -> Double {
        guard offset >= 0, offset + 8 <= data.count else { return 0 }
        return data.withUnsafeBytes {
            Double(bitPattern: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self).littleEndian)
        }
    }

    private static func readString(_ data: Data, at offset: Int) -> String {
        guard offset >= 0, offset <= data.count else { return "" }
        var end = offset
        while end < data.count && data[end] != 0 { end += 1 }
        return String(data: data.subdata(in: offset..<end), encoding: .utf8) ?? ""
    }
}
