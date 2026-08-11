import XCTest
import CommonCrypto
@testable import aibarsCore

/// Pins the Chromium cookie decryption path.
///
/// Every constant here is compiled into Chromium, not negotiated at runtime, so
/// a wrong one fails silently: the decrypt returns nothing, the cookie value is
/// empty, and aibars reports every Chromium-backed provider as signed out with
/// no error anywhere. These are the assertions that turn that into a red test.
final class ChromeCookieCryptoTests: XCTestCase {
    /// Chromium's fixed IV of sixteen spaces, mirrored here so the fixture
    /// encrypts the same way the browser does.
    private let iv = [UInt8](repeating: 0x20, count: 16)

    /// Builds a blob in the shape of the `encrypted_value` column: a version
    /// tag, then the value under AES-128-CBC with PKCS7 padding.
    private func encryptedBlob(_ plaintext: Data, key: Data, tag: String = "v10") -> Data {
        var ciphertext = Data(count: plaintext.count + kCCBlockSizeAES128)
        var written = 0
        let status: Int32 = ciphertext.withUnsafeMutableBytes { out in
            plaintext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    CCCrypt(
                        CCOperation(kCCEncrypt),
                        CCAlgorithm(kCCAlgorithmAES),
                        CCOptions(kCCOptionPKCS7Padding),
                        keyBytes.baseAddress, key.count,
                        iv,
                        input.baseAddress, plaintext.count,
                        out.baseAddress, out.count,
                        &written
                    )
                }
            }
        }
        XCTAssertEqual(status, Int32(kCCSuccess), "the fixture failed to encrypt")
        return Data(tag.utf8) + ciphertext.prefix(written)
    }

    /// A known answer, because the salt and the iteration count are private and
    /// a length-and-determinism check would still pass with either one changed.
    /// PBKDF2-HMAC-SHA1("peanuts", "saltysalt", 1003) truncated to 16 bytes.
    func testDerivedKeyMatchesChromiumsParameters() throws {
        let key = try ChromeCookieCrypto.deriveKey(from: Data("peanuts".utf8))
        XCTAssertEqual(
            key.map { String(format: "%02x", $0) }.joined(),
            "d9a09d499b4e1b7461f28e67972c6dbd"
        )

        let other = try ChromeCookieCrypto.deriveKey(from: Data("password".utf8))
        XCTAssertEqual(
            other.map { String(format: "%02x", $0) }.joined(),
            "9395139d5abdba8b749042ad882c0937"
        )
        XCTAssertEqual(key.count, 16, "AES-128 needs a 16-byte key")
        XCTAssertEqual(key, try ChromeCookieCrypto.deriveKey(from: Data("peanuts".utf8)))
    }

    func testDecryptsAValueWrittenTheWayChromiumWritesIt() throws {
        let key = try ChromeCookieCrypto.deriveKey(from: Data("peanuts".utf8))
        let blob = encryptedBlob(Data("sessionKey-abc123".utf8), key: key)
        XCTAssertEqual(try ChromeCookieCrypto.decrypt(blob, key: key), "sessionKey-abc123")
    }

    /// Some builds tag with v11 instead of v10; both are the same scheme here.
    func testAcceptsTheV11Tag() throws {
        let key = try ChromeCookieCrypto.deriveKey(from: Data("peanuts".utf8))
        let blob = encryptedBlob(Data("sessionKey-abc123".utf8), key: key, tag: "v11")
        XCTAssertEqual(try ChromeCookieCrypto.decrypt(blob, key: key), "sessionKey-abc123")
    }

    /// Chromium 130 and later prepend a 32-byte hash of the cookie's domain to
    /// the plaintext. Missing that strip is the failure that breaks every
    /// current Chrome install at once.
    func testStripsTheDomainHashNewerChromiumPrepends() throws {
        let key = try ChromeCookieCrypto.deriveKey(from: Data("peanuts".utf8))
        let plaintext = Data(repeating: 0x00, count: 32) + Data("sessionKey-abc123".utf8)
        let blob = encryptedBlob(plaintext, key: key)
        XCTAssertEqual(try ChromeCookieCrypto.decrypt(blob, key: key), "sessionKey-abc123")
    }

    func testRejectsAnUnknownSchemePrefix() throws {
        let key = try ChromeCookieCrypto.deriveKey(from: Data("peanuts".utf8))
        let blob = encryptedBlob(Data("sessionKey-abc123".utf8), key: key, tag: "v20")
        XCTAssertThrowsError(try ChromeCookieCrypto.decrypt(blob, key: key)) { error in
            guard case ChromeCookieCrypto.Failure.unsupportedScheme(let prefix) = error else {
                XCTFail("expected unsupportedScheme, got \(error)")
                return
            }
            XCTAssertEqual(prefix, "v20")
        }
    }

    /// A blob too short to hold a tag, and one too short to hold a block, are
    /// both things a truncated or half-written cookie row can produce.
    func testRejectsBlobsTooShortToDecrypt() throws {
        let key = try ChromeCookieCrypto.deriveKey(from: Data("peanuts".utf8))
        for blob in [Data("v1".utf8), Data("v10".utf8) + Data(repeating: 0x41, count: 8)] {
            XCTAssertThrowsError(try ChromeCookieCrypto.decrypt(blob, key: key)) { error in
                guard case ChromeCookieCrypto.Failure.decryptFailed = error else {
                    XCTFail("expected decryptFailed, got \(error)")
                    return
                }
            }
        }
    }

    /// The wrong Safe Storage key must not yield a value. Padding validation
    /// rejects it first; the printability check is the backstop.
    func testRejectsAValueEncryptedUnderAnotherKey() throws {
        let key = try ChromeCookieCrypto.deriveKey(from: Data("peanuts".utf8))
        let other = try ChromeCookieCrypto.deriveKey(from: Data("password".utf8))
        let blob = encryptedBlob(Data("sessionKey-abc123".utf8), key: key)
        XCTAssertThrowsError(try ChromeCookieCrypto.decrypt(blob, key: other)) { error in
            guard case ChromeCookieCrypto.Failure.decryptFailed = error else {
                XCTFail("expected decryptFailed, got \(error)")
                return
            }
        }
    }
}
