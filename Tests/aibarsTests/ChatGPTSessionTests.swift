import XCTest
@testable import aibarsCore

final class ChatGPTSessionTests: XCTestCase {
    // MARK: - The session document

    func testFullPayloadYieldsTokenEmailAndAccountID() throws {
        let token = try jwt(claims: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "8f1c0a6e-2b7d-4c11-9a3e-0d5f6b2c9e77"],
            "sub": "user-abc",
            "exp": 1_786_000_000
        ])
        let raw: [String: Any] = [
            "user": ["id": "user-abc", "email": "someone@example.com", "name": "Someone"],
            "expires": "2026-09-01T00:00:00Z",
            "accessToken": token,
            "authProvider": "auth0"
        ]

        let identity = try ChatGPTSession.parse(raw)

        XCTAssertEqual(identity.accessToken, token)
        XCTAssertEqual(identity.email, "someone@example.com")
        XCTAssertEqual(identity.accountID, "8f1c0a6e-2b7d-4c11-9a3e-0d5f6b2c9e77")
    }

    func testAccessTokenWithoutUserStillParses() throws {
        // The document is allowed to name a token and nothing else; the row it
        // feeds is still usable, it just has no address to label the account.
        let identity = try ChatGPTSession.parse(["accessToken": "eyJopaque"])

        XCTAssertEqual(identity.accessToken, "eyJopaque")
        XCTAssertNil(identity.email)
        // One segment is not a JWT, so no claim is invented from it.
        XCTAssertNil(identity.accountID)
    }

    func testSurroundingWhitespaceIsTrimmedOffTheToken() throws {
        let identity = try ChatGPTSession.parse(["accessToken": "\n  eyJopaque \t"])

        // A header built from an untrimmed value is a header the edge rejects.
        XCTAssertEqual(identity.accessToken, "eyJopaque")
    }

    // MARK: - Documents that mean re-auth

    func testEmptyObjectIsSessionExpiredRatherThanAnEmptyToken() {
        // What an expired cookie actually gets back: 200, `{}`.
        assertSessionExpired([:])
    }

    func testPresentButEmptyAccessTokenIsSessionExpired() {
        assertSessionExpired(["accessToken": ""])
        assertSessionExpired(["accessToken": "   "])
        assertSessionExpired(["accessToken": "\n\t "])
        // A user block without a token is still a signed-out document.
        assertSessionExpired(["user": ["email": "someone@example.com"], "expires": "2026-09-01T00:00:00Z"])
    }

    func testATokenThatIsNotAStringIsSessionExpired() {
        // Persisted or proxied responses are untrusted input: every one of these
        // has to land on re-auth rather than on a crash or an empty bearer.
        assertSessionExpired(["accessToken": NSNull()])
        assertSessionExpired(["accessToken": 0])
        assertSessionExpired(["accessToken": -1])
        assertSessionExpired(["accessToken": 1_234.5])
        assertSessionExpired(["accessToken": true])
        assertSessionExpired(["accessToken": ["eyJopaque"]])
        assertSessionExpired(["accessToken": ["token": "eyJopaque"]])
        // Right shape, wrong case: the field is camelCase upstream.
        assertSessionExpired(["access_token": "eyJopaque"])
    }

    // MARK: - The address

    func testAnAbsentEmptyOrUnreadableEmailIsNilRatherThanBlank() throws {
        let cases: [Any] = [
            ["id": "user-abc"],                     // no email key
            ["email": ""],                          // present and empty
            ["email": NSNull()],                    // present and null
            ["email": 42],                          // present and not a string
            ["email": ["someone@example.com"]],     // present and an array
            "someone@example.com",                  // user itself is a string
            [String](),                             // user itself is an array
            NSNull()
        ]

        for user in cases {
            let identity = try ChatGPTSession.parse(["accessToken": "eyJopaque", "user": user])
            XCTAssertNil(identity.email, "user \(user) should not produce an email")
            // Nothing about the user block may cost us the token.
            XCTAssertEqual(identity.accessToken, "eyJopaque")
        }
    }

    // MARK: - The workspace claim

    func testAccountIDFallsBackToATopLevelClaim() throws {
        let token = try jwt(claims: ["chatgpt_account_id": "acct-top-level"])

        XCTAssertEqual(try ChatGPTSession.parse(["accessToken": token]).accountID, "acct-top-level")
    }

    func testNamespacedClaimWinsOverTheTopLevelOne() throws {
        let token = try jwt(claims: [
            "https://api.openai.com/auth": ["chatgpt_account_id": "acct-namespaced"],
            "chatgpt_account_id": "acct-top-level"
        ])

        XCTAssertEqual(try ChatGPTSession.parse(["accessToken": token]).accountID, "acct-namespaced")
    }

    func testPayloadsOfEveryLengthDecodeBecausePaddingIsRestored() throws {
        // JWT segments are unpadded, so a payload whose base64 length is 2 or 3
        // past a multiple of four is the common case, not the exotic one. The
        // filler walks the byte count through all three remainders twice.
        for filler in 0...5 {
            let token = try jwt(claims: [
                "https://api.openai.com/auth": ["chatgpt_account_id": "acct-9f2"],
                "f": String(repeating: "x", count: filler)
            ])
            let payload = String(token.split(separator: ".")[1])
            XCTAssertFalse(payload.contains("="), "segment \(filler) should be unpadded")

            XCTAssertEqual(
                try ChatGPTSession.parse(["accessToken": token]).accountID,
                "acct-9f2",
                "filler of \(filler) should not change the claim"
            )
        }
    }

    func testTheURLSafeAlphabetIsTranslatedBack() throws {
        // Hand-written rather than round-tripped, so the `-` and `_` the JWT
        // alphabet substitutes for `+` and `/` are certain to be present:
        //   {"pad":"~~ÿ","https://api.openai.com/auth":{"chatgpt_account_id":"acct-9f2"}}
        let payload = "eyJwYWQiOiJ-fsO_IiwiaHR0cHM6Ly9hcGkub3BlbmFpLmNvbS9hdXRoIjp7ImNoYXRncHRfYWNjb3VudF9pZCI6ImFjY3QtOWYyIn19"
        XCTAssertTrue(payload.contains("-"))
        XCTAssertTrue(payload.contains("_"))

        let identity = try ChatGPTSession.parse(["accessToken": "eyJhbGciOiJSUzI1NiJ9.\(payload).c2ln"])

        XCTAssertEqual(identity.accountID, "acct-9f2")
    }

    func testATokenWithNoSignatureSegmentStillCarriesItsClaims() throws {
        // The signature is the server's business; two segments is enough to read.
        let full = try jwt(claims: ["chatgpt_account_id": "acct-9f2"])
        let unsigned = full.split(separator: ".").dropLast().joined(separator: ".")

        XCTAssertEqual(try ChatGPTSession.parse(["accessToken": unsigned]).accountID, "acct-9f2")
    }

    func testAClaimThatIsAbsentEmptyOrUnreadableLeavesTheAccountIDNil() throws {
        let payloads: [[String: Any]] = [
            [:],
            ["sub": "user-abc"],
            ["chatgpt_account_id": ""],
            ["chatgpt_account_id": NSNull()],
            ["chatgpt_account_id": 12_345],
            ["chatgpt_account_id": ["acct-9f2"]],
            ["https://api.openai.com/auth": ["chatgpt_account_id": ""]],
            ["https://api.openai.com/auth": ["chatgpt_account_id": NSNull()]],
            ["https://api.openai.com/auth": ["chatgpt_account_id": 12_345]],
            // The namespace present but not an object.
            ["https://api.openai.com/auth": "acct-9f2"],
            ["https://api.openai.com/auth": [String]()],
            // Right-looking key, wrong namespace.
            ["https://auth.openai.com": ["chatgpt_account_id": "acct-9f2"]]
        ]

        for claims in payloads {
            let token = try jwt(claims: claims)
            let identity = try ChatGPTSession.parse(["accessToken": token])

            XCTAssertNil(identity.accountID, "claims \(claims) should not name a workspace")
            // A missing workspace is a personal account, not a failure: the
            // token has to survive every one of these.
            XCTAssertEqual(identity.accessToken, token)
        }
    }

    func testMalformedTokensYieldNoAccountIDRatherThanThrowing() throws {
        let tokens = [
            "eyJopaque",                                  // no separators at all
            ".",                                          // two empty segments
            "..",                                         // three empty segments
            "eyJhbGciOiJSUzI1NiJ9.",                      // empty payload
            "eyJhbGciOiJSUzI1NiJ9.!!!!.c2ln",             // payload outside the alphabet
            "eyJhbGciOiJSUzI1NiJ9.eyJ.c2ln",              // payload too short to pad
            "eyJhbGciOiJSUzI1NiJ9.bm90IGpzb24.c2ln",      // decodes to "not json"
            "eyJhbGciOiJSUzI1NiJ9.WyJhIl0.c2ln",          // decodes to ["a"], not an object
            "eyJhbGciOiJSUzI1NiJ9.NDI.c2ln",              // decodes to "42"
            "a.b.c.d.e",                                  // more segments than a JWT has
            String(repeating: "z", count: 20_000) + ".." + String(repeating: "z", count: 20_000)
        ]

        for token in tokens {
            let identity = try ChatGPTSession.parse(["accessToken": token])

            XCTAssertNil(identity.accountID, "\(token.prefix(40)) should not name a workspace")
            XCTAssertEqual(identity.accessToken, token)
        }
    }

    // MARK: - The cookie the exchange spends

    func testCookieNameIsTheOneChatGPTProviderUsedBeforeTheExtraction() {
        // Stated literally: the extractors, the web-login capture rule and both
        // providers key off this, so a typo here silently signs everyone out.
        XCTAssertEqual(ChatGPTSession.cookieName, "__Secure-next-auth.session-token")
    }

    // MARK: - Identity

    func testIdentityDefaultsToNoEmailAndNoWorkspace() {
        let bare = ChatGPTSession.Identity(accessToken: "eyJopaque")

        XCTAssertNil(bare.email)
        XCTAssertNil(bare.accountID)
        XCTAssertEqual(bare, ChatGPTSession.Identity(accessToken: "eyJopaque", email: nil, accountID: nil))
        XCTAssertNotEqual(bare, ChatGPTSession.Identity(accessToken: "eyJopaque", accountID: "acct-9f2"))
    }

    // MARK: - Helpers

    /// A JWT the way the session endpoint hands one over: base64url, unpadded,
    /// with a signature this code never looks at.
    private func jwt(claims: [String: Any]) throws -> String {
        "\(try base64URL(["alg": "RS256", "typ": "JWT"])).\(try base64URL(claims)).c2lnbmF0dXJl"
    }

    private func base64URL(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func assertSessionExpired(
        _ raw: [String: Any],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try ChatGPTSession.parse(raw), file: file, line: line) { error in
            guard case ProviderError.sessionExpired = error else {
                return XCTFail("Expected ProviderError.sessionExpired, got \(error)", file: file, line: line)
            }
        }
    }
}
