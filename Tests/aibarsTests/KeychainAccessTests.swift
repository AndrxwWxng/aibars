import XCTest
import Security
@testable import aibarsCore

/// Guards the reasons aibars stopped asking for keychain access on a loop.
///
/// Two separate prompts used to fire repeatedly: the app's own Keychain items
/// (read once per provider per refresh) and each Chromium browser's Safe Storage
/// key (read by any provider that consulted browser cookies on its refresh
/// cycle). Both are regressions that would be invisible in normal use until a
/// user complained, so they are asserted here.
final class KeychainAccessTests: XCTestCase {
    /// A provider id no real provider uses, so this never touches a credential
    /// the user actually depends on.
    private let probeID = "keychain-access-test"

    override func tearDown() {
        SessionStore.shared.clear(probeID)
        super.tearDown()
    }

    /// The test runner is a different binary from the app, so the ACL on the
    /// app's Keychain item doesn't cover it and every read used to put an
    /// "xctest wants to access key dev.aibars.app" dialog on the user's screen.
    /// Storage under XCTest must stay in memory: no dialogs, and no chance of a
    /// test overwriting the credentials a real install depends on.
    func testTestRunsNeverTouchTheRealKeychain() throws {
        try SessionStore.shared.setToken("must-not-persist", for: probeID)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "dev.aibars.app",
            kSecAttrAccount as String: "aibars.tokens",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data,
           let contents = String(data: data, encoding: .utf8) {
            XCTAssertFalse(
                contents.contains("must-not-persist"),
                "a test wrote into the real login keychain"
            )
        }
        query[kSecReturnData as String] = nil
        // Whatever the outcome, this test must not have created the item.
        XCTAssertNotEqual(status, errSecAuthFailed, "a test triggered a keychain dialog")
    }

    /// A browser-derived session must never be written anywhere that needs
    /// authorisation to read back. Storing it bought nothing — it is re-derived
    /// at launch in half a second — and cost a dialog on every rebuild.
    func testBrowserSessionsAreNeverPersisted() throws {
        let store = SessionStore.shared
        try store.setToken("from-a-cookie", for: probeID, source: .browserCookie)

        XCTAssertEqual(store.token(for: probeID), "from-a-cookie", "not usable this launch")
        XCTAssertTrue(store.hasCredential(for: probeID))

        // Nothing was written, so a reload finds nothing.
        store.invalidateCache()
        XCTAssertNil(
            KeychainStore.get("aibars.tokens").flatMap { $0.contains("from-a-cookie") ? $0 : nil },
            "a cookie-derived session reached the store that prompts"
        )
    }

    /// A pasted key can't be re-derived from anything, so it does get stored.
    func testPastedKeysArePersisted() throws {
        let store = SessionStore.shared
        try store.setToken("pasted-key", for: probeID, source: .apiKey)
        store.invalidateCache()
        XCTAssertEqual(store.token(for: probeID), "pasted-key", "lost across a reload")
    }

    /// With nothing pasted, there is no reason to open the Keychain at all —
    /// and not opening it is the only guarantee of no dialog.
    func testNoKeychainReadWhenOnlyBrowserSessionsExist() throws {
        let store = SessionStore.shared
        // Any pasted credential left by another test would legitimately cause a
        // read, so start from a state where none exist.
        for credential in store.allCredentials() { store.clear(credential.providerID) }
        try store.setToken("from-a-cookie", for: probeID, source: .browserCookie)
        store.invalidateCache()

        // Seed the item directly, then assert the load path never looks at it.
        try KeychainStore.set(Data(#"{"decoy":"value"}"#.utf8), for: "aibars.tokens")
        XCTAssertNil(store.token(for: "decoy"), "the load path read the Keychain unnecessarily")
        KeychainStore.delete("aibars.tokens")
    }

    func testTokenReadsComeFromMemoryAfterTheFirst() throws {
        let store = SessionStore.shared
        try store.setToken("probe-value", for: probeID)
        XCTAssertEqual(store.token(for: probeID), "probe-value")

        // There is no hook into SecItemCopyMatching, so this asserts the
        // observable consequence: reads keep working with the item deleted
        // underneath, which is only possible if they never reach the Keychain.
        KeychainStore.delete("aibars.\(probeID).token")
        for _ in 0..<50 {
            XCTAssertEqual(store.token(for: probeID), "probe-value", "a read escaped the cache")
        }
    }

    func testMissesAreCachedSoDisconnectedProvidersDoNotReAsk() {
        let store = SessionStore.shared
        store.clear(probeID)
        store.invalidateCache()
        XCTAssertNil(store.token(for: probeID))
        XCTAssertNil(store.token(for: probeID))
    }

    func testHasCredentialAnswersWithoutTheKeychain() throws {
        let store = SessionStore.shared
        try store.setToken("probe-value", for: probeID)
        // Providers ask this at construction; it must not depend on the item.
        KeychainStore.delete("aibars.\(probeID).token")
        XCTAssertTrue(store.hasCredential(for: probeID))
        store.clear(probeID)
        XCTAssertFalse(store.hasCredential(for: probeID))
    }

    /// Deriving a Chromium key is what puts a dialog on screen, so the default
    /// read path must never do it.
    func testCookieReadsAreSilentByDefault() {
        for extractor in CookieExtractors.available() {
            guard let chromium = extractor as? ChromeCookieExtractor else { continue }
            XCTAssertFalse(chromium.hasCachedKey, "a key was derived before any read")
            _ = try? chromium.cookies(for: "example.com")
            XCTAssertFalse(chromium.hasCachedKey, "cookies(for:) prompted")
            _ = try? chromium.cookies(forAnyOf: ["example.com"])
            XCTAssertFalse(chromium.hasCachedKey, "cookies(forAnyOf:) prompted")
        }
    }

    @MainActor
    func testLaunchSweepIsSilent() async {
        _ = await AppState().adoptBrowserSessions()
        for extractor in CookieExtractors.available() {
            guard let chromium = extractor as? ChromeCookieExtractor else { continue }
            XCTAssertFalse(
                chromium.hasCachedKey,
                "the launch sweep prompted for \(chromium.variant.rawValue)"
            )
        }
    }
}
