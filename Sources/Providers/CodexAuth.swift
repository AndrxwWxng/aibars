import Foundation
import Security

/// Where a Codex OAuth token comes from, and when it has to be refreshed.
///
/// aibars does not sign anyone into Codex. The `codex` CLI already did that and
/// left the result on disk; this reads the same credential the CLI reads, in the
/// same order the CLI resolves it, and hands it to whoever is fetching usage.
///
/// Everything here is pure apart from `load`, `keychainAuthFile` and `write`, so
/// the parts that are easy to get wrong — the expiry rule, the rotation merge,
/// the path order — are testable without a home directory or a keychain.
public enum CodexAuth {
    /// The OAuth client the `codex` CLI registers. Not a secret: a public
    /// client id is half of the PKCE contract, and the refresh endpoint rejects
    /// a refresh token presented under a different one.
    public static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    /// `URL(string:)` on a literal cannot fail. The coalesce exists only because
    /// the initialiser is optional and nothing in this file force-unwraps; the
    /// fallback is deliberately inert so a mistake here fails loudly at the
    /// first request rather than quietly succeeding somewhere else.
    public static let refreshEndpoint: URL =
        URL(string: "https://auth.openai.com/oauth/token") ?? URL(fileURLWithPath: "/dev/null")

    /// The refresh request is JSON, because that is what the CLI sends. Matching
    /// it keeps us on the same server-side path as the tool that minted the
    /// token instead of a neighbouring one with its own quirks.
    public static let refreshContentType = "application/json"

    /// The generic-password item the CLI falls back to when it cannot write a
    /// file. It belongs to Codex, and this file only ever reads it.
    public static let keychainService = "Codex Auth"

    /// How far ahead of expiry a refresh is allowed. Five minutes is the CLI's
    /// own slack, so both tools rotate at the same moment rather than racing.
    public static let refreshWindow: TimeInterval = 5 * 60

    /// The credential, reduced to the four things a usage request needs.
    ///
    /// `expiresAt` is the access token's own `exp`, read at parse time, because
    /// it is the only honest answer to "is this still good" — see `needsRefresh`.
    public struct Tokens: Equatable, Sendable {
        public let accessToken: String
        public let refreshToken: String?
        public let accountID: String?
        public let expiresAt: Date?

        public init(accessToken: String, refreshToken: String?, accountID: String?, expiresAt: Date?) {
            self.accessToken = accessToken
            self.refreshToken = refreshToken
            self.accountID = accountID
            self.expiresAt = expiresAt
        }
    }

    /// A credential plus where it came from.
    ///
    /// `file` is nil when the credential came from the keychain, and there is no
    /// writer in this file that accepts an optional URL. That is the whole
    /// enforcement mechanism for "rotated tokens go back only to a file we read":
    /// it is a type, not a convention someone has to remember.
    public struct Loaded: Equatable, Sendable {
        public let tokens: Tokens
        public let file: URL?

        public init(tokens: Tokens, file: URL?) {
            self.tokens = tokens
            self.file = file
        }
    }

    // MARK: - Where the credential lives

    /// The auth files to try, in order, without touching the filesystem.
    ///
    /// `$CODEX_HOME` first when it is set — a user who moved their Codex home
    /// moved it for both tools — then the two defaults the CLI itself walks. The
    /// list is deduplicated, so pointing `CODEX_HOME` at `~/.codex` does not
    /// produce the same file twice.
    public static func authFileURLs(environment: [String: String], home: URL) -> [URL] {
        var directories: [URL] = []
        if let raw = environment["CODEX_HOME"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            directories.append(expand(raw, home: home))
        }
        directories.append(home.appendingPathComponent(".config/codex", isDirectory: true))
        directories.append(home.appendingPathComponent(".codex", isDirectory: true))

        var seen = Set<String>()
        return directories
            .map { $0.appendingPathComponent("auth.json").standardizedFileURL }
            .filter { seen.insert($0.path).inserted }
    }

