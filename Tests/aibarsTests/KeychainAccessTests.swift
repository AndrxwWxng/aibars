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
