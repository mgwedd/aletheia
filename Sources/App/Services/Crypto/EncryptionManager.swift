import CryptoKit
import Foundation

/// Owns the lifecycle of a data folder's encryption: whether it's on, whether
/// it's unlocked this session, and the in-memory DEK while it is. It's the one
/// object the UI talks to and the one `AppModel` consults to build the
/// `FileProtector` its stores read and write through.
///
///   ┌─ disabled ──enable(passphrase)──▶ unlocked ──lock()──┐
///   │                                       ▲              │
///   └─ lockedNeedsPassphrase ─unlock(pp)────┘◀─────────────┘
///     (keystore on disk, DEK not yet in memory this launch)
///
/// The DEK lives only in memory here and only while unlocked; `lock()` drops
/// it. Enabling and unlocking are the only ways it enters memory, and both go
/// through `Keystore`, so this type holds no cryptography of its own.
///
/// Not actor-isolated, matching `AppSettings`: every mutation happens
/// synchronously in response to a direct user action (a button in Settings or
/// first-run), so it follows the same main-thread-by-convention pattern.
final class EncryptionManager: ObservableObject {
    enum State: Equatable {
        /// No keystore in the data folder — encryption has never been turned on.
        case disabled
        /// Keystore present, but the DEK isn't in memory yet this launch.
        case lockedNeedsPassphrase
        /// DEK held; files can be read and written.
        case unlocked
    }

    enum ManagerError: LocalizedError, Equatable {
        case noDataFolder
        case alreadyEnabled
        case notEnabled
        case locked
        case decryptionIncomplete([String])

        var errorDescription: String? {
            switch self {
            case .noDataFolder: return "Choose a data folder before turning on encryption."
            case .alreadyEnabled: return "Encryption is already turned on for this folder."
            case .notEnabled: return "Encryption isn't turned on for this folder."
            case .locked: return "Unlock the data with your passphrase before changing encryption."
            case let .decryptionIncomplete(items):
                return "Encryption is still on: \(items.count) item(s) couldn't be decrypted, so nothing was removed. Try again."
            }
        }
    }

    @Published private(set) var state: State = .disabled

    /// Set by `AppModel` so the stores rebuild with a fresh `FileProtector`
    /// whenever the key or on/off state changes.
    var onProtectionChanged: (() -> Void)?

    private let dataRootProvider: () -> URL?
    private let deviceKeys: DeviceKeyStoring
    private var dek: SymmetricKey?

    init(dataRootProvider: @escaping () -> URL?, deviceKeys: DeviceKeyStoring = KeychainDeviceKeyStore()) {
        self.dataRootProvider = dataRootProvider
        self.deviceKeys = deviceKeys
        refresh()
    }

    // MARK: - Derived state

    var dataRoot: URL? { dataRootProvider() }

    /// Whether this folder has a keystore, i.e. encryption has been turned on
    /// (independent of whether it's unlocked this session).
    var isEnabled: Bool {
        guard let root = dataRoot else { return false }
        return Keystore.exists(at: root)
    }

    var isUnlocked: Bool { state == .unlocked }

    /// The protector the stores use: carries the DEK only while unlocked, so it
    /// seals/opens; otherwise it's a passthrough (encryption off) — reads of an
    /// encrypted-but-locked folder then surface `.locked` rather than garbage.
    var protector: FileProtector { FileProtector(key: dek) }

    /// Recomputes state from disk. Call on launch and whenever the data folder
    /// changes; it doesn't drop an already-held key for the same folder.
    func refresh() {
        guard isEnabled, let root = dataRoot else {
            dek = nil
            state = .disabled
            return
        }
        // Auto-unlock from this Mac's keychain if the user chose to be remembered.
        if dek == nil, let id = Keystore.load(from: root)?.id, let key = deviceKeys.load(for: id) {
            dek = key
        }
        state = dek == nil ? .lockedNeedsPassphrase : .unlocked
    }

    /// Whether the DEK is remembered in this Mac's keychain for auto-unlock.
    var isRememberedOnDevice: Bool {
        guard let root = dataRoot, let id = Keystore.load(from: root)?.id else { return false }
        return deviceKeys.load(for: id) != nil
    }

