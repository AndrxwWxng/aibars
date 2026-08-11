import XCTest
@testable import aibarsCore

final class CodexAuthTests: XCTestCase {
    /// 2026-08-06T02:26:40Z. Fixed, because every expiry assertion here is
    /// arithmetic against it and a moving clock would make the boundaries
    /// untestable.
    private let now = Date(timeIntervalSince1970: 1_786_000_000)

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("codex-auth-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    // MARK: - Where the credential lives

    func testAuthFilePathsAreTheTwoDefaultsInOrderWhenCodexHomeIsUnset() {
        let urls = CodexAuth.authFileURLs(environment: [:], home: home)

        // No `CODEX_HOME`, no third path: an unset variable contributes nothing
        // rather than a path built from an empty string.
        XCTAssertEqual(urls.map(\.path), [
            path(".config/codex/auth.json"),
            path(".codex/auth.json")
        ])
    }

    func testCodexHomeLeadsAndTakesTheThreeDocumentedPaths() {
        let elsewhere = home.appendingPathComponent("elsewhere", isDirectory: true)
        let urls = CodexAuth.authFileURLs(environment: ["CODEX_HOME": elsewhere.path], home: home)

        XCTAssertEqual(urls.map(\.path), [
            path("elsewhere/auth.json"),
            path(".config/codex/auth.json"),
            path(".codex/auth.json")
        ])
    }

    func testCodexHomeIsExpandedAgainstTheHomeItWasHanded() {
        let tilde = CodexAuth.authFileURLs(environment: ["CODEX_HOME": "~/custom"], home: home)
        XCTAssertEqual(tilde.first?.path, path("custom/auth.json"))

        // A bare tilde is the home directory itself, not a directory called "~".
        let bare = CodexAuth.authFileURLs(environment: ["CODEX_HOME": "~"], home: home)
        XCTAssertEqual(bare.first?.path, path("auth.json"))
    }

    func testBlankCodexHomeIsTreatedAsUnset() {
        // An exported-but-empty variable is what a shell leaves behind after
        // `export CODEX_HOME=`, and it must not produce a path of "auth.json"
        // relative to whatever directory the app happens to be running in.
        for blank in ["", "   ", "\n", "\t "] {
            let urls = CodexAuth.authFileURLs(environment: ["CODEX_HOME": blank], home: home)
            XCTAssertEqual(urls.count, 2, "blank CODEX_HOME \(blank.debugDescription) should be ignored")
            XCTAssertEqual(urls.first?.path, path(".config/codex/auth.json"))
        }
    }

    func testCodexHomeSurroundedByWhitespaceIsStillAPath() {
        let urls = CodexAuth.authFileURLs(environment: ["CODEX_HOME": "  ~/custom \n"], home: home)
        XCTAssertEqual(urls.first?.path, path("custom/auth.json"))
    }

    func testCodexHomePointingAtADefaultDoesNotProduceTheSameFileTwice() {
        // Trailing slash and all: the same file reached by two spellings is one
        // file, and reading it twice would only cost a syscall to prove it.
        let urls = CodexAuth.authFileURLs(environment: ["CODEX_HOME": "~/.codex/"], home: home)

        XCTAssertEqual(urls.map(\.path), [
            path(".codex/auth.json"),
            path(".config/codex/auth.json")
        ])
    }

    // MARK: - Reading the file

    func testFullAuthFileParsesToAccessRefreshIDAndAccount() throws {
        let access = try jwt(["exp": 1_786_003_600])
        let data = try authFile([
            "OPENAI_API_KEY": NSNull(),
            "tokens": [
                "access_token": access,
                "refresh_token": "rt-1",
                "id_token": try jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "acct-from-id"]]),
                "account_id": "acct-explicit"
            ],
            "last_refresh": "2026-08-05T00:00:00.000Z"
        ])

        let tokens = try CodexAuth.tokens(fromAuthFile: data)

        XCTAssertEqual(tokens.accessToken, access)
        XCTAssertEqual(tokens.refreshToken, "rt-1")
        // The stored account id is the one Codex maintains, so it wins over the
        // copy embedded in the id token.
        XCTAssertEqual(tokens.accountID, "acct-explicit")
        XCTAssertEqual(tokens.expiresAt, Date(timeIntervalSince1970: 1_786_003_600))
    }

    func testAccountIDFallsBackToTheIDTokenClaim() throws {
        let data = try authFile([
            "tokens": [
                "access_token": "not-a-jwt",
                // Codex writes "" where it means absent; an empty account id is
                // no account id, not an account named "".
                "account_id": "",
                "id_token": try jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "acct-from-id"]])
            ]
        ])

        let tokens = try CodexAuth.tokens(fromAuthFile: data)

        XCTAssertEqual(tokens.accountID, "acct-from-id")
        // An access token that is not a JWT has no readable expiry, and none is
        // guessed for it.
        XCTAssertNil(tokens.expiresAt)
    }

    func testAccountIDStaysNilWhenNeitherSourceCarriesOne() throws {
        for idToken in ["", "not-a-jwt", try jwt(["sub": "user-1"]),
                        try jwt(["https://api.openai.com/auth": ["chatgpt_account_id": ""]])] {
            let data = try authFile(["tokens": ["access_token": "a.b.c", "id_token": idToken]])
            XCTAssertNil(try CodexAuth.tokens(fromAuthFile: data).accountID, idToken.debugDescription)
        }
    }

    func testEmptyRefreshTokenIsAbsentRatherThanAToken() throws {
        let data = try authFile(["tokens": ["access_token": "a.b.c", "refresh_token": ""]])
        XCTAssertNil(try CodexAuth.tokens(fromAuthFile: data).refreshToken)
    }

    func testAPIKeyOnlyFileIsNotAuthenticatedRatherThanUnparseable() throws {
        // The distinction is the point: an API key cannot read subscription
        // usage, so this is "you are not signed in", not "this file is broken".
        // `load` skips such a file and tries the next path because of it.
        let data = try authFile(["OPENAI_API_KEY": "sk-proj-abc123", "last_refresh": NSNull()])

        assertNotAuthenticated(data)

        // Same answer for the file the CLI writes before any login lands, and
        // for an access token stored as the empty string.
        assertNotAuthenticated(try authFile(["tokens": NSNull()]))
        assertNotAuthenticated(try authFile([String: Any]()))
        assertNotAuthenticated(try authFile(["tokens": [String: Any]()]))
        assertNotAuthenticated(try authFile(["tokens": ["access_token": ""]]))
        assertNotAuthenticated(try authFile(["tokens": ["access_token": NSNull(), "refresh_token": "rt"]]))
    }

    func testMalformedAuthFileThrowsRatherThanReturningEmptyTokens() throws {
        // Untrusted input: it is a file on disk that another tool owns and a
        // user can edit. Every one of these must throw, and none may come back
        // as a credential with empty fields.
        assertParseError(Data())
        assertParseError(Data("not json at all".utf8))
        assertParseError(Data("{\"tokens\":".utf8))
        // Valid JSON, wrong shape: a top-level array, and a `tokens` that is
        // not an object.
        assertParseError(Data("[]".utf8))
        assertParseError(Data("\"just a string\"".utf8))
        assertParseError(try authFile(["tokens": "sk-proj-abc"]))
        assertParseError(try authFile(["tokens": [["access_token": "a"]]]))
        // Right key, wrong type: a numeric access token is not a token.
        assertParseError(try authFile(["tokens": ["access_token": 42]]))
        // Not UTF-8 at all, which is what a half-written file looks like.
        assertParseError(Data([0xFF, 0xFE, 0x00, 0x01]))
    }

    // MARK: - Reading the expiry

    func testExpiryReadsExpFromAnUnsignedJWT() throws {
        // `alg: none`, empty signature — three parts, the last of them empty.
        let unsigned = try jwt(["exp": 1_786_003_600], signature: "")
        XCTAssertEqual(unsigned.split(separator: ".", omittingEmptySubsequences: false).count, 3)
        XCTAssertEqual(CodexAuth.expiry(ofJWT: unsigned), Date(timeIntervalSince1970: 1_786_003_600))

        // And with a signature present, which is what a real token carries. The
        // signature is never checked: this decides when to refresh, not whether
        // to trust.
        XCTAssertEqual(
            CodexAuth.expiry(ofJWT: try jwt(["exp": 1_786_003_600], signature: "not-a-real-signature")),
            Date(timeIntervalSince1970: 1_786_003_600)
        )
    }

    func testExpiryAcceptsEveryBase64URLPaddingCaseAndAlphabet() throws {
        // Padding is stripped from a JWT segment, so all three remainders have
        // to decode. The filler walks the payload through each of them.
        for length in 0...5 {
            let filler = String(repeating: "a", count: length)
            let token = try jwt(["exp": 1_700_000_000, "p": filler])
            XCTAssertEqual(
                CodexAuth.expiry(ofJWT: token),
                Date(timeIntervalSince1970: 1_700_000_000),
                "filler of \(length) characters"
            )
        }

        // A payload whose base64 uses the two characters base64url swaps out.
        let swapped = try jwt(["exp": 1_700_000_000, "p": "~aa?"])
        let payload = String(swapped.split(separator: ".", omittingEmptySubsequences: false)[1])
        XCTAssertTrue(payload.contains("-") && payload.contains("_"), "fixture does not exercise base64url")
        XCTAssertEqual(CodexAuth.expiry(ofJWT: swapped), Date(timeIntervalSince1970: 1_700_000_000))
    }

    func testExpiryIsNilForAnythingThatIsNotAJWTWithAnExp() throws {
        let notTokens = [
            "",
            "opaque-session-token",
            "a.b",
            "a.b.c.d",
            "....",
            // Three parts, but the payload is not base64.
            "aGVhZGVy.!!!!.sig",
            // Base64, but not JSON.
            "aGVhZGVy.bm90IGpzb24.sig",
            // JSON, but not an object.
            "aGVhZGVy.WzEsMl0.sig"
        ]
        for token in notTokens {
            XCTAssertNil(CodexAuth.expiry(ofJWT: token), token.debugDescription)
        }

        // A well-formed token that simply does not claim an expiry.
        XCTAssertNil(CodexAuth.expiry(ofJWT: try jwt(["sub": "user-1"])))
        XCTAssertNil(CodexAuth.expiry(ofJWT: try jwt(["exp": NSNull()])))
        XCTAssertNil(CodexAuth.expiry(ofJWT: try jwt(["exp": "soon"])))
    }

    func testExpiryHandlesZeroNegativeAndStringSeconds() throws {
        XCTAssertEqual(CodexAuth.expiry(ofJWT: try jwt(["exp": 0])), Date(timeIntervalSince1970: 0))
        // Nonsense, but arithmetic nonsense: it reads as long expired, which is
        // the safe direction for a value that decides whether to refresh.
        XCTAssertEqual(CodexAuth.expiry(ofJWT: try jwt(["exp": -1])), Date(timeIntervalSince1970: -1))
        // Some providers serialise numbers as strings; the coercion covers it.
        XCTAssertEqual(
            CodexAuth.expiry(ofJWT: try jwt(["exp": "1786003600"])),
            Date(timeIntervalSince1970: 1_786_003_600)
        )
    }

    // MARK: - When to refresh

    func testRefreshHappensInsideTheWindowAndNotOutsideIt() {
        XCTAssertEqual(CodexAuth.refreshWindow, 5 * 60)

        // Four minutes out: inside the window, rotate now.
        XCTAssertTrue(CodexAuth.needsRefresh(tokens(expiresIn: 4 * 60), now: now))
        // Six minutes out: still good, leave it alone.
        XCTAssertFalse(CodexAuth.needsRefresh(tokens(expiresIn: 6 * 60), now: now))
    }

    func testRefreshBoundaryIsInclusiveOnEitherSideOfTheWindow() {
        // Exactly at the window, and a hair either side of it.
        XCTAssertTrue(CodexAuth.needsRefresh(tokens(expiresIn: 300), now: now))
        XCTAssertTrue(CodexAuth.needsRefresh(tokens(expiresIn: 299.999), now: now))
        XCTAssertFalse(CodexAuth.needsRefresh(tokens(expiresIn: 300.001), now: now))

        // Zero, and long past: an expired token is refreshed, not skipped.
        XCTAssertTrue(CodexAuth.needsRefresh(tokens(expiresIn: 0), now: now))
        XCTAssertTrue(CodexAuth.needsRefresh(tokens(expiresIn: -86_400), now: now))
    }

    func testAnUnknownExpiryIsNotRefreshedOnASchedule() {
        // The shipped rule, and it is deliberate: rotating on a guess spends a
        // refresh token that may still have a live access token behind it, and
        // OpenAI answers a reused refresh token by killing the session. A token
        // with no readable `exp` waits for a 401 instead.
        XCTAssertFalse(CodexAuth.needsRefresh(tokens(expiresIn: nil), now: now))
    }

    func testNothingToRefreshWithMeansNoRefresh() {
        let noRefreshToken = CodexAuth.Tokens(
            accessToken: "a.b.c",
            refreshToken: nil,
            accountID: "acct",
            expiresAt: now.addingTimeInterval(-3_600)
        )
        XCTAssertFalse(CodexAuth.needsRefresh(noRefreshToken, now: now))
    }

    func testANonFiniteExpiryNeverTriggersARefresh() throws {
        // `Double("nan")` parses, so an `exp` of "nan" survives coercion and
        // reaches the comparison. Every comparison against NaN is false, which
        // lands on "do not refresh" — the same place an unreadable expiry lands.
        let token = try jwt(["exp": "nan"])
        let parsed = try CodexAuth.tokens(fromAuthFile: authFile([
            "tokens": ["access_token": token, "refresh_token": "rt"]
        ]))

        XCTAssertNotNil(parsed.expiresAt)
        XCTAssertFalse(CodexAuth.needsRefresh(parsed, now: now))
    }

    // MARK: - The refresh request

    func testRefreshEndpointAndContentTypeAreTheOnesCodexUses() {
        XCTAssertEqual(CodexAuth.refreshEndpoint.absoluteString, "https://auth.openai.com/oauth/token")
        // The inert fallback in the source is a file URL; reaching it would mean
        // the literal stopped parsing.
        XCTAssertFalse(CodexAuth.refreshEndpoint.isFileURL)
        XCTAssertEqual(CodexAuth.refreshContentType, "application/json")
        XCTAssertEqual(CodexAuth.clientID, "app_EMoamEEZ73f0CkXaXp7hrann")
    }

    func testRefreshBodyIsTheJSONTheDeclaredContentTypePromises() throws {
        let body = CodexAuth.refreshBody(refreshToken: "rt-1")

        // Not form encoding: the request announces application/json, so the body
        // is JSON, byte for byte, with keys sorted so it is reproducible.
        XCTAssertEqual(
            String(decoding: body, as: UTF8.self),
            #"{"client_id":"app_EMoamEEZ73f0CkXaXp7hrann","grant_type":"refresh_token","refresh_token":"rt-1","scope":"openid profile email"}"#
        )

        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        // The scope is fixed and must be sent: a narrower one comes back with an
        // access token the usage endpoint refuses.
        XCTAssertEqual(decoded, [
            "client_id": CodexAuth.clientID,
            "grant_type": "refresh_token",
            "refresh_token": "rt-1",
            "scope": "openid profile email"
        ])
    }

    func testRefreshBodyEscapesWhateverTheTokenContains() throws {
        // A refresh token is opaque; nothing stops it holding a quote or a
        // non-ASCII byte, and string concatenation would produce broken JSON.
        for token in ["", "a\"b\\c", "üñî/+=", "line\nbreak"] {
            let decoded = try XCTUnwrap(
                JSONSerialization.jsonObject(with: CodexAuth.refreshBody(refreshToken: token)) as? [String: String]
            )
            XCTAssertEqual(decoded["refresh_token"], token)
        }
    }

    // MARK: - Merging the response

    func testRotationTakesTheNewTokensAndTheirExpiry() throws {
        let access = try jwt(["exp": 1_786_010_000])
        let idToken = try jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "acct-new"]])

        let rotated = try XCTUnwrap(CodexAuth.rotated(
            tokens(expiresIn: 60),
            from: ["access_token": access, "refresh_token": "rt-2", "id_token": idToken]
        ))

        XCTAssertEqual(rotated.accessToken, access)
        XCTAssertEqual(rotated.refreshToken, "rt-2")
        XCTAssertEqual(rotated.accountID, "acct-new")
        XCTAssertEqual(rotated.expiresAt, Date(timeIntervalSince1970: 1_786_010_000))
    }

    func testRotationKeepsTheOldRefreshTokenAndAccountWhenTheResponseOmitsThem() throws {
        let before = tokens(expiresIn: 60)
        let access = try jwt(["exp": 1_786_010_000])

        // OpenAI rotates the refresh token on some responses and not others.
        // Dropping the old one on a response that did not replace it would leave
        // nothing to refresh with next time.
        let omitted = try XCTUnwrap(CodexAuth.rotated(before, from: ["access_token": access]))
        XCTAssertEqual(omitted.refreshToken, before.refreshToken)
        XCTAssertEqual(omitted.accountID, before.accountID)

        // "" means absent here as it does everywhere else in this file.
        let blank = try XCTUnwrap(CodexAuth.rotated(
            before,
            from: ["access_token": access, "refresh_token": "", "id_token": ""]
        ))
        XCTAssertEqual(blank.refreshToken, before.refreshToken)
        XCTAssertEqual(blank.accountID, before.accountID)

        // An id token that carries no account claim is no better than none.
        let unclaimed = try XCTUnwrap(CodexAuth.rotated(
            before,
            from: ["access_token": access, "id_token": try jwt(["sub": "user-1"])]
        ))
        XCTAssertEqual(unclaimed.accountID, before.accountID)
    }

    func testRotationWithoutAnAccessTokenIsADeadSession() throws {
        let before = tokens(expiresIn: 60)

        // Nil means "ask the user to run codex again", not "retry" — so every
        // response that fails to carry a usable access token must produce it.
        XCTAssertNil(CodexAuth.rotated(before, from: [:]))
        XCTAssertNil(CodexAuth.rotated(before, from: ["access_token": ""]))
        XCTAssertNil(CodexAuth.rotated(before, from: ["access_token": NSNull()]))
        XCTAssertNil(CodexAuth.rotated(before, from: ["access_token": 42]))
        XCTAssertNil(CodexAuth.rotated(before, from: ["error": "invalid_grant"]))
        XCTAssertNil(CodexAuth.rotated(before, from: ["accessToken": "a.b.c"]))
    }

    func testRotationDoesNotCarryTheOldExpiryOntoANewToken() throws {
        // The old `exp` describes the token that was just replaced. An opaque
        // replacement has an unknown expiry, and unknown is the honest answer.
        let rotated = try XCTUnwrap(CodexAuth.rotated(
            tokens(expiresIn: 60),
            from: ["access_token": "opaque-token"]
        ))

        XCTAssertNil(rotated.expiresAt)
        XCTAssertFalse(CodexAuth.needsRefresh(rotated, now: now))
    }

    // MARK: - Writing back

    func testWriteReplacesTheTokensAndKeepsEverythingElseInTheFile() throws {
        let url = home.appendingPathComponent("auth.json")
        try authFile([
            "OPENAI_API_KEY": "sk-proj-keep-me",
            "last_refresh": "2020-01-01T00:00:00.000Z",
            "tokens": [
                "access_token": "old-access",
                "refresh_token": "old-refresh",
                "id_token": "old-id",
                "account_id": "old-account",
                "something_a_newer_cli_added": 5
            ]
        ]).write(to: url)

        let fresh = CodexAuth.Tokens(
            accessToken: "new-access",
            refreshToken: "new-refresh",
            accountID: "new-account",
            expiresAt: nil
        )
        try CodexAuth.write(fresh, toAuthFile: url, now: now)

        let root = try readObject(at: url)
        let stored = try XCTUnwrap(root["tokens"] as? [String: Any])
        XCTAssertEqual(stored["access_token"] as? String, "new-access")
        XCTAssertEqual(stored["refresh_token"] as? String, "new-refresh")
        XCTAssertEqual(stored["account_id"] as? String, "new-account")
        // A rotation must not cost Codex a field it owns.
        XCTAssertEqual(stored["id_token"] as? String, "old-id")
        XCTAssertEqual(stored["something_a_newer_cli_added"] as? Int, 5)
        XCTAssertEqual(root["OPENAI_API_KEY"] as? String, "sk-proj-keep-me")
        // Leaving `last_refresh` stale would make our rotation invisible to the
        // CLI sharing the file.
        XCTAssertEqual(ProviderDate.parse(root["last_refresh"] as? String ?? ""), now)
    }

    func testWriteLeavesFieldsAloneWhenTheRotationHasNothingToPutThere() throws {
        let url = home.appendingPathComponent("auth.json")
        try authFile([
            "tokens": ["access_token": "old", "refresh_token": "old-refresh", "account_id": "old-account"]
        ]).write(to: url)

        try CodexAuth.write(
            CodexAuth.Tokens(accessToken: "new", refreshToken: nil, accountID: nil, expiresAt: nil),
            toAuthFile: url,
            now: now
        )

        let stored = try XCTUnwrap(try readObject(at: url)["tokens"] as? [String: Any])
        XCTAssertEqual(stored["access_token"] as? String, "new")
        // Absent in the rotation is not "delete it": erasing a live refresh
        // token would end the session on the next poll.
        XCTAssertEqual(stored["refresh_token"] as? String, "old-refresh")
        XCTAssertEqual(stored["account_id"] as? String, "old-account")
    }

    func testWrittenFileReadsBackAsTheTokensThatWentIn() throws {
        let url = home.appendingPathComponent("auth.json")
        try authFile(["tokens": ["access_token": "old"]]).write(to: url)

        let fresh = CodexAuth.Tokens(
            accessToken: try jwt(["exp": 1_786_010_000]),
            refreshToken: "rt-2",
            accountID: "acct-2",
            expiresAt: Date(timeIntervalSince1970: 1_786_010_000)
        )
        try CodexAuth.write(fresh, toAuthFile: url, now: now)

        XCTAssertEqual(try CodexAuth.tokens(fromAuthFile: Data(contentsOf: url)), fresh)
    }

    func testWriteReplacesATokensFieldThatIsNotAnObject() throws {
        // A file someone hand-edited into nonsense under `tokens` still parses
        // as JSON, so the write proceeds and the field is rebuilt rather than
        // merged into a string.
        let url = home.appendingPathComponent("auth.json")
        try authFile(["tokens": "sk-proj-abc", "OPENAI_API_KEY": "sk-proj-abc"]).write(to: url)

        try CodexAuth.write(
            CodexAuth.Tokens(accessToken: "new", refreshToken: "rt", accountID: nil, expiresAt: nil),
            toAuthFile: url,
            now: now
        )

        let stored = try XCTUnwrap(try readObject(at: url)["tokens"] as? [String: Any])
        XCTAssertEqual(stored["access_token"] as? String, "new")
        XCTAssertEqual(stored["refresh_token"] as? String, "rt")
    }

    func testWriteRefusesAFileItCannotReadOrParseAndLeavesItAsItFoundIt() throws {
        let missing = home.appendingPathComponent("nowhere/auth.json")
        XCTAssertThrowsError(try CodexAuth.write(tokens(expiresIn: 60), toAuthFile: missing, now: now)) { error in
            guard case ProviderError.configuration = error else {
                return XCTFail("expected a configuration error for an unreadable file, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))

        // Valid JSON but not an object, and not JSON at all: overwriting either
        // would be aibars deciding it knows better than the tool that owns them.
        for contents in ["[]", "\"nope\"", "", "{ this is not json"] {
            let url = home.appendingPathComponent("auth-\(UUID().uuidString).json")
            let original = Data(contents.utf8)
            try original.write(to: url)

            XCTAssertThrowsError(try CodexAuth.write(tokens(expiresIn: 60), toAuthFile: url, now: now)) { error in
                guard case ProviderError.parse = error else {
                    return XCTFail("expected a parse error for \(contents.debugDescription), got \(error)")
                }
            }
            XCTAssertEqual(try Data(contentsOf: url), original, contents.debugDescription)
        }
    }

    func testWrittenFileIsReadableOnlyByItsOwner() throws {
        let url = home.appendingPathComponent("auth.json")
        // Start deliberately loose, so a passing assertion means the write set
        // the mode rather than inheriting it.
        try authFile(["tokens": ["access_token": "old"]]).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)

        try CodexAuth.write(tokens(expiresIn: 60), toAuthFile: url, now: now)

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        // The file holds a live refresh token; an atomic write is a rename, and
        // the replacement must not arrive group-readable.
        XCTAssertEqual(mode?.int16Value, 0o600)
    }

    // MARK: - Load order

    func testLoadSkipsAnAPIKeyOnlyFileAndTakesTheNextRealLogin() throws {
        let apiKeyOnly = try write(["OPENAI_API_KEY": "sk-proj-abc"], to: ".config/codex")
        let login = try write(["tokens": ["access_token": "a.b.c", "refresh_token": "rt"]], to: ".codex")
        XCTAssertTrue(FileManager.default.fileExists(atPath: apiKeyOnly.path))

        let loaded = try XCTUnwrap(CodexAuth.load(environment: [:], home: home))

        XCTAssertEqual(loaded.file?.path, login.standardizedFileURL.path)
        XCTAssertEqual(loaded.tokens.refreshToken, "rt")
    }

    func testLoadSkipsAMalformedFileForALaterGoodOne() throws {
        try Data("{ half written".utf8).write(to: try directory(".config/codex").appendingPathComponent("auth.json"))
        let login = try write(["tokens": ["access_token": "a.b.c"]], to: ".codex")

        XCTAssertEqual(CodexAuth.load(environment: [:], home: home)?.file?.path, login.standardizedFileURL.path)
    }

    func testLoadPrefersCodexHomeOverTheDefaults() throws {
        let moved = try write(["tokens": ["access_token": "a.b.c", "account_id": "moved"]], to: "elsewhere")
        _ = try write(["tokens": ["access_token": "a.b.c", "account_id": "default"]], to: ".codex")

        let loaded = try XCTUnwrap(CodexAuth.load(
            environment: ["CODEX_HOME": home.appendingPathComponent("elsewhere").path],
            home: home
        ))

        XCTAssertEqual(loaded.file?.path, moved.standardizedFileURL.path)
        XCTAssertEqual(loaded.tokens.accountID, "moved")
    }

    func testLoadIsNilWhenNothingOnDiskHoldsALogin() throws {
        _ = try write(["OPENAI_API_KEY": "sk-proj-abc"], to: ".config/codex")
        _ = try write([String: Any](), to: ".codex")

        // Nothing else to fall back to: the keychain is off limits in a test
        // process, so this must not put an access dialog on anyone's screen.
        XCTAssertNil(CodexAuth.load(environment: [:], home: home))
    }

    func testKeychainIsNeverInterrogatedFromATestProcess() {
        // The test runner is a different binary from the app, and the item's ACL
        // names `codex` in any case. Reading it here would prompt a real user.
        XCTAssertNil(CodexAuth.keychainAuthFile())
        XCTAssertEqual(CodexAuth.keychainService, "Codex Auth")
    }

    // MARK: - Helpers

    /// A credential that expires `seconds` from `now`, with a refresh token, so
    /// only the quantity under test varies between the expiry cases.
    private func tokens(expiresIn seconds: TimeInterval?) -> CodexAuth.Tokens {
        CodexAuth.Tokens(
            accessToken: "a.b.c",
            refreshToken: "rt-1",
            accountID: "acct-1",
            expiresAt: seconds.map { now.addingTimeInterval($0) }
        )
    }

    /// An unsigned JWT over `claims`. Sorted keys so the encoded payload — which
    /// two tests assert against directly — is reproducible.
    private func jwt(_ claims: [String: Any], signature: String = "sig") throws -> String {
        let header = try JSONSerialization.data(
            withJSONObject: ["alg": "none", "typ": "JWT"],
            options: [.sortedKeys]
        )
        let payload = try JSONSerialization.data(withJSONObject: claims, options: [.sortedKeys])
        return "\(base64URL(header)).\(base64URL(payload)).\(signature)"
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private func authFile(_ root: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    }

    private func readObject(at url: URL) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: try Data(contentsOf: url)) as? [String: Any])
    }

    /// A path under the test home, standardised the same way `authFileURLs`
    /// standardises what it returns, so the comparison is about the path the
    /// function built and not about how either side spelled it.
    private func path(_ relative: String) -> String {
        home.appendingPathComponent(relative).standardizedFileURL.path
    }

    private func directory(_ relative: String) throws -> URL {
        let url = home.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @discardableResult
    private func write(_ root: [String: Any], to relative: String) throws -> URL {
        let url = try directory(relative).appendingPathComponent("auth.json")
        try authFile(root).write(to: url)
        return url
    }

    private func assertNotAuthenticated(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try CodexAuth.tokens(fromAuthFile: data), file: file, line: line) { error in
            guard let provider = error as? ProviderError, case .notAuthenticated = provider else {
                return XCTFail("expected notAuthenticated, got \(error)", file: file, line: line)
            }
            // What the caller keys off to send the user to Settings rather than
            // to retry the request.
            XCTAssertTrue(provider.isAuth, file: file, line: line)
        }
    }

    private func assertParseError(
        _ data: Data,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try CodexAuth.tokens(fromAuthFile: data), file: file, line: line) { error in
            guard case ProviderError.parse = error else {
                return XCTFail("expected a parse error, got \(error)", file: file, line: line)
            }
        }
    }
}
