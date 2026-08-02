import Foundation

/// A cookie extracted from a browser, ready to be applied to a URLRequest.
public struct BrowserCookie: Hashable {
    public let name: String
    public let value: String
    public let domain: String
    public let path: String
    public let expiresAt: Date?
    public let source: Browser

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
}

public enum CookieExtractors {
    /// Returns all available extractors on the current system.
    public static func available() -> [CookieExtractor] {
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
        return result
    }

    /// Try each available extractor in order, return the first non-empty
    /// match for the given domain.
    public static func firstAvailableCookie(named name: String, for domain: String) -> BrowserCookie? {
        for extractor in available() {
            if let cookies = try? extractor.cookies(for: domain),
               let match = cookies.first(where: { $0.name == name }) {
                return match
            }
        }
        return nil
    }
}
