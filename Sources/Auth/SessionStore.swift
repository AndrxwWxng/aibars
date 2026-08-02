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

    private init() {}

    // MARK: - Token CRUD

    public func setToken(_ token: String, for providerID: String, source: SessionSource = .manualPaste, accountHint: String? = nil) throws {
        try KeychainStore.set(token, for: tokenKey(providerID))
        var meta = loadMeta()
        meta[providerID] = SessionCredential(providerID: providerID, source: source, accountHint: accountHint)
        saveMeta(meta)
    }

    public func token(for providerID: String) -> String? {
        KeychainStore.get(tokenKey(providerID))
    }

    public func clear(_ providerID: String) {
        KeychainStore.delete(tokenKey(providerID))
        var meta = loadMeta()
        meta.removeValue(forKey: providerID)
        saveMeta(meta)
    }

    public func credential(for providerID: String) -> SessionCredential? {
        loadMeta()[providerID]
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
