import Foundation
import AppKit

/// Describes how a provider is signed into.
///
/// The point of this type is to replace "open DevTools, find a cookie, copy the
/// value, paste it here" with "click Sign in, log in normally". aibars sends the
/// user to the provider's login page in their own default browser, then reads
/// the resulting session straight out of that browser's cookie store.
public struct WebLoginConfig {
    /// How the credential is picked up once the user has logged in.
    public enum Capture {
        /// Watch the browser's cookie store for `name` on `domainSuffix`.
        case cookie(name: String, domainSuffix: String)
        /// The page shows a token the user copies (GitHub PAT flow). We still
        /// open the page so it's one click to get there.
        case tokenShownOnPage
    }

    public let startURL: URL
    public let capture: Capture
    /// Shown while the user works through the flow.
    public let hint: String
    /// Domains this provider's session lives on. First entry is the one the
    /// cookie search targets.
    public let dataDomains: [String]
    /// Other names the session cookie may go by. Services that have migrated
    /// their auth library write a different name depending on when the account
    /// last signed in, and the old ones stay valid.
    public let alternateCookieNames: [String]

    public init(
        startURL: URL,
        capture: Capture,
        hint: String,
        dataDomains: [String] = [],
        alternateCookieNames: [String] = []
    ) {
        self.startURL = startURL
        self.capture = capture
        self.hint = hint
        self.dataDomains = dataDomains
        self.alternateCookieNames = alternateCookieNames
    }

    public var expectedCookieName: String? {
        if case .cookie(let name, _) = capture { return name }
        return nil
    }

    /// Every name worth looking for, preferred first.
    public var candidateCookieNames: [String] {
        guard let primary = expectedCookieName else { return [] }
        return [primary] + alternateCookieNames.filter { $0 != primary }
    }

    public var cookieDomain: String? {
        if case .cookie(_, let domain) = capture { return domain }
        return nil
    }
}

/// The browser macOS will hand an https:// link to, and whether aibars can read
/// its cookies afterwards.
public struct DefaultBrowser {
    public let bundleIdentifier: String
    public let name: String
    /// Which extractor covers it, if any.
    public let kind: BrowserCookie.Browser?
    /// Why the session can't be read automatically, when it can't be.
    public let limitation: Limitation?

    public enum Limitation: Equatable {
        /// Safari's cookie jar lives inside a TCC-protected container.
        case needsFullDiskAccess
        /// A browser with no extractor at all.
        case unsupported

        public var explanation: String {
            switch self {
            case .needsFullDiskAccess:
                return "Safari keeps its cookies in a protected folder. Grant aibars Full Disk Access to read the session automatically, or paste a token below."
            case .unsupported:
                return "aibars can't read this browser's cookies. Log in, then paste a token below."
            }
        }
    }

    public static func current() -> DefaultBrowser {
        let probe = URL(string: "https://example.com")!
        guard let appURL = NSWorkspace.shared.urlForApplication(toOpen: probe),
              let bundle = Bundle(url: appURL),
              let identifier = bundle.bundleIdentifier?.lowercased()
        else {
            return DefaultBrowser(bundleIdentifier: "", name: "your browser", kind: nil, limitation: .unsupported)
        }
        let name = FileManager.default.displayName(atPath: appURL.path)
            .replacingOccurrences(of: ".app", with: "")

        if identifier == "com.apple.safari" || identifier == "com.apple.safaritechnologypreview" {
            return DefaultBrowser(bundleIdentifier: identifier, name: name, kind: .safari, limitation: .needsFullDiskAccess)
        }
        if identifier.hasPrefix("org.mozilla") {
            return DefaultBrowser(bundleIdentifier: identifier, name: name, kind: .firefox, limitation: nil)
        }
        for variant in ChromeBasedBrowser.allCases where variant.bundleIdentifiers.contains(identifier) {
            return DefaultBrowser(bundleIdentifier: identifier, name: name, kind: variant.browserEnum, limitation: nil)
        }
        return DefaultBrowser(bundleIdentifier: identifier, name: name, kind: nil, limitation: .unsupported)
    }

    private init(bundleIdentifier: String, name: String, kind: BrowserCookie.Browser?, limitation: Limitation?) {
        self.bundleIdentifier = bundleIdentifier
        self.name = name
        self.kind = kind
        self.limitation = limitation
    }

    /// Whether a session could plausibly be picked up without the user pasting.
    public var supportsAutomaticCapture: Bool { limitation == nil }
}

public enum WebLoginEnvironment {
    /// Hands the login URL to the user's default browser.
    @MainActor
    public static func openLoginPage(for config: WebLoginConfig) {
        NSWorkspace.shared.open(config.startURL)
    }

    /// One attempt at finding the provider's session in the installed
    /// browsers, preferring the default one. Runs the SQLite and keychain work
    /// off the main thread.
    /// `allowingKeychainPrompt` is true when this runs from the login window:
    /// the user just asked to sign in, so a one-off prompt for the browser's
    /// cookie key is expected rather than mysterious. The Chromium extractor
    /// caches the outcome, so a refusal is not re-asked.
    public static func capturedCookie(
        for config: WebLoginConfig,
        preferring browser: BrowserCookie.Browser? = nil,
        allowingKeychainPrompt: Bool = false
    ) async -> BrowserCookie? {
        guard case .cookie(_, let domain) = config.capture else { return nil }
        let names = config.candidateCookieNames
        return await Task.detached(priority: .utility) {
            CookieExtractors.firstAvailableCookie(
                named: names,
                for: domain,
                preferring: browser,
                allowingKeychainPrompt: allowingKeychainPrompt
            )
        }.value
    }

    /// Opens the Full Disk Access pane, for the Safari case.
    @MainActor
    public static func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }
}
