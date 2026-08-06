import Foundation

/// Where a session credential is stored.
public enum SessionSource: String, Codable {
    case manualPaste
    case browserCookie
    case apiKey
}

/// A provider-agnostic session credential.
public struct SessionCredential: Codable, Hashable {
    public let providerID: String
    public let source: SessionSource
    public let createdAt: Date
    public let accountHint: String?

    public init(providerID: String, source: SessionSource, accountHint: String? = nil) {
        self.providerID = providerID
        self.source = source
        self.accountHint = accountHint
        self.createdAt = Date()
    }
}

/// Caches session tokens in the Keychain. Each provider's token is keyed
/// `aibars.<providerID>.token`. The SessionCredential metadata is stored
/// in UserDefaults for the settings UI.
public final class SessionStore {
    public static let shared = SessionStore()

    private let defaults = UserDefaults.standard
    private let metaKey = "aibars.sessionMeta"

    /// Tokens are cached in memory for the life of the process.
    ///
    /// Every provider reads its token on every refresh — nine providers a
    /// minute — and each read of a Keychain item is an access-control check.
    /// A locally signed build gets a new code signature every time it is
    /// rebuilt, which no longer matches the ACL on items the previous build
    /// created, so macOS asks the user to approve the read. Doing that once per
    /// token per launch is tolerable; doing it every minute is not.
    ///
    /// `nil` cached against a key means "already looked, nothing there", so a
    /// disconnected provider doesn't re-ask either.
    private let cache = Lock<[String: String?]>([:])

    private init() {}

    // MARK: - Token CRUD

    public func setToken(_ token: String, for providerID: String, source: SessionSource = .manualPaste, accountHint: String? = nil) throws {
        // Writing is an access-control check of its own. Re-storing a value we
        // already hold — which is what adopting an unchanged browser session
        // does on every launch — is worth skipping. The metadata is still
        // refreshed below: it's what `hasCredential` answers from, so skipping
        // it would leave a provider looking disconnected forever.
        if token != self.token(for: providerID) {
            try KeychainStore.set(token, for: tokenKey(providerID))
            cache.withLock { $0[tokenKey(providerID)] = token }
        }
        var meta = loadMeta()
        meta[providerID] = SessionCredential(providerID: providerID, source: source, accountHint: accountHint)
        saveMeta(meta)
    }

    public func token(for providerID: String) -> String? {
        let key = tokenKey(providerID)
        if let cached = cache.withLock({ $0[key] }) { return cached }
        let value = KeychainStore.get(key)
        cache.withLock { $0[key] = value }
        return value
    }

    public func clear(_ providerID: String) {
        KeychainStore.delete(tokenKey(providerID))
        cache.withLock { $0[tokenKey(providerID)] = .some(nil) }
        var meta = loadMeta()
        meta.removeValue(forKey: providerID)
        saveMeta(meta)
    }

    /// Drops the in-memory copies, so the next read goes back to the Keychain.
    /// Only needed if something outside this process could have changed them.
    public func invalidateCache() {
        cache.withLock { $0 = [:] }
    }

    public func credential(for providerID: String) -> SessionCredential? {
        loadMeta()[providerID]
    }

    /// Whether a credential was stored, answered from the metadata in
    /// UserDefaults rather than by reading the Keychain.
    ///
    /// Providers ask this at construction to decide whether they start out
    /// connected. Reading the token itself for nine providers during launch is
    /// nine access-control checks before the user has done anything — and the
    /// value isn't needed until a fetch actually runs. If the two ever disagree
    /// the fetch throws `notAuthenticated` and the row falls back to "Sign in",
    /// which is the correct outcome anyway.
    public func hasCredential(for providerID: String) -> Bool {
        loadMeta()[providerID] != nil
    }

    public func allCredentials() -> [SessionCredential] {
        Array(loadMeta().values).sorted { $0.providerID < $1.providerID }
    }

    // MARK: - Internals

    private func tokenKey(_ providerID: String) -> String {
        "aibars.\(providerID).token"
    }

    private func loadMeta() -> [String: SessionCredential] {
        guard let data = defaults.data(forKey: metaKey),
              let decoded = try? JSONDecoder().decode([String: SessionCredential].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func saveMeta(_ meta: [String: SessionCredential]) {
        if let data = try? JSONEncoder().encode(meta) {
            defaults.set(data, forKey: metaKey)
        }
    }
}
