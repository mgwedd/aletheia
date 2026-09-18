import CommonCrypto
import CryptoKit
import Foundation

/// Turns a human recovery passphrase into a 256-bit key-encryption key (KEK).
///
/// Passphrases are low-entropy, so this uses PBKDF2-HMAC-SHA256 with a random
/// per-keystore salt and a high iteration count to make brute-forcing a stolen
/// keystore expensive. PBKDF2 comes from CommonCrypto — a system library, no
/// third-party dependency (CryptoKit deliberately omits password KDFs). The
/// derived KEK never touches disk; only the DEK it wraps does, and only in
/// sealed form.
enum PassphraseKDF {
    /// OWASP's 2023 floor for PBKDF2-HMAC-SHA256. Tune up over time; the value
    /// used for a given keystore is stored in it, so old keystores keep opening.
    static let defaultIterations = 600_000
    /// 128-bit salt: enough that per-keystore salts don't collide and rainbow
    /// tables are useless.
    static let saltByteCount = 16
    /// AES-256 key length.
    static let keyByteCount = 32

    enum KDFError: LocalizedError {
        case emptyPassphrase
        case derivationFailed

        var errorDescription: String? {
            switch self {
            case .emptyPassphrase: return "The recovery passphrase can't be empty."
            case .derivationFailed: return "Couldn't derive a key from the passphrase."
            }
        }
    }

    static func randomSalt() -> Data {
        randomBytes(saltByteCount)
    }

    /// Derives the KEK for `passphrase` with the given `salt`/`iterations`.
    /// Deterministic in those three inputs, which is what lets the same
    /// passphrase re-derive the same KEK to unwrap the DEK later.
    static func deriveKey(passphrase: String, salt: Data, iterations: Int = defaultIterations) throws -> SymmetricKey {
        let passwordData = Data(passphrase.utf8)
        guard !passwordData.isEmpty else { throw KDFError.emptyPassphrase }

        var derived = Data(count: keyByteCount)
        let status = derived.withUnsafeMutableBytes { derivedPtr -> Int32 in
            salt.withUnsafeBytes { saltPtr -> Int32 in
                passwordData.withUnsafeBytes { pwPtr -> Int32 in
                    CCKeyDerivationPBKDF(
                        CCPBKDFAlgorithm(kCCPBKDF2),
                        pwPtr.bindMemory(to: CChar.self).baseAddress, passwordData.count,
                        saltPtr.bindMemory(to: UInt8.self).baseAddress, salt.count,
                        CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                        UInt32(iterations),
                        derivedPtr.bindMemory(to: UInt8.self).baseAddress, keyByteCount
                    )
                }
            }
        }
        guard status == kCCSuccess else { throw KDFError.derivationFailed }
        return SymmetricKey(data: derived)
    }

    /// Cryptographically random bytes via CryptoKit's CSPRNG.
    static func randomBytes(_ count: Int) -> Data {
        let key = SymmetricKey(size: .init(bitCount: count * 8))
        return key.withUnsafeBytes { Data($0) }
    }
}
