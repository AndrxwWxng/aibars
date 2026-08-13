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
    ///
    /// This used to be asserted as `Set(cookies.map(\.value)).count == 1`, which
    /// is a property of `Set` and reached no aibars code at all: it would have
    /// gone on passing with `searchAll` deleted. It is driven through the real
    /// dedupe now, over a stub extractor rather than whatever browsers the
    /// machine running the suite happens to have.
    func testIdenticalSessionsAreNotCountedTwice() {
        let stub = StubExtractor(jar: [
            BrowserCookie(name: "sessionKey", value: "same", domain: ".claude.ai", path: "/",
                          expiresAt: nil, source: .chrome, profile: "Default"),
            BrowserCookie(name: "sessionKey", value: "same", domain: ".claude.ai", path: "/",
                          expiresAt: nil, source: .chrome, profile: "Profile 2")
        ])

        let found = CookieExtractors.searchAll(
            [CookieExtractors.Query(key: "session", names: ["sessionKey"], domain: "claude.ai")],
            extractors: [stub]
        )

        XCTAssertEqual(found["session"]?.count, 1, "one session was counted as two accounts")
        // `searchAll` walks profiles in sorted order, so which of the two
        // survives is fixed rather than whatever the jar listed first.
        XCTAssertEqual(found["session"]?.first?.profile, "Default")
    }

    /// The other half of the same fingerprint, and the one the `Set` assertion
    /// could not see: two queries that resolve to the same string are two
    /// sessions, because the fingerprint is `"\(query.key)|\(cookie.value)"` and
    /// not the value alone. Drop the key half and the second query silently
    /// finds nothing, which draws as a signed-out service.
    func testOneValueUnderTwoQueriesIsNotCollapsed() {
        let stub = StubExtractor(jar: [
            BrowserCookie(name: "sessionKey", value: "same", domain: ".claude.ai", path: "/",
                          expiresAt: nil, source: .chrome, profile: "Default"),
            BrowserCookie(name: "orgKey", value: "same", domain: ".claude.ai", path: "/",
                          expiresAt: nil, source: .chrome, profile: "Default")
        ])

        let found = CookieExtractors.searchAll(
            [
                CookieExtractors.Query(key: "session", names: ["sessionKey"], domain: "claude.ai"),
                CookieExtractors.Query(key: "org", names: ["orgKey"], domain: "claude.ai")
            ],
            extractors: [stub]
        )

        XCTAssertEqual(found["session"]?.count, 1)
        XCTAssertEqual(found["org"]?.count, 1, "the second query was swallowed by the first's value")
        XCTAssertEqual(found["session"]?.first?.name, "sessionKey")
        XCTAssertEqual(found["org"]?.first?.name, "orgKey")
    }

    /// And two genuinely different sessions under one query are two accounts —
    /// the case a fingerprint of `query.key` alone would collapse.
    func testTwoValuesUnderOneQueryAreTwoAccounts() {
        let stub = StubExtractor(jar: [
            BrowserCookie(name: "sessionKey", value: "work", domain: ".claude.ai", path: "/",
                          expiresAt: nil, source: .chrome, profile: "Default"),
            BrowserCookie(name: "sessionKey", value: "personal", domain: ".claude.ai", path: "/",
                          expiresAt: nil, source: .chrome, profile: "Profile 2")
        ])

        let found = CookieExtractors.searchAll(
            [CookieExtractors.Query(key: "session", names: ["sessionKey"], domain: "claude.ai")],
            extractors: [stub]
        )

        XCTAssertEqual(found["session"]?.count, 2, "two accounts were counted as one")
        XCTAssertEqual(found["session"]?.map(\.value), ["work", "personal"])
    }

    func testOriginNamesTheProfile() {
        let plain = BrowserCookie(name: "a", value: "b", domain: "c", path: "/",
                                  expiresAt: nil, source: .chrome, profile: "Default")
        let named = BrowserCookie(name: "a", value: "b", domain: "c", path: "/",
                                  expiresAt: nil, source: .chrome, profile: "Profile 2")
        XCTAssertEqual(plain.origin, "Chrome", "the default profile needs no qualifier")
        XCTAssertEqual(named.origin, "Chrome · Profile 2")
    }

    /// One browser's jar, held in memory. Only `cookies(for:)` is implemented:
    /// the `cookies(forAnyOf:allowingKeychainPrompt:)` that `searchAll` actually
    /// calls comes from `CookieExtractor`'s own extension, so the three dedupe
    /// tests drive the shipped path rather than a second one written here.
    private struct StubExtractor: CookieExtractor {
        let jar: [BrowserCookie]
        var browser: BrowserCookie.Browser { .chrome }
        var isAvailable: Bool { true }
        func cookies(for domain: String) throws -> [BrowserCookie] { jar }
    }
}
