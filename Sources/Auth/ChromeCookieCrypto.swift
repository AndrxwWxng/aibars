import Foundation
import CommonCrypto
import Security

/// Decrypts Chromium cookie values on macOS.
///
/// Chromium encrypts each cookie value with AES-128-CBC. The key is derived
/// from a random password Chromium generates once and stores in the login
/// keychain under "<Browser> Safe Storage", run through PBKDF2 with a fixed
/// salt and iteration count that are compiled into Chromium itself.
///
/// Reading that keychain item is what makes this work, and it is also why the
/// first sign-in shows a system prompt asking the user to allow aibars access.
/// Denying it is not fatal — the caller falls back to pasting a token.
public enum ChromeCookieCrypto {
    /// Chromium's `kSalt`, `kEncryptionVersionPrefix` and derivation
    /// parameters, from components/os_crypt.
    private static let salt = "saltysalt"
    private static let iterations: UInt32 = 1003
    private static let keyLength = 16
    /// Chromium uses a fixed IV of sixteen spaces.
    private static let iv = [UInt8](repeating: 0x20, count: 16)

    public enum Failure: LocalizedError {
        case keychainDenied(OSStatus)
        case noStorageKey
        case unsupportedScheme(String)
        case decryptFailed

        public var errorDescription: String? {
            switch self {
            case .keychainDenied(let status):
                return "Keychain access was denied (status \(status)). Paste a token instead."
            case .noStorageKey:
                return "No Safe Storage key found for that browser."
            case .unsupportedScheme(let prefix):
                return "Unrecognised cookie encryption scheme '\(prefix)'."
            case .decryptFailed:
                return "Could not decrypt the cookie value."
            }
        }
    }

    /// Reads the browser's Safe Storage password out of the login keychain.
    public static func storageKey(service: String, account: String) throws -> Data {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, !data.isEmpty else { throw Failure.noStorageKey }
            return data
        case errSecItemNotFound:
            throw Failure.noStorageKey
        default:
            throw Failure.keychainDenied(status)
        }
    }

    /// PBKDF2-HMAC-SHA1 with Chromium's fixed parameters.
    public static func deriveKey(from password: Data) throws -> Data {
        var derived = Data(count: keyLength)
        let saltBytes = Array(salt.utf8)
        let status: Int32 = derived.withUnsafeMutableBytes { derivedBytes in
            password.withUnsafeBytes { passwordBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes.baseAddress?.assumingMemoryBound(to: CChar.self),
                    password.count,
                    saltBytes,
                    saltBytes.count,
                    CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1),
                    iterations,
                    derivedBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    keyLength
                )
            }
        }
        guard status == kCCSuccess else { throw Failure.decryptFailed }
        return derived
    }

    /// Decrypts a value from the `encrypted_value` column.
    ///
    /// The blob starts with a version tag: `v10` on macOS. Chromium 130 and
    /// later also prepend a 32-byte SHA-256 of the cookie's domain to the
    /// plaintext, which has to be stripped back off.
    public static func decrypt(_ blob: Data, key: Data) throws -> String {
        guard blob.count > 3 else { throw Failure.decryptFailed }
        let prefix = String(decoding: blob.prefix(3), as: UTF8.self)
        guard prefix == "v10" || prefix == "v11" else {
            throw Failure.unsupportedScheme(prefix)
        }
        let ciphertext = blob.dropFirst(3)
        guard ciphertext.count >= kCCBlockSizeAES128 else { throw Failure.decryptFailed }

        var plaintext = Data(count: ciphertext.count + kCCBlockSizeAES128)
        var decryptedCount = 0
        let status: Int32 = plaintext.withUnsafeMutableBytes { out in
            ciphertext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCDecrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count,
                        iv,
                        input.baseAddress, ciphertext.count,
                        out.baseAddress, out.count,
                        &decryptedCount
                    )
                }
            }
        }
        guard status == kCCSuccess, decryptedCount > 0 else { throw Failure.decryptFailed }
        plaintext = plaintext.prefix(decryptedCount)

        if let value = readableString(from: plaintext) {
            return value
        }
        // Newer Chromium builds prefix the plaintext with a domain hash.
        if plaintext.count > 32, let value = readableString(from: plaintext.dropFirst(32)) {
            return value
        }
        throw Failure.decryptFailed
    }

    /// A cookie value has to be printable ASCII to be usable as a header, so
    /// that doubles as the check for "did this decrypt into something real".
    private static func readableString(from data: Data) -> String? {
        guard !data.isEmpty,
              let string = String(data: data, encoding: .utf8),
              !string.isEmpty,
              string.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value < 0x7F })
        else { return nil }
        return string
    }
}
