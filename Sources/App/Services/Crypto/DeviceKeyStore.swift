import CryptoKit
import Foundation
import Security

/// Defaults for choices offered when a passphrase is first set or entered.
enum EncryptionSettingsDefaults {
    /// Whether "Remember on this Mac" starts checked. Off: the key is copied to
    /// the login keychain only when the user asks.
    static let rememberKeyOnDevice = false
}

/// Stores a folder's data-encryption key (DEK) on *this Mac* so an encrypted
/// folder can unlock without retyping the recovery passphrase every launch.
/// Abstracted so the manager can be tested with an in-memory double instead of
/// the real Keychain.
protocol DeviceKeyStoring {
    func save(_ key: SymmetricKey, for id: String) throws
    func load(for id: String) -> SymmetricKey?
    func delete(for id: String)
}

/// Process-lifetime store used instead of the Keychain while tests run
/// (see `TestHost.usesLiveKeychain`).
final class ProcessMemoryDeviceKeyStore: DeviceKeyStoring {
    private let lock = NSLock()
    private var keys: [String: SymmetricKey] = [:]
    func save(_ key: SymmetricKey, for id: String) throws { lock.withLock { keys[id] = key } }
    func load(for id: String) -> SymmetricKey? { lock.withLock { keys[id] } }
    func delete(for id: String) { lock.withLock { _ = keys.removeValue(forKey: id) } }
}

extension KeychainDeviceKeyStore {
    private static let testStore = ProcessMemoryDeviceKeyStore()

    /// The Keychain store, or a shared in-memory one under XCTest without opt-in.
    static func makeDefault(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DeviceKeyStoring {
        TestHost.usesLiveKeychain(environment: environment) ? KeychainDeviceKeyStore() : testStore
    }
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
                return "Couldn't save the key to this Mac's keychain: \(Self.reason(for: status)) (OSStatus \(status))."
            }
        }

        /// A plain-language reason for the statuses a user can actually hit, else the system's text.
        static func reason(for status: OSStatus) -> String {
            switch status {
            case errSecInteractionNotAllowed: return "the keychain is locked"
            case errSecAuthFailed: return "access to the keychain was refused"
            case errSecUserCanceled: return "the keychain request was cancelled"
            case errSecNotAvailable: return "no keychain is available"
            case errSecDuplicateItem: return "an entry for this folder already exists"
            case errSecMissingEntitlement: return "the app isn't allowed to use the keychain"
            default: return SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            }
        }
    }

    /// Every query and add names the entry as non-synchronizable, so the key can
    /// never reach iCloud Keychain.
    static func baseQuery(service: String, id: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id,
            kSecAttrSynchronizable as String: false,
        ]
    }

    private let client: Client

    init(client: Client = .system) { self.client = client }

    func save(_ key: SymmetricKey, for id: String) throws {
        let data = key.withUnsafeBytes { Data($0) }
        let base = Self.baseQuery(service: service, id: id)
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
        var query = Self.baseQuery(service: service, id: id)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let (status, data) = client.copy(query as CFDictionary)
        guard status == errSecSuccess, let data, data.count == Self.keyLength else { return nil }
        return SymmetricKey(data: data)
    }

    func delete(for id: String) {
        _ = client.delete(Self.baseQuery(service: service, id: id) as CFDictionary)
    }
}