    /// Stores the DEK in this Mac's keychain so future launches unlock without
    /// the passphrase. Assigns the keystore a stable id on first use. Requires
    /// the folder to be unlocked.
    func rememberOnDevice() throws {
        guard let root = dataRoot, var keystore = Keystore.load(from: root) else { throw ManagerError.notEnabled }
        guard let dek else { throw FileProtector.ProtectorError.locked }
        let id: String
        if let existing = keystore.id {
            id = existing
        } else {
            id = UUID().uuidString
            keystore.id = id
            try keystore.write(to: root)
        }
        try deviceKeys.save(dek, for: id)
    }

    /// Removes the remembered DEK from this Mac's keychain; the folder stays
    /// encrypted and will ask for the passphrase next launch.
    func forgetOnDevice() {
        guard let root = dataRoot, let id = Keystore.load(from: root)?.id else { return }
        deviceKeys.delete(for: id)
    }

    // MARK: - Transitions

    /// Turns encryption on for this folder: mints a new keystore around a fresh
    /// DEK sealed under `passphrase`, holds the DEK unlocked, and seals the
    /// folder's existing plaintext PHI. Migration is best-effort — a keyed
    /// protector reads plaintext and sealed files alike, so a partially
    /// converted folder still works and the pass can be re-run — so the result
    /// is returned for the UI to surface rather than failing the enable.
    @discardableResult
    func enable(passphrase: String, iterations: Int = PassphraseKDF.defaultIterations) throws -> DataMigrator.Result {
        guard let root = dataRoot else { throw ManagerError.noDataFolder }
        guard !Keystore.exists(at: root) else { throw ManagerError.alreadyEnabled }
        let (keystore, dek) = try Keystore.create(passphrase: passphrase, iterations: iterations)
        try keystore.write(to: root)
        self.dek = dek
        state = .unlocked
        let result = DataMigrator.migrate(root: root, from: .passthrough, to: protector)
        onProtectionChanged?()
        return result
    }

    /// Turns encryption off: decrypts all PHI back to plaintext, and only then
    /// removes the keystore and drops the key. If any item can't be decrypted
    /// the keystore is kept (so nothing becomes unreadable) and it throws.
    /// Requires the folder to be unlocked.
    func disable() throws {
        guard let root = dataRoot, Keystore.exists(at: root) else { throw ManagerError.notEnabled }
        guard dek != nil else { throw ManagerError.locked }
        let result = DataMigrator.migrate(root: root, from: protector, to: .passthrough)
        guard result.isComplete else { throw ManagerError.decryptionIncomplete(result.failures) }
        forgetOnDevice() // drop the keychain copy before the keystore (which holds its id) is gone
        try FileManager.default.removeItem(at: root.appendingPathComponent(Keystore.fileName))
        dek = nil
        state = .disabled
        onProtectionChanged?()
    }

    /// Unlocks an already-enabled folder by recovering the DEK from `passphrase`.
    func unlock(passphrase: String) throws {
        guard let root = dataRoot, let keystore = Keystore.load(from: root) else {
            throw ManagerError.notEnabled
        }
        dek = try keystore.unlock(passphrase: passphrase)
        state = .unlocked
        onProtectionChanged?()
    }

    /// Drops the in-memory DEK; the folder stays encrypted and re-locks. Called
    /// on the same "app hidden" transition as the Tier-1 app lock.
    func lock() {
        guard dek != nil else { return }
        dek = nil
        refresh()
        onProtectionChanged?()
    }

    /// Adds a second recovery passphrase without re-encrypting any file (a new
    /// keyslot for the same DEK). Requires the folder to be unlocked.
    func addRecoveryPassphrase(_ passphrase: String, iterations: Int = PassphraseKDF.defaultIterations) throws {
        guard let root = dataRoot, let keystore = Keystore.load(from: root) else {
            throw ManagerError.notEnabled
        }
        guard let dek else { throw FileProtector.ProtectorError.locked }
        let updated = try keystore.addingPassphraseWrapping(dek: dek, passphrase: passphrase, iterations: iterations)
        try updated.write(to: root)
    }
}
