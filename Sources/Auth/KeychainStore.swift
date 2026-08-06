import Foundation
import Security

/// Lightweight Keychain wrapper for storing session tokens and API keys.
///
/// Prefers the data-protection keychain, where access is governed by the app's
/// signing identity and there are no per-item access-control prompts at all. It
/// requires an entitlement that only a team-signed build carries, so a locally
/// signed build falls back to the legacy file-based keychain — which does prompt
/// whenever the reading binary's signature no longer matches the ACL recorded on
/// the item, i.e. after every rebuild. `SessionStore` caches reads for exactly
/// that reason.
public enum KeychainStore {
    private static let service = "dev.aibars.app"

    /// Whether the data-protection keychain is usable here. Resolved once on
    /// first write and reused, so the fallback isn't re-probed per call.
    private static let usesDataProtection = Lock<Bool?>(nil)

    public static func set(_ value: String, for key: String) throws {
        let data = Data(value.utf8)

        // Try the modern keychain first, unless a previous call established that
        // this build can't use it.
        let known = usesDataProtection.withLock { $0 }
        if known != false {
            let status = write(data, for: key, dataProtection: true)
            if status == errSecSuccess {
                usesDataProtection.withLock { $0 = true }
                return
            }
            if status != errSecMissingEntitlement {
                throw KeychainError(status: status)
            }
            usesDataProtection.withLock { $0 = false }
        }

        let status = write(data, for: key, dataProtection: false)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public static func get(_ key: String) -> String? {
        for dataProtection in [true, false] {
            if usesDataProtection.withLock({ $0 }) == !dataProtection { continue }
            var query = baseQuery(for: key, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
                  let data = item as? Data,
                  let string = String(data: data, encoding: .utf8)
            else { continue }
            return string
        }
        return nil
    }

    public static func delete(_ key: String) {
        // Both keychains: an item may predate a change in which one is in use.
        for dataProtection in [true, false] {
            SecItemDelete(baseQuery(for: key, dataProtection: dataProtection) as CFDictionary)
        }
    }

    public static func has(_ key: String) -> Bool {
        get(key) != nil
    }

    // MARK: - Internals

    private static func baseQuery(for key: String, dataProtection: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]
        if dataProtection {
            query[kSecUseDataProtectionKeychain as String] = true
        }
        return query
    }

    private static func write(_ data: Data, for key: String, dataProtection: Bool) -> OSStatus {
        let query = baseQuery(for: key, dataProtection: dataProtection)
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard updateStatus == errSecItemNotFound else { return updateStatus }

        var newItem = query
        newItem.merge(attributes) { _, new in new }
        return SecItemAdd(newItem as CFDictionary, nil)
    }
}

public struct KeychainError: LocalizedError {
    public let status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
        return "Keychain error \(status): \(message)"
    }
}
