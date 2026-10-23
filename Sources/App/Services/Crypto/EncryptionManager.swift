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
        /// Encryption was turned on for this folder but its keystore is gone.
        /// Nothing can be read or written until the keystore is restored.
        case keystoreMissing
    }

    enum ManagerError: LocalizedError, Equatable {
        case noDataFolder
        case alreadyEnabled
        case notEnabled
        case locked
        case decryptionIncomplete([String])
        case keystoreMissing
        case passphraseTooShort
        case throttled(retryAfter: TimeInterval)

        var errorDescription: String? {
            switch self {
            case .noDataFolder: return "Choose a data folder before turning on encryption."
            case .alreadyEnabled: return "Encryption is already turned on for this folder."
            case .notEnabled: return "Encryption isn't turned on for this folder."
            case .locked: return "Unlock the data with your passphrase before changing encryption."
            case .keystoreMissing:
                return "This folder was encrypted but its keystore is missing. Restore the keystore file to the data folder, or choose a different folder."
            case .passphraseTooShort:
                return "Use a passphrase of at least \(PassphraseStrength.requiredLength) characters."
            case let .throttled(retryAfter):
                return "Too many incorrect attempts. Try again in \(Int(retryAfter.rounded(.up))) seconds."
            case let .decryptionIncomplete(items):
                return "Encryption is still on: \(items.count) item(s) couldn't be decrypted, so nothing was removed. Try again."
            }
        }
    }

    @Published private(set) var state: State = .disabled {
        didSet { SessionSearch.setEncryptionLocked(state == .lockedNeedsPassphrase || state == .keystoreMissing) }
    }

    /// Why the last attempt to keep the key in this Mac's keychain failed, for
    /// the UI to show; nil after a success.
    @Published private(set) var rememberError: String?

    /// Set by `AppModel` so the stores rebuild with a fresh `FileProtector`
    /// whenever the key or on/off state changes.
    var onProtectionChanged: (() -> Void)?

    /// Set by `AppModel` to write key and key-storage changes to the activity
    /// log. Notes are fixed text; nothing about the key itself is passed.
    var recordAudit: (AuditAction, String) -> Void = { _, _ in }

    private let dataRootProvider: () -> URL?
    private let deviceKeys: DeviceKeyStoring
    private let defaults: UserDefaults
    private var throttle: UnlockThrottle
    private var keyReference: ProtectionKey?
    private var keyedRoot: URL?
    private var dek: SymmetricKey? {
        get { keyReference?.key }
        set {
            keyReference?.revoke()
            keyReference = newValue.map(ProtectionKey.init)
            keyedRoot = newValue == nil ? nil : dataRoot
        }
    }

    init(
        dataRootProvider: @escaping () -> URL?,
        deviceKeys: DeviceKeyStoring = KeychainDeviceKeyStore.makeDefault(),
        defaults: UserDefaults = .standard,
        throttle: UnlockThrottle = UnlockThrottle()
    ) {
        self.dataRootProvider = dataRootProvider
        self.deviceKeys = deviceKeys
        self.defaults = defaults
        self.throttle = throttle
        refreshState()
        autoUnlockFromDevice()
    }

    // MARK: - Derived state

    var dataRoot: URL? { dataRootProvider() }

    /// Whether encryption has been turned on for this folder (independent of
    /// whether it's unlocked this session): it has a keystore, or it had one
    /// that has since gone missing.
    var isEnabled: Bool {
        guard let root = dataRoot else { return false }
        return Keystore.exists(at: root) || markerPresent(at: root)
    }

    /// Encryption was turned on here but the keystore file is gone.
    var isKeystoreMissing: Bool {
        guard let root = dataRoot else { return false }
        return !Keystore.exists(at: root) && markerPresent(at: root)
    }

    /// Seconds before another passphrase attempt is allowed; 0 when one is.
    var unlockRetryDelay: TimeInterval { throttle.remainingDelay }

    // MARK: - Enabled marker

    /// Small file in the data folder, mirrored by a UserDefaults flag, written when
    /// encryption is turned on and removed only when it is turned off. If it is
    /// present without a keystore, the keystore was lost, not never created.
    static let markerFileName = ".aletheia-encryption-enabled"

    private func markerURL(_ root: URL) -> URL { root.appendingPathComponent(Self.markerFileName) }
    private func markerDefaultsKey(_ root: URL) -> String { "encryptionEnabled.\(root.standardizedFileURL.path)" }

    private func markerPresent(at root: URL) -> Bool {
        FileManager.default.fileExists(atPath: markerURL(root).path) || defaults.bool(forKey: markerDefaultsKey(root))
    }

    private func writeMarker(at root: URL) throws {
        try Data("1\n".utf8).write(to: markerURL(root), options: .atomic)
        defaults.set(true, forKey: markerDefaultsKey(root))
    }

    private func clearMarker(at root: URL) {
        try? FileManager.default.removeItem(at: markerURL(root))
        defaults.removeObject(forKey: markerDefaultsKey(root))
    }

    var isUnlocked: Bool { state == .unlocked }

    /// The protector the stores use: carries the DEK only while unlocked, so it
    /// seals/opens; otherwise it's a passthrough (encryption off) — reads of an
    /// encrypted-but-locked folder then surface `.locked` rather than garbage.
    var protector: FileProtector {
        guard isEnabled else { return .passthrough }
        return FileProtector(keyReference: keyReference, requiresKey: true)
    }

    /// Recomputes state from disk. Call on launch and whenever the data folder
    /// changes; it doesn't drop an already-held key for the same folder.
    func refreshState() {
        guard isEnabled, let root = dataRoot else {
            dek = nil
            state = .disabled
            return
        }
        if keyedRoot != root { dek = nil }
        // Folders encrypted before the marker existed get one now.
        if Keystore.exists(at: root), !markerPresent(at: root) { try? writeMarker(at: root) }
        if dek != nil {
            state = .unlocked
        } else {
            state = Keystore.exists(at: root) ? .lockedNeedsPassphrase : .keystoreMissing
        }
    }

    /// Explicit device-key unlock, used at launch and after successful app
    /// authentication. A state refresh or lock must never call this.
    func autoUnlockFromDevice() {
        refreshState()
        guard state == .lockedNeedsPassphrase, let root = dataRoot,
              let id = Keystore.load(from: root)?.id,
              let key = deviceKeys.load(for: id) else { return }
        dek = key
        state = .unlocked
        onProtectionChanged?()
        SessionSearch.openIndex()
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
        do {
            let wasRemembered = isRememberedOnDevice
            try storeKeyOnDevice()
            rememberError = nil
            if !wasRemembered {
                recordAudit(.securitySettingChanged, AuditedSettings.rememberKeyOnMac.detail(for: true))
            }
        } catch {
            rememberError = error.localizedDescription
            throw error
        }
    }

    private func storeKeyOnDevice() throws {
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
        let wasRemembered = deviceKeys.load(for: id) != nil
        deviceKeys.delete(for: id)
        if wasRemembered {
            recordAudit(.securitySettingChanged, AuditedSettings.rememberKeyOnMac.detail(for: false))
        }
    }

    // MARK: - Transitions

    /// Turns encryption on for this folder: mints a new keystore around a fresh
    /// DEK sealed under `passphrase` (and optionally an emergency `recoveryKey`),
    /// holds the DEK unlocked, and seals the folder's existing plaintext PHI.
    /// Migration is best-effort — a keyed protector reads plaintext and sealed
    /// files alike, so a partially converted folder still works and the pass can
    /// be re-run — so the result is returned for the UI to surface rather than
    /// failing the enable.
    @discardableResult
    func enable(
        passphrase: String,
        recoveryKey: String? = nil,
        iterations: Int = PassphraseKDF.defaultIterations
    ) throws -> DataMigrator.Result {
        guard let root = dataRoot else { throw ManagerError.noDataFolder }
        guard !Keystore.exists(at: root) else { throw ManagerError.alreadyEnabled }
        // A new key here would orphan whatever the lost keystore sealed.
        guard !markerPresent(at: root) else { throw ManagerError.keystoreMissing }
        guard PassphraseStrength.meetsRequirement(passphrase) else { throw ManagerError.passphraseTooShort }
        let (keystore, dek) = try Keystore.create(
            passphrase: passphrase, recoveryKey: recoveryKey, iterations: iterations
        )
        try writeMarker(at: root)
        do {
            try keystore.write(to: root)
        } catch {
            clearMarker(at: root)
            throw error
        }
        self.dek = dek
        state = .unlocked
        let result = DataMigrator.migrate(root: root, from: .passthrough, to: protector)
        SessionSearch.deleteIndex()   // built while the folder was plaintext; the sweep rebuilds it
        onProtectionChanged?()
        SessionSearch.openIndex()
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
        // Drop the keychain copy before the keystore (which holds its id) is gone. Not
        // `forgetOnDevice()`: the disable is recorded as one event.
        if let id = Keystore.load(from: root)?.id { deviceKeys.delete(for: id) }
        clearMarker(at: root) // before the keystore goes, so a half-finished disable never looks like a lost keystore
        try FileManager.default.removeItem(at: root.appendingPathComponent(Keystore.fileName))
        dek = nil
        state = .disabled
        SessionSearch.deleteIndex()   // the folder is plaintext now, but don't leave a copy behind; the sweep rebuilds it
        onProtectionChanged?()
        SessionSearch.openIndex()
    }

    /// Unlocks an already-enabled folder by recovering the DEK from `passphrase`.
    func unlock(passphrase: String) throws {
        guard let root = dataRoot, isEnabled else { throw ManagerError.notEnabled }
        guard Keystore.exists(at: root) else { throw ManagerError.keystoreMissing }
        guard let keystore = Keystore.load(from: root) else { throw Keystore.KeystoreError.malformed }
        let wait = throttle.remainingDelay
        guard wait <= 0 else { throw ManagerError.throttled(retryAfter: wait) }
        do {
            dek = try keystore.unlock(passphrase: passphrase)
        } catch {
            throttle.recordFailure()
            throw error
        }
        throttle.recordSuccess()
        state = .unlocked
        onProtectionChanged?()
        SessionSearch.openIndex()   // after the stores are rebuilt, so the sweep it starts reads with the new key
    }

    /// Unlocks an already-enabled folder using the 24-word emergency recovery key.
    /// Shares the passphrase throttle, so alternating between the two doesn't
    /// buy extra guesses. A mistyped word or bad checksum is caught before the
    /// keystore is tried and isn't counted.
    func unlock(recoveryKey: String) throws {
        guard let root = dataRoot, isEnabled else { throw ManagerError.notEnabled }
        guard Keystore.exists(at: root) else { throw ManagerError.keystoreMissing }
        guard let keystore = Keystore.load(from: root) else { throw Keystore.KeystoreError.malformed }
        _ = try RecoveryKey.normalizeAndValidate(recoveryKey)
        let wait = throttle.remainingDelay
        guard wait <= 0 else { throw ManagerError.throttled(retryAfter: wait) }
        do {
            dek = try keystore.unlock(recoveryKey: recoveryKey)
        } catch {
            throttle.recordFailure()
            throw error
        }
        throttle.recordSuccess()
        state = .unlocked
        onProtectionChanged?()
        SessionSearch.openIndex()
    }

    /// Whether the current folder's keystore contains an emergency recovery key slot.
    var hasRecoveryKey: Bool {
        guard let root = dataRoot, let keystore = Keystore.load(from: root) else { return false }
        return keystore.hasRecoveryKey
    }

    /// Replaces the existing recovery key slot with a new 24-word emergency recovery key.
    /// If no key is provided, a fresh random one is generated.
    /// Requires the folder to be unlocked.
    @discardableResult
    func replaceRecoveryKey(
        _ newKey: String? = nil,
        iterations: Int = PassphraseKDF.defaultIterations
    ) throws -> String {
        guard let root = dataRoot, var keystore = Keystore.load(from: root) else {
            throw ManagerError.notEnabled
        }
        guard let dek else { throw FileProtector.ProtectorError.locked }
        let key = newKey ?? RecoveryKey.generate()
        let oldSlots = keystore.wrappings.filter { $0.kind == .recoveryKey }
        keystore = try keystore.addingRecoveryKeyWrapping(dek: dek, recoveryKey: key, iterations: iterations)
        for old in oldSlots {
            keystore = try keystore.removingWrapping(id: old.id)
        }
        try keystore.write(to: root)
        recordAudit(.encryptionKeyChanged, "Recovery key replaced")
        return key
    }

    /// Drops the in-memory DEK; the folder stays encrypted and re-locks. Called
    /// on the same "app hidden" transition as the Tier-1 app lock.
    func lock() {
        guard dek != nil else { return }
        dek = nil
        state = .lockedNeedsPassphrase
        SessionSearch.deleteIndex()   // plaintext transcript text: gone while locked, rebuilt on unlock
        LlamaRuntime.unloadAll()   // the built-in model's KV cache holds the last transcript
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
        recordAudit(.encryptionKeyChanged, "Recovery passphrase added")
    }
}
