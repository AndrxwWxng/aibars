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

    /// Under XCTest, storage is in memory and the real Keychain is never
    /// touched.
    ///
    /// This is not tidiness. The test runner is a different binary from the app,
    /// so the ACL on the app's item doesn't cover it, and every test run put a
    /// "xctest wants to access key dev.aibars.app" dialog on screen — during
    /// someone's actual working day. It also means tests can no longer read,
    /// overwrite or delete the credentials a real install depends on.
    private static let isTesting = ProcessInfo.processInfo
        .environment["XCTestConfigurationFilePath"] != nil
        || ProcessInfo.processInfo.environment["XCTestBundlePath"] != nil
        || NSClassFromString("XCTestCase") != nil

    private static let memory = Lock<[String: Data]>([:])

    /// The outcome of a read. "Denied" has to be distinguishable from "absent":
    /// the user dismissing the access dialog is not the same as never having
    /// signed in, and telling them to sign in again would not help.
    public enum ReadResult {
        case success(Data?)
        case denied
    }

    public static func read(_ key: String) -> ReadResult {
        if isTesting { return .success(memory.withLock { $0[key] }) }
        var lastDenied = false
        for dataProtection in [true, false] {
            if usesDataProtection.withLock({ $0 }) == !dataProtection { continue }
            var query = baseQuery(for: key, dataProtection: dataProtection)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne

            var item: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &item)
            switch status {
            case errSecSuccess:
                return .success(item as? Data)
            case errSecAuthFailed, errSecUserCanceled, errSecInteractionNotAllowed:
                lastDenied = true
            default:
                continue
            }
        }
        return lastDenied ? .denied : .success(nil)
    }

    public static func set(_ value: String, for key: String) throws {
        try set(Data(value.utf8), for: key)
    }

    public static func set(_ data: Data, for key: String) throws {
        if isTesting {
            memory.withLock { $0[key] = data }
            return
        }

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
        guard case .success(let data) = read(key), let data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public static func delete(_ key: String) {
        if isTesting {
            memory.withLock { $0[key] = nil }
            return
        }
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
