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
    private let service = "com.aletheia.datakey"
    /// The data key is 256 bits; anything else in the keychain entry is not ours.
    static let keyLength = 32

    /// The four Keychain calls this store makes, so tests can observe them
    /// without touching the real Keychain.
    struct Client {
        var add: (CFDictionary) -> OSStatus
        var update: (_ query: CFDictionary, _ attributes: CFDictionary) -> OSStatus
        var copy: (CFDictionary) -> (OSStatus, Data?)
        var delete: (CFDictionary) -> OSStatus

        static let system = Client(
            add: { SecItemAdd($0, nil) },
            update: { SecItemUpdate($0, $1) },
            copy: { query in
                var result: CFTypeRef?
                let status = SecItemCopyMatching(query, &result)
                return (status, result as? Data)
            },
            delete: { SecItemDelete($0) }
        )
    }

    enum KeychainError: LocalizedError, Equatable {
        case unexpectedStatus(OSStatus)
        var errorDescription: String? {
            switch self {
            case let .unexpectedStatus(status):
                let reason = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
                return "Couldn't save the key to this Mac's keychain: \(reason) (OSStatus \(status))."
            }
        }
    }

    private let client: Client

    init(client: Client = .system) { self.client = client }

    func save(_ key: SymmetricKey, for id: String) throws {
        let data = key.withUnsafeBytes { Data($0) }
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        // Update in place so there is never a moment with no entry; add only when none exists.
        let updated = client.update(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw KeychainError.unexpectedStatus(updated) }
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = client.add(add as CFDictionary)
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
        let (status, data) = client.copy(query as CFDictionary)
        guard status == errSecSuccess, let data, data.count == Self.keyLength else { return nil }
        return SymmetricKey(data: data)
    }

    func delete(for id: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
        ]
        _ = client.delete(query as CFDictionary)
    }
}
