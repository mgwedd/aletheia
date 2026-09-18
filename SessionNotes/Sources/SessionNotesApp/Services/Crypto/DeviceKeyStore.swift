import CryptoKit
import Foundation
import Security

/// Stores a folder's data-encryption key (DEK) on *this Mac* so an encrypted
/// folder can unlock without retyping the recovery passphrase every launch.
/// Abstracted so the manager can be tested with an in-memory double instead of
/// the real Keychain.
protocol DeviceKeyStoring {
    func save(_ key: SymmetricKey, for id: String) throws
    func load(for id: String) -> SymmetricKey?
    func delete(for id: String)
}

/// Keychain-backed `DeviceKeyStoring`: the DEK lives in the login keychain as a
/// generic password, `WhenUnlockedThisDeviceOnly` (never synced to iCloud, never
/// readable while the Mac is locked). Keyed by the keystore's random id, so it's
/// scoped to one data folder.
///
/// This is a convenience/security trade-off the user opts into: anything running
/// as the logged-in user can then reach the key, which is the same "malware
/// while unlocked" surface the threat model already excludes. Off by default;
/// the passphrase is always the fallback.
struct KeychainDeviceKeyStore: DeviceKeyStoring {
    private let service = "com.sessionnotes.aletheia.datakey"

    enum KeychainError: LocalizedError {
        case unexpectedStatus(OSStatus)
        var errorDescription: String? {
            "Couldn't save the key to this Mac's keychain (error \(String(describing: self)))."
        }
    }

    func save(_ key: SymmetricKey, for id: String) throws {
        let data = key.withUnsafeBytes { Data($0) }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        SecItemDelete(base as CFDictionary) // replace any existing entry
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    func load(for id: String) -> SymmetricKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return SymmetricKey(data: data)
    }

    func delete(for id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
