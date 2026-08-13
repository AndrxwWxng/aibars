import XCTest
@testable import aibarsCore

/// Signing out has to survive the thing that undid it.
///
/// Gemini fell through to "any Google session in any browser" whenever it had no
/// token, and stored it — so a sign-out lasted until the next refresh a few
/// seconds later. The launch sweep would have re-adopted it regardless.
final class SignOutTests: XCTestCase {
    override func tearDown() {
        AppState.clearSignedOut("gemini")
        SessionStore.shared.clear("gemini")
        super.tearDown()
    }

    @MainActor
    func testSignOutIsRememberedAcrossASweep() async throws {
        let state = AppState()
        let gemini = try XCTUnwrap(state.provider(for: "gemini"))

        try gemini.adoptBrowserSession("a-session-value")
        XCTAssertEqual(SessionStore.shared.token(for: "gemini"), "a-session-value")

        try await gemini.signOut()
        XCTAssertNil(SessionStore.shared.token(for: "gemini"), "the credential should be gone")
        XCTAssertTrue(AppState.signedOutProviders.contains("gemini"), "the choice should be recorded")

        // The sweep is what used to bring it straight back.
        _ = await state.adoptBrowserSessions()
        XCTAssertNil(
            SessionStore.shared.token(for: "gemini"),
            "the sweep re-adopted a session the user had signed out of"
        )
    }

    /// Signing back in is the user changing their mind, so the mark must go —
    /// otherwise they can never reconnect.
    @MainActor
    func testSigningInAgainClearsTheMark() async throws {
        let state = AppState()
        let gemini = try XCTUnwrap(state.provider(for: "gemini"))

        try await gemini.signOut()
        XCTAssertTrue(AppState.signedOutProviders.contains("gemini"))

        try gemini.saveToken("a-new-session", source: .browserCookie)
        XCTAssertFalse(AppState.signedOutProviders.contains("gemini"))
        XCTAssertEqual(SessionStore.shared.token(for: "gemini"), "a-new-session")
    }

    /// A row the user disconnected has to go back to its short form.
    ///
    /// The reading is what decides that, not the auth flag: `ProviderRow`
    /// reserves its detail box for a row that is authenticated *or* holds a
    /// result, so a snapshot outliving the credential leaves a disconnected row
    /// at full height with the last sentence it managed to say still in it —
    /// and a "Sign in" button under a figure from the session that just ended.
    @MainActor
    func testSigningOutDropsTheReadingTheRowWasDrawnFrom() async throws {
        let state = AppState()
        let gemini = try XCTUnwrap(state.provider(for: "gemini"))

        try gemini.adoptBrowserSession("a-session-value")
        state.snapshots["gemini"] = .success(UsageData(
            providerID: "gemini",
            primary: UsageMetric(label: "Daily", used: 40, limit: 100)
        ))

        try await gemini.signOut()

        XCTAssertNil(
            state.snapshots["gemini"],
            "the row kept a reading from the session the user just ended"
        )
    }

    /// A provider with no credential must report that, not go looking for one.
    @MainActor
    func testGeminiWithoutATokenDoesNotAdoptOne() async throws {
        SessionStore.shared.clear("gemini")
        AppState.markSignedOut("gemini")

        let provider = GoogleGeminiProvider()
        do {
            _ = try await provider.fetchUsage()
            XCTFail("fetch should not succeed without a credential")
        } catch let error as ProviderError {
            XCTAssertTrue(error.isAuth, "expected an auth error, got \(error)")
        }
        XCTAssertNil(
            SessionStore.shared.token(for: "gemini"),
            "the fetch claimed a browser session for itself"
        )
    }
}
