import Foundation

/// Reads cookies from Safari's binary cookies file.
///
/// The binary format is documented and unencrypted, but Safari only
/// allows access if the user has granted Full Disk Access to the
/// reading app. We surface a clear error in that case.
public final class SafariCookieExtractor: CookieExtractor {
    public let browser: BrowserCookie.Browser = .safari

    private let cookiesURL: URL

    public init?() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let url = home.appendingPathComponent("Library/Cookies/Cookies.binarycookies")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        self.cookiesURL = url
    }

    public var isAvailable: Bool {
        FileManager.default.isReadableFile(atPath: cookiesURL.path)
    }

    public func cookies(for domain: String) throws -> [BrowserCookie] {
        guard let data = try? Data(contentsOf: cookiesURL) else {
            throw ProviderError.configuration("Cannot read Safari cookies. Grant Full Disk Access in System Settings → Privacy & Security.")
        }
        return SafariBinaryCookies.parse(data, matching: domain, source: .safari)
    }
}

/// Parses Safari's Cookies.binarycookies format.
///
/// Reference: https://github.com/nickchenct123/Safari-Cookie-Extractor
enum public SafariBinaryCookies {
    static func parse(_ data: Data, matching domain: String, source: BrowserCookie.Browser) -> [BrowserCookie] {
        guard data.count > 8 else { return [] }
        let magic = data.subdata(in: 0..<4)
        guard String(data: magic, encoding: .ascii) == "cook" else { return [] }

        let numPages = readUInt32(data, at: 4)
        var pageSizes: [Int] = []
        for i in 0..<Int(numPages) {
            pageSizes.append(readInt32(data, at: 8 + i * 4))
        }

        var cookies: [BrowserCookie] = []
        var offset = 8 + Int(numPages) * 4
        for size in pageSizes {
            let pageData = data.subdata(in: offset..<(offset + size))
            cookies.append(contentsOf: parsePage(pageData, matching: domain, source: source))
            offset += size
        }
        return cookies
    }

    private static func parsePage(_ data: Data, matching domain: String, source: BrowserCookie.Browser) -> [BrowserCookie] {
        guard data.count > 4 else { return [] }
        // Page header: 4-byte page header, 0x00000100
        let numCookies = readUInt32(data, at: 4)
        var cookieOffsets: [Int] = []
        for i in 0..<Int(numCookies) {
            cookieOffsets.append(readInt32(data, at: 8 + i * 4))
        }
        var result: [BrowserCookie] = []
        for off in cookieOffsets {
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

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        data.withUnsafeBytes { raw in
            let ptr = raw.baseAddress!.advanced(by: offset)
            return ptr.load(as: UInt32.self).littleEndian
        }
    }

    private static func readInt32(_ data: Data, at offset: Int) -> Int {
        Int(readUInt32(data, at: offset))
    }

    private static func readDouble(_ data: Data, at offset: Int) -> Double {
        data.withUnsafeBytes { raw in
            let ptr = raw.baseAddress!.advanced(by: offset)
            return Double(bitPattern: UInt64(ptr.load(as: UInt64.self).littleEndian))
        }
    }

    private static func readString(_ data: Data, at offset: Int) -> String {
        var end = offset
        while end < data.count && data[end] != 0 { end += 1 }
        return String(data: data.subdata(in: offset..<end), encoding: .utf8) ?? ""
    }
}
