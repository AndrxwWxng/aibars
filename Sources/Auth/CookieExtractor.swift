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

    /// Try each available extractor, returning the first cookie that actually
    /// has a value. `preferred` is checked first — during a login flow that's
    /// the browser the user just logged in with, so it avoids prompting for
    /// another browser's keychain key unnecessarily.
    public static func firstAvailableCookie(
        named name: String,
        for domain: String,
        preferring preferred: BrowserCookie.Browser? = nil
    ) -> BrowserCookie? {
        firstAvailableCookie(named: [name], for: domain, preferring: preferred)
    }

    /// As above, for services that write one of several cookie names depending
    /// on when the account last signed in. Each browser is read once and all
    /// candidates checked against that snapshot — reading per name would risk
    /// a keychain prompt per name.
    public static func firstAvailableCookie(
        named names: [String],
        for domain: String,
        preferring preferred: BrowserCookie.Browser? = nil
    ) -> BrowserCookie? {
        let extractors = available().sorted { lhs, rhs in
            (lhs.browser == preferred ? 0 : 1) < (rhs.browser == preferred ? 0 : 1)
        }
        for extractor in extractors {
            guard let cookies = try? extractor.cookies(for: domain) else { continue }
            for name in names {
                // An empty value means the row was found but not decryptable,
                // which is not a usable session — keep looking.
                if let match = cookies.first(where: { $0.name == name && !$0.value.isEmpty }) {
                    return match
                }
            }
        }
        return nil
    }
}
