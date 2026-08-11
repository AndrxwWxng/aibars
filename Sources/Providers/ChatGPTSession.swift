import Foundation

/// The cookie-for-bearer-token exchange every chatgpt.com-backed provider needs.
///
/// `/backend-api` does not accept the session cookie: the web app trades it for
/// a short-lived bearer token at `/api/auth/session` first, and both
/// `ChatGPTProvider` (account entitlement) and `CodexProvider` (wham usage
/// windows) have to make that same call before they can ask anything. It lives
/// here once so a change to the endpoint, the cookie name or the shape of its
/// answer is a change in one place.
///
/// It is also the only place the signed-in address comes from — nothing further
/// down either provider's chain names the account.
public enum ChatGPTSession {
    /// The browser cookie the exchange spends. Extractors and the web-login
    /// capture rule key off this name too, so it is stated once.
    public static let cookieName = "__Secure-next-auth.session-token"

    /// Who is signed in, and what they can spend at `/backend-api`.
    public struct Identity: Equatable {
        /// Short-lived bearer, good for a handful of minutes. Never persisted:
        /// it is re-derived from the browser cookie on every poll.
        public let accessToken: String
        /// The signed-in address, when the session names one.
        public let email: String?
        /// The ChatGPT workspace this token is authorized for, when the token
        /// carries the claim. Endpoints that serve more than one workspace want
        /// it back as a `ChatGPT-Account-Id` header.
        public let accountID: String?

        public init(accessToken: String, email: String? = nil, accountID: String? = nil) {
            self.accessToken = accessToken
            self.email = email
            self.accountID = accountID
        }
    }

    /// Spend `sessionToken` on a bearer token. Throws `.sessionExpired` when the
    /// cookie is no longer good; see `parse(_:)` for why that is not a parse
    /// error.
    public static func identity(sessionToken: String) async throws -> Identity {
        let url = URL(string: "https://chatgpt.com/api/auth/session")!
        let (data, _) = try await ProviderHTTP(headers: [
            "Cookie": "\(cookieName)=\(sessionToken)",
            "Referer": "https://chatgpt.com/"
        ]).get(url)

        guard let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw ProviderError.parse("Session endpoint returned \(data.count) bytes that are not a JSON object")
        }
        return try parse(raw)
    }

    /// Reads the session document:
    ///
    ///     { user: { id: "user-…", email: "…", name: "…" },
    ///       expires: "2026-…", accessToken: "eyJ…", authProvider: "auth0" }
    ///
    /// An expired cookie is answered with `{}` — 200 and an empty object, not an
    /// error status — so a missing or empty `accessToken` is the only signal
    /// there is, and it means re-auth rather than a malformed response.
    public static func parse(_ raw: [String: Any]) throws -> Identity {
        let token = (raw["accessToken"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !token.isEmpty else {
            throw ProviderError.sessionExpired
        }

        let user = raw["user"] as? [String: Any]
        let email = (user?["email"] as? String).flatMap { $0.isEmpty ? nil : $0 }

        return Identity(accessToken: token, email: email, accountID: accountID(inJWT: token))
    }

    /// The workspace id is not a field of the session document; it is a claim
    /// inside the bearer token, `chatgpt_account_id` under the namespaced
    /// `https://api.openai.com/auth` claim. Read, never verified: the signature
    /// is the server's business, and a token this client did not like is one the
    /// server will reject anyway.
    ///
    /// Absent is not a failure — a personal account with one workspace works
    /// fine without the header — so every unhappy path here returns nil.
    private static func accountID(inJWT token: String) -> String? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2,
              let data = base64URLDecode(String(segments[1])),
              let claims = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }

        let auth = claims["https://api.openai.com/auth"] as? [String: Any]
        let id = (auth?["chatgpt_account_id"] ?? claims["chatgpt_account_id"]) as? String
        return (id?.isEmpty ?? true) ? nil : id
    }

    /// JWT segments are base64url and unpadded, which `Data(base64Encoded:)`
    /// rejects on both counts.
    private static func base64URLDecode(_ segment: String) -> Data? {
        var s = segment
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = s.count % 4
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }

}
