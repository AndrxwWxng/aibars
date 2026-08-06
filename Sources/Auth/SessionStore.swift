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

/// Stores session tokens in the Keychain, all of them in a single item keyed
/// `aibars.tokens`. The SessionCredential metadata lives in UserDefaults, which
/// is what answers "is this provider connected" without a Keychain read.
public final class SessionStore {
    public static let shared = SessionStore()

    private let defaults = UserDefaults.standard
    private let metaKey = "aibars.sessionMeta"

    /// Every token in one Keychain item, read once per launch.
    ///
    /// Each read of a Keychain item is an access-control check, and a locally
    /// signed build gets a new code signature every time it is rebuilt, which no
    /// longer matches the ACL recorded on items the previous build wrote — so
    /// macOS asks the user to approve it. One item read once is one dialog at
    /// worst, and none after "Always Allow". Nine items read on every refresh
    /// was a dialog every few seconds.
    ///
    /// `nil` means "not loaded yet"; an empty dictionary means "loaded, nothing
    /// stored", so a disconnected provider doesn't send us back to the Keychain.
    private let tokens = Lock<[String: String]?>(nil)

    /// Set when the Keychain refused to hand the item over — almost always the
    /// user dismissing the access dialog. Worth telling them apart from "you
    /// never signed in", because the fix is completely different.
    private let accessDenied = Lock<Bool>(false)

    private static let combinedKey = "aibars.tokens"

    private init() {}

    // MARK: - Token CRUD

    public func setToken(_ token: String, for providerID: String, source: SessionSource = .manualPaste, accountHint: String? = nil) throws {
        var current = loadTokens()
        if current[providerID] != token {
            current[providerID] = token
            try persist(current)
        }
        // The metadata is refreshed either way: it's what `hasCredential`
        // answers from, so skipping it would leave a provider looking
        // disconnected forever.
        var meta = loadMeta()
        meta[providerID] = SessionCredential(providerID: providerID, source: source, accountHint: accountHint)
        saveMeta(meta)
    }

    public func token(for providerID: String) -> String? {
        loadTokens()[providerID]
    }

    /// True when the Keychain item exists but couldn't be read.
    public var isAccessDenied: Bool {
        accessDenied.withLock { $0 }
    }

    public func clear(_ providerID: String) {
        var current = loadTokens()
        current.removeValue(forKey: providerID)
        try? persist(current)
        var meta = loadMeta()
        meta.removeValue(forKey: providerID)
        saveMeta(meta)
    }

    /// Drops the in-memory copy, so the next read goes back to the Keychain.
    /// Only needed if something outside this process could have changed it.
    public func invalidateCache() {
        tokens.withLock { $0 = nil }
        accessDenied.withLock { $0 = false }
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

    /// Reads the combined item once, migrating anything left in the old
    /// per-provider items on the way.
    private func loadTokens() -> [String: String] {
        if let loaded = tokens.withLock({ $0 }) { return loaded }

        var result: [String: String] = [:]
        switch KeychainStore.read(Self.combinedKey) {
        case .success(let data):
            if let data, let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                result = decoded
            }
            accessDenied.withLock { $0 = false }
        case .denied:
            // Leave the cache unset so a later attempt — after the user allows
            // access — can still succeed.
            accessDenied.withLock { $0 = true }
            return [:]
        }

        let migrated = migrateLegacyItems(into: &result)
        tokens.withLock { $0 = result }
        if migrated {
            try? persist(result)
        }
        return result
    }

    /// Earlier builds stored one item per provider. Each of those reads can cost
    /// a dialog, so only credentials that cannot be recovered any other way are
    /// worth migrating: a pasted API key is gone if we drop it, while a session
    /// taken from a browser cookie gets re-adopted at the next launch for free.
    private func migrateLegacyItems(into result: inout [String: String]) -> Bool {
        let meta = loadMeta()
        let irreplaceable = meta.values
            .filter { $0.source != .browserCookie }
            .map(\.providerID)
        guard !irreplaceable.isEmpty else { return false }
        var moved = false
        for providerID in irreplaceable where result[providerID] == nil {
            guard case .success(let data) = KeychainStore.read(tokenKey(providerID)),
                  let data,
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty
            else { continue }
            result[providerID] = value
            KeychainStore.delete(tokenKey(providerID))
            moved = true
        }
        // The browser-derived ones are re-adopted at launch, so their old items
        // are dead weight — and every one left behind is a dialog waiting to
        // happen on some future read.
        for credential in meta.values where credential.source == .browserCookie {
            KeychainStore.delete(tokenKey(credential.providerID))
        }
        return moved
    }

    private func persist(_ values: [String: String]) throws {
        tokens.withLock { $0 = values }
        guard !values.isEmpty else {
            KeychainStore.delete(Self.combinedKey)
            return
        }
        let data = try JSONEncoder().encode(values)
        try KeychainStore.set(data, for: Self.combinedKey)
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
