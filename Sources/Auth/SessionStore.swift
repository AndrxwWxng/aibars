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

    /// Sessions lifted from a browser cookie. Memory only — deliberately never
    /// written to the Keychain.
    ///
    /// Every Keychain operation is an access-control check, and a locally signed
    /// build gets a new code signature on every rebuild, so the ACL written by
    /// the previous build no longer matches and macOS asks the user to approve.
    /// The cheapest way to stop being asked is to have nothing to ask about:
    /// these tokens are re-derived from the browser at launch in about half a
    /// second, silently, so storing them buys nothing and costs a dialog.
    private let ephemeral = Lock<[String: String]>([:])

    /// Pasted API keys, which cannot be re-derived from anything and so do have
    /// to be kept. One Keychain item for all of them, read at most once per
    /// launch — and not read at all when the metadata says none were ever
    /// stored, which is the common case.
    ///
    /// `nil` means "not loaded yet"; empty means "loaded, nothing there".
    private let persisted = Lock<[String: String]?>(nil)

    /// Set when the Keychain refused to hand the item over — almost always the
    /// user dismissing the access dialog. Worth telling them apart from "you
    /// never signed in", because the fix is completely different.
    private let accessDenied = Lock<Bool>(false)

    private static let combinedKey = "aibars.tokens"

    private init() {}

    // MARK: - Token CRUD

    public func setToken(_ token: String, for providerID: String, source: SessionSource = .manualPaste, accountHint: String? = nil) throws {
        if source == .browserCookie {
            ephemeral.withLock { $0[providerID] = token }
        } else {
            var current = loadPersisted()
            if current[providerID] != token {
                current[providerID] = token
                try persist(current)
            }
        }
        // The metadata is refreshed either way: it's what `hasCredential`
        // answers from, so skipping it would leave a provider looking
        // disconnected forever.
        var meta = loadMeta()
        meta[providerID] = SessionCredential(providerID: providerID, source: source, accountHint: accountHint)
        saveMeta(meta)
    }

    public func token(for providerID: String) -> String? {
        if let live = ephemeral.withLock({ $0[providerID] }) { return live }
        return loadPersisted()[providerID]
    }

    /// True when the Keychain item exists but couldn't be read.
    public var isAccessDenied: Bool {
        accessDenied.withLock { $0 }
    }

    public func clear(_ providerID: String) {
        ephemeral.withLock { $0[providerID] = nil }
        // Only touch the Keychain if this provider actually had something there.
        let wasPersisted = loadMeta()[providerID].map { $0.source != .browserCookie } ?? false
        if wasPersisted {
            var current = loadPersisted()
            if current.removeValue(forKey: providerID) != nil {
                try? persist(current)
            }
        }
        var meta = loadMeta()
        meta.removeValue(forKey: providerID)
        saveMeta(meta)
    }

    /// Drops the in-memory copy, so the next read goes back to the Keychain.
    /// Only needed if something outside this process could have changed it, or
    /// to retry after the user refused an access prompt.
    public func invalidateCache() {
        persisted.withLock { $0 = nil }
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

    /// Reads the pasted-key item, at most once, and only if there is reason to
    /// think it exists.
    private func loadPersisted() -> [String: String] {
        if let loaded = persisted.withLock({ $0 }) { return loaded }

        // The metadata says whether anything was ever pasted. If nothing was,
        // there is nothing in the Keychain to read — and not reading is the only
        // way to be certain no dialog appears.
        let irreplaceable = loadMeta().values.filter { $0.source != .browserCookie }
        guard !irreplaceable.isEmpty else {
            persisted.withLock { $0 = [:] }
            return [:]
        }

        var result: [String: String] = [:]
        switch KeychainStore.read(Self.combinedKey) {
        case .success(let data):
            if let data, let decoded = try? JSONDecoder().decode([String: String].self, from: data) {
                result = decoded
            }
            accessDenied.withLock { $0 = false }
        case .denied:
            // Cache the refusal. Leaving it unset meant every provider's fetch
            // asked again, and then again on the next refresh — the dialog came
            // back every few seconds. `invalidateCache()` is how a retry the
            // user actually asked for gets through.
            accessDenied.withLock { $0 = true }
            persisted.withLock { $0 = [:] }
            return [:]
        }

        let migrated = migrateLegacyItems(into: &result, irreplaceable: irreplaceable.map(\.providerID))
        persisted.withLock { $0 = result }
        if migrated {
            try? persist(result)
        }
        return result
    }

    /// Earlier builds stored one item per provider.
    ///
    /// Only pasted credentials are migrated, and nothing is deleted here.
    /// Deleting a Keychain item is itself an authorised operation, so tidying
    /// away the browser-derived leftovers cost one dialog each — which is how a
    /// change meant to stop the prompts ended up causing a burst of them. The
    /// leftovers are inert: nothing reads them, and the sessions they hold are
    /// re-derived from the browser anyway.
    private func migrateLegacyItems(into result: inout [String: String], irreplaceable: [String]) -> Bool {
        var moved = false
        for providerID in irreplaceable where result[providerID] == nil {
            guard case .success(let data) = KeychainStore.read(tokenKey(providerID)),
                  let data,
                  let value = String(data: data, encoding: .utf8),
                  !value.isEmpty
            else { continue }
            result[providerID] = value
            // Safe to remove: reading it just succeeded, so this is covered by
            // the same authorisation.
            KeychainStore.delete(tokenKey(providerID))
            moved = true
        }
        return moved
    }

    private func persist(_ values: [String: String]) throws {
        persisted.withLock { $0 = values }
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