    /// The first auth file that parses, then the keychain.
    ///
    /// A file that exists but carries only an `OPENAI_API_KEY` is skipped rather
    /// than treated as a failure: an API key cannot read subscription usage, and
    /// the next path along may hold a real login.
    public static func load(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Loaded? {
        for url in authFileURLs(environment: environment, home: home) {
            guard let data = try? Data(contentsOf: url),
                  let parsed = try? tokens(fromAuthFile: data) else { continue }
            return Loaded(tokens: parsed, file: url)
        }
        guard let data = keychainAuthFile(),
              let parsed = try? tokens(fromAuthFile: data) else { return nil }
        return Loaded(tokens: parsed, file: nil)
    }

    /// The same JSON, out of the item Codex owns.
    ///
    /// This item's ACL names the `codex` binary and not ours, so on a legacy
    /// keychain the read puts an access dialog on screen. It is therefore a
    /// fallback reached only when no auth file was found — never something to
    /// call on every poll.
    ///
    /// Under XCTest it returns nil without asking, for the reason `KeychainStore`
    /// documents: the test runner is a different binary, and a test run must not
    /// interrogate a real user's credentials or leave a dialog on their screen.
    public static func keychainAuthFile() -> Data? {
        if isTesting { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: keychainService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, !data.isEmpty else { return nil }
        return data
    }

    /// Signals XCTest being linked into *this* process rather than an
    /// environment variable, which the launching shell chooses. Same reasoning as
    /// `KeychainStore.isTesting`, and it has to be duplicated because that one is
    /// private to its own storage.
    private static let isTesting = NSClassFromString("XCTestCase") != nil

    // MARK: - Reading the file

    /// The shape the CLI writes. Unknown keys are ignored here and preserved on
    /// write-back, because this file is Codex's, not ours.
    private struct AuthFile: Decodable {
        struct StoredTokens: Decodable {
            let accessToken: String?
            let refreshToken: String?
            let idToken: String?
            let accountID: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case refreshToken = "refresh_token"
                case idToken = "id_token"
                case accountID = "account_id"
            }
        }

        let tokens: StoredTokens?
    }

    /// Parses `auth.json`.
    ///
    /// Throws `.notAuthenticated` when there is no OAuth access token — which is
    /// the API-key-only file as well as the never-logged-in one, and both mean
    /// the same thing to a subscription usage request.
    public static func tokens(fromAuthFile data: Data) throws -> Tokens {
        let file: AuthFile
        do {
            file = try JSONDecoder().decode(AuthFile.self, from: data)
        } catch {
            throw ProviderError.parse("auth.json is not the shape codex writes: \(error.localizedDescription)")
        }

        guard let stored = file.tokens, let access = nonEmpty(stored.accessToken) else {
            throw ProviderError.notAuthenticated
        }

        // Older logins predate `account_id` being stored beside the tokens; the
        // id token has carried it all along.
        let account = nonEmpty(stored.accountID)
            ?? nonEmpty(stored.idToken).flatMap(accountID(fromIDToken:))

        return Tokens(
            accessToken: access,
            refreshToken: nonEmpty(stored.refreshToken),
            accountID: account,
            expiresAt: expiry(ofJWT: access)
        )
    }

    // MARK: - When to refresh

    /// The `exp` claim, read without verifying the signature.
    ///
    /// That is not an oversight. This decides *when to refresh*, not whether to
    /// trust the token: the server checks the signature on every request anyway,
    /// and a forged `exp` can only make us refresh a token that still worked.
    public static func expiry(ofJWT token: String) -> Date? {
        guard let seconds = claims(ofJWT: token).flatMap({ ProviderNumber.coerce($0["exp"]) }) else {
            return nil
        }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Whether the access token should be rotated before the next request.
    ///
    /// The rule is the whole point of this file: refresh `refreshWindow` before
    /// the access token's own expiry, and at no other time. The obvious
    /// alternative — refresh when the stored `last_refresh` is more than eight
    /// days old — rotates a token that is still valid, and OpenAI answers a
    /// second use of an already-rotated refresh token with `refresh_token_reused`
    /// and kills the session. A wall clock cannot know what the token knows.
    ///
    /// So a token whose `exp` we cannot read is never refreshed on a schedule.
    /// It gets refreshed when a request comes back 401, which is the only
    /// evidence that actually exists.
    public static func needsRefresh(_ tokens: Tokens, now: Date) -> Bool {
        guard tokens.refreshToken != nil else { return false }
        guard let expiresAt = tokens.expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= refreshWindow
    }

    // MARK: - Refreshing

    /// The body of the refresh request, to be POSTed to `refreshEndpoint` as
    /// `refreshContentType`.
    ///
    /// The scope is fixed and must be sent: a refresh that asks for less comes
    /// back with an access token the usage endpoint will not accept.
    public static func refreshBody(refreshToken: String) -> Data {
        let payload: [String: String] = [
            "client_id": clientID,
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "scope": "openid profile email"
        ]
        // A flat dictionary of strings cannot fail to serialise; the coalesce is
        // here because the API throws, not because there is a case to handle.
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
    }

    /// Merges a refresh response over the tokens that produced it.
    ///
    /// Nil means the response carried no usable access token, which is a dead
    /// session rather than a transport failure — the caller should ask the user
    /// to run `codex` again, not retry.
    ///
    /// The refresh token and account id are carried forward when the response
    /// omits them: OpenAI rotates the refresh token on some responses and not
    /// others, and dropping the old one on a response that did not replace it
    /// would leave nothing to refresh with next time.
    public static func rotated(_ tokens: Tokens, from response: [String: Any]) -> Tokens? {
        guard let access = nonEmpty(response["access_token"] as? String) else { return nil }
        let refresh = nonEmpty(response["refresh_token"] as? String) ?? tokens.refreshToken
        let account = nonEmpty(response["id_token"] as? String)
            .flatMap(accountID(fromIDToken:)) ?? tokens.accountID

        return Tokens(
            accessToken: access,
            refreshToken: refresh,
            accountID: account,
            expiresAt: expiry(ofJWT: access)
        )
    }

    /// Writes rotated tokens back into an auth file aibars read.
    ///
    /// Only into a file, and only into one that already parses: everything the
    /// file holds that this type does not model — `OPENAI_API_KEY`, `id_token`,
    /// anything a newer CLI adds — is read back and written out untouched, so a
    /// rotation never costs Codex a field. A file that will not parse is left
    /// exactly as it is; overwriting it would be aibars deciding it knows better
    /// than the tool that owns it.
    ///
    /// There is deliberately no keychain counterpart. That item's ACL names
    /// `codex`, writing it would mean asking the user for permission to modify
    /// another app's credential, and a keychain login is the case where the CLI
    /// could not write a file in the first place.
    public static func write(_ tokens: Tokens, toAuthFile url: URL, now: Date = Date()) throws {
        guard let existing = try? Data(contentsOf: url) else {
            throw ProviderError.configuration("Could not read \(url.path) to rotate the token into it")
        }
        guard var root = (try? JSONSerialization.jsonObject(with: existing)) as? [String: Any] else {
            throw ProviderError.parse("\(url.lastPathComponent) is not a JSON object; refusing to overwrite it")
        }

        var stored = root["tokens"] as? [String: Any] ?? [:]
        stored["access_token"] = tokens.accessToken
        if let refresh = tokens.refreshToken { stored["refresh_token"] = refresh }
        if let account = tokens.accountID { stored["account_id"] = account }
        root["tokens"] = stored
        // The CLI keeps its own eye on this; leaving it stale after we rotated
        // would make our refresh invisible to the tool sharing the file.
        root["last_refresh"] = ProviderDate.iso8601.string(from: now)

        let data = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: [.atomic])
        // An atomic write is a rename over the original, so the replacement
        // carries default permissions. This file holds a live refresh token and
        // must not become group-readable because we touched it.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    // MARK: - Internals

    /// The account the token belongs to, out of the id token's OpenAI claim.
    /// Only ever used to fill a gap: it is a label, and a wrong one is better
    /// caught by the usage request failing than by guessing.
    private static func accountID(fromIDToken token: String) -> String? {
        let auth = claims(ofJWT: token)?["https://api.openai.com/auth"] as? [String: Any]
        return nonEmpty(auth?["chatgpt_account_id"] as? String)
    }

    /// A JWT's payload, decoded and nothing more.
    private static func claims(ofJWT token: String) -> [String: Any]? {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, let payload = base64URLDecoded(String(parts[1])) else { return nil }
        return (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any]
    }

    /// Base64url, which is base64 with two characters swapped and the padding
    /// dropped. `Data(base64Encoded:)` wants both back.
    private static func base64URLDecoded(_ segment: String) -> Data? {
        var text = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = text.count % 4
        if remainder > 0 { text += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: text)
    }

    /// Codex writes `""` where it means "absent" often enough that an empty
    /// string has to be treated as nil everywhere in this file.
    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Expands a leading `~` against the home we were handed, so the function
    /// stays pure and a test can hand it a temporary directory.
    private static func expand(_ path: String, home: URL) -> URL {
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }
}
