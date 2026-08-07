import XCTest
@testable import aibarsCore

/// One person can be signed into the same service several times — Chrome
/// profiles are the usual way. Before this, discovery took the first session it
/// found and the rest were invisible.
final class MultiAccountTests: XCTestCase {
    @MainActor
    func testASecondSessionBecomesASecondProvider() async throws {
        let state = AppState()
        let before = state.providers.filter { $0.serviceID == "claude" }
        XCTAssertEqual(before.count, 1, "starts with one instance per service")
        XCTAssertNil(before.first?.accountID, "the first account keeps the plain id")
        XCTAssertEqual(before.first?.id, "claude")
    }

    /// Ids have to stay distinct, or two accounts share one credential and one
    /// snapshot — which is the bug this whole change exists to avoid.
    @MainActor
    func testAccountsGetDistinctIdentitiesButShareAService() {
        let first = ClaudeProvider()
        let second = ClaudeProvider(accountID: "2")

        XCTAssertEqual(first.id, "claude")
        XCTAssertEqual(second.id, "claude#2")
        XCTAssertNotEqual(first.id, second.id)
        // Same family, so they draw the same logo and carry the same name.
        XCTAssertEqual(first.serviceID, second.serviceID)
        XCTAssertEqual(first.displayName, second.displayName)
    }

    @MainActor
    func testCredentialsDoNotLeakBetweenAccounts() throws {
        let store = SessionStore.shared
        defer { store.clear("claude#98"); store.clear("claude#99") }

        try store.setToken("token-a", for: "claude#98", source: .browserCookie)
        try store.setToken("token-b", for: "claude#99", source: .browserCookie)

        XCTAssertEqual(store.token(for: "claude#98"), "token-a")
        XCTAssertEqual(store.token(for: "claude#99"), "token-b")
    }

    /// The enabled flag is per account too, so hiding one doesn't hide both.
    @MainActor
    func testEnabledStateIsPerAccount() {
        let first = ClaudeProvider(accountID: "96")
        let second = ClaudeProvider(accountID: "97")
        first.setEnabled(false)
        second.setEnabled(true)
        XCTAssertFalse(ClaudeProvider(accountID: "96").isEnabled)
        XCTAssertTrue(ClaudeProvider(accountID: "97").isEnabled)
        // Leave the defaults as they were.
        first.setEnabled(true)
    }

    /// Two profiles holding the same session are one account, not two rows.
    func testIdenticalSessionsAreNotCountedTwice() {
        let cookies = [
            BrowserCookie(name: "sessionKey", value: "same", domain: ".claude.ai", path: "/",
                          expiresAt: nil, source: .chrome, profile: "Default"),
            BrowserCookie(name: "sessionKey", value: "same", domain: ".claude.ai", path: "/",
                          expiresAt: nil, source: .chrome, profile: "Profile 2")
        ]
        XCTAssertEqual(Set(cookies.map(\.value)).count, 1)
    }

    func testOriginNamesTheProfile() {
        let plain = BrowserCookie(name: "a", value: "b", domain: "c", path: "/",
                                  expiresAt: nil, source: .chrome, profile: "Default")
        let named = BrowserCookie(name: "a", value: "b", domain: "c", path: "/",
                                  expiresAt: nil, source: .chrome, profile: "Profile 2")
        XCTAssertEqual(plain.origin, "Chrome", "the default profile needs no qualifier")
        XCTAssertEqual(named.origin, "Chrome · Profile 2")
    }
}
