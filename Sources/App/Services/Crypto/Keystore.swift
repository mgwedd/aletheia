import CryptoKit
import Foundation

/// The on-disk key material for an encrypted data folder: a single random
/// 256-bit **data encryption key (DEK)** that every PHI file is sealed under,
/// stored only in *wrapped* form. It is never written in the clear.
///
///   passphrase ──PBKDF2──▶ KEK ──AES-GCM-unwrap──▶ DEK ──▶ opens every file
///
/// The DEK can carry more than one wrapping — the same key sealed under several
/// KEKs, LUKS-keyslot style — so a folder can be openable by, say, a recovery
/// passphrase now and a Keychain-held key later, each addable or removable
/// without re-encrypting a single PHI file. v1 ships the passphrase wrapping;
/// the array shape is what lets a Keychain slot drop in without a format bump.
///
/// This lives at `<dataRoot>/.aletheia-keystore.json`. Losing it (and every
/// passphrase) means the encrypted files are unrecoverable — that's the point
/// of encryption, and the UI says so before turning it on.
struct Keystore: Codable, Equatable {
    static let fileName = ".aletheia-keystore.json"
    static let currentVersion = 1

    var version: Int
    var wrappings: [Wrapping]
    /// Random per-folder id, assigned lazily the first time the DEK is
    /// remembered on a device (the Keychain entry is keyed by it). `nil` until
    /// then, and omitted from older keystores — decoding tolerates its absence.
    var id: String?

    /// One way to unwrap the DEK. `wrappedKey` is `DataCipher.seal(DEK, KEK)`;
    /// for a passphrase slot the KEK is `PassphraseKDF(passphrase, salt,
    /// iterations)`, so the KDF parameters travel with the slot and old slots
    /// keep opening after the defaults are tuned up.
    struct Wrapping: Codable, Equatable {
        enum Kind: String, Codable {
            case passphrase
            case recoveryKey
        }

        var id: String
        var kind: Kind
        var kdf: String?
        var salt: String?
        var iterations: Int?
        var wrappedKey: String
        var label: String?
        var createdAt: String
    }

    enum KeystoreError: LocalizedError, Equatable {
        case wrongPassphrase
        case wrongRecoveryKey
        case noPassphraseWrapping
        case noRecoveryKeyWrapping
        case cannotRemoveLastWrapping
        case malformed

        var errorDescription: String? {
            switch self {
            case .wrongPassphrase:
                return "That passphrase didn't unlock the encrypted data. Check it and try again."
            case .wrongRecoveryKey:
                return "That recovery key didn't unlock the encrypted data. Check the words and try again."
            case .noPassphraseWrapping:
                return "This encrypted folder has no recovery passphrase set."
            case .noRecoveryKeyWrapping:
                return "This encrypted folder has no emergency recovery key set."
            case .cannotRemoveLastWrapping:
                return "You can't remove the only way to unlock the data. Add another first."
            case .malformed:
                return "The encryption keystore for this folder is damaged."
            }
        }
    }

    // MARK: - Creation

    /// Creates a new keystore around a fresh random DEK, sealed under a KEK
    /// derived from `passphrase`, and optionally a second slot for an emergency
    /// `recoveryKey`. Returns both the keystore (to persist) and the live DEK
    /// (to seal files with this session). The DEK exists only in memory here;
    /// only its wrapped form is ever serialized.
    static func create(
        passphrase: String,
        recoveryKey: String? = nil,
        label: String = "Recovery passphrase",
        recoveryKeyLabel: String = "Emergency recovery key",
        iterations: Int = PassphraseKDF.defaultIterations,
        now: Date = Date()
    ) throws -> (keystore: Keystore, dek: SymmetricKey) {
        let dek = SymmetricKey(size: .bits256)
        var wrappings = [
            try makeWrapping(
                dek: dek, secret: passphrase, kind: .passphrase, label: label, iterations: iterations, now: now
            )
        ]
        if let recoveryKey {
            let normalized = try RecoveryKey.normalizeAndValidate(recoveryKey)
            wrappings.append(
                try makeWrapping(
                    dek: dek, secret: normalized, kind: .recoveryKey, label: recoveryKeyLabel, iterations: iterations, now: now
                )
            )
        }
        return (Keystore(version: currentVersion, wrappings: wrappings), dek)
    }

    // MARK: - Unlock

    /// Tries every passphrase wrapping and returns the DEK if one opens.
    /// A wrong passphrase fails GCM authentication on all of them and surfaces
    /// as `wrongPassphrase`. A keystore with an unknown version, or whose slots
    /// are all unreadable (bad KDF, out-of-range iterations, bad encoding),
    /// surfaces as `malformed`.
    func unlock(passphrase: String) throws -> SymmetricKey {
        guard version == Self.currentVersion else { throw KeystoreError.malformed }
        let passphraseSlots = wrappings.filter { $0.kind == .passphrase }
        guard !passphraseSlots.isEmpty else { throw KeystoreError.noPassphraseWrapping }
        var readableSlots = 0
        for slot in passphraseSlots {
            guard let params = try? Self.parameters(of: slot) else { continue }
            readableSlots += 1
            if let dek = Self.openPassphraseWrapping(params, passphrase: passphrase) {
                return dek
            }
        }
        throw readableSlots == 0 ? KeystoreError.malformed : KeystoreError.wrongPassphrase
    }

    /// Tries every recovery key wrapping and returns the DEK if one opens.
    func unlock(recoveryKey: String) throws -> SymmetricKey {
        guard version == Self.currentVersion else { throw KeystoreError.malformed }
        let normalized = try RecoveryKey.normalizeAndValidate(recoveryKey)
        let recoverySlots = wrappings.filter { $0.kind == .recoveryKey }
        guard !recoverySlots.isEmpty else { throw KeystoreError.noRecoveryKeyWrapping }
        var readableSlots = 0
        for slot in recoverySlots {
            guard let params = try? Self.parameters(of: slot) else { continue }
            readableSlots += 1
            if let dek = Self.openPassphraseWrapping(params, passphrase: normalized) {
                return dek
            }
        }
        throw readableSlots == 0 ? KeystoreError.malformed : KeystoreError.wrongRecoveryKey
    }

    // MARK: - Managing wrappings

    /// Whether this keystore holds an emergency recovery key slot.
    var hasRecoveryKey: Bool {
        wrappings.contains { $0.kind == .recoveryKey }
    }

    /// Returns a copy with an added passphrase slot for the already-unlocked
    /// `dek`. Adding a slot never re-encrypts PHI — it only wraps the same DEK
    /// another way.
    func addingPassphraseWrapping(
        dek: SymmetricKey,
        passphrase: String,
        label: String = "Recovery passphrase",
        iterations: Int = PassphraseKDF.defaultIterations,
        now: Date = Date()
    ) throws -> Keystore {
        let wrapping = try Self.makeWrapping(
            dek: dek, secret: passphrase, kind: .passphrase, label: label, iterations: iterations, now: now
        )
        var copy = self
        copy.wrappings.append(wrapping)
        return copy
    }

    /// Returns a copy with an added 24-word emergency recovery key slot for the
    /// already-unlocked `dek`.
    func addingRecoveryKeyWrapping(
        dek: SymmetricKey,
        recoveryKey: String,
        label: String = "Emergency recovery key",
        iterations: Int = PassphraseKDF.defaultIterations,
        now: Date = Date()
    ) throws -> Keystore {
        let normalized = try RecoveryKey.normalizeAndValidate(recoveryKey)
        let wrapping = try Self.makeWrapping(
            dek: dek, secret: normalized, kind: .recoveryKey, label: label, iterations: iterations, now: now
        )
        var copy = self
        copy.wrappings.append(wrapping)
        return copy
    }

    /// Returns a copy with wrapping `id` removed. Refuses to remove the last
    /// one, which would orphan the data.
    func removingWrapping(id: String) throws -> Keystore {
        guard wrappings.contains(where: { $0.id == id }) else { return self }
        guard wrappings.count > 1 else { throw KeystoreError.cannotRemoveLastWrapping }
        var copy = self
        copy.wrappings.removeAll { $0.id == id }
        return copy
    }

    /// Returns a copy where every passphrase slot that opens with `current` is
    /// replaced by one wrapping the same DEK under `new` (other passphrase
    /// slots and the recovery key slot are untouched), plus that DEK. No PHI
    /// file is re-encrypted: the DEK does not change.
    func replacingPassphrase(
        current: String,
        new: String,
        iterations: Int = PassphraseKDF.defaultIterations,
        now: Date = Date()
    ) throws -> (keystore: Keystore, dek: SymmetricKey) {
        let dek = try unlock(passphrase: current)
        var copy = self
        var label = "Recovery passphrase"
        var replacedAny = false
        copy.wrappings.removeAll { slot in
            guard slot.kind == .passphrase,
                  let params = try? Self.parameters(of: slot),
                  Self.openPassphraseWrapping(params, passphrase: current) != nil else { return false }
            if !replacedAny, let existing = slot.label { label = existing }
            replacedAny = true
            return true
        }
        copy.wrappings.append(
            try Self.makeWrapping(dek: dek, secret: new, kind: .passphrase, label: label, iterations: iterations, now: now)
        )
        return (copy, dek)
    }

    // MARK: - Disk

    static let stagingFileName = ".aletheia-keystore.json.new"

    /// Replaces the keystore on disk without ever leaving it unusable: the new
    /// keystore is written to a staging file, read back and checked (it must
    /// decode to the same value and open to `dek` with `passphrase`), and only
    /// then swapped in. Any failure, or a crash before the swap, leaves the old
    /// keystore in place; the staging file is removed on failure.
    func replaceOnDisk(
        at root: URL,
        verifyingPassphrase passphrase: String,
        expectedDEK dek: SymmetricKey,
        beforeSwap: (() throws -> Void)? = nil
    ) throws {
        let fm = FileManager.default
        let destination = root.appendingPathComponent(Self.fileName)
        let staging = root.appendingPathComponent(Self.stagingFileName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try SecureFS.write(try encoder.encode(self), to: staging)
            let reread = try JSONDecoder().decode(Keystore.self, from: Data(contentsOf: staging))
            guard reread == self,
                  let opened = try? reread.unlock(passphrase: passphrase),
                  opened == dek else { throw KeystoreError.malformed }
            try beforeSwap?()
            _ = try fm.replaceItemAt(destination, withItemAt: staging)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    static func exists(at root: URL) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(fileName).path)
    }

    static func load(from root: URL) -> Keystore? {
        let url = root.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Keystore.self, from: data)
    }

    func write(to root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try SecureFS.createDirectory(at: root)
        try SecureFS.write(data, to: root.appendingPathComponent(Self.fileName))
    }

    // MARK: - Internals

    private static func makeWrapping(
        dek: SymmetricKey,
        secret: String,
        kind: Wrapping.Kind,
        label: String,
        iterations: Int,
        now: Date
    ) throws -> Wrapping {
        let salt = PassphraseKDF.randomSalt()
        let kek = try PassphraseKDF.deriveKey(passphrase: secret, salt: salt, iterations: iterations)
        let dekData = dek.withUnsafeBytes { Data($0) }
        let wrapped = try DataCipher.seal(dekData, using: kek)
        return Wrapping(
            id: UUID().uuidString,
            kind: kind,
            kdf: PassphraseKDF.identifier,
            salt: salt.base64EncodedString(),
            iterations: iterations,
            wrappedKey: wrapped.base64EncodedString(),
            label: label,
            createdAt: iso8601.string(from: now)
        )
    }

    private struct SlotParameters {
        let salt: Data
        let wrapped: Data
        let iterations: Int
    }

    /// Validates a slot's stored fields before any key derivation.
    private static func parameters(of slot: Wrapping) throws -> SlotParameters {
        guard
            slot.kdf == nil || slot.kdf == PassphraseKDF.identifier,
            let saltB64 = slot.salt, let salt = Data(base64Encoded: saltB64),
            let wrapped = Data(base64Encoded: slot.wrappedKey)
        else { throw KeystoreError.malformed }
        let iterations = slot.iterations ?? PassphraseKDF.defaultIterations
        guard PassphraseKDF.iterationRange.contains(iterations) else { throw KeystoreError.malformed }
        return SlotParameters(salt: salt, wrapped: wrapped, iterations: iterations)
    }

    /// Opens a slot with the normalized passphrase first, then the raw one, so
    /// slots wrapped before normalization was added keep unlocking.
    private static func openPassphraseWrapping(_ slot: SlotParameters, passphrase: String) -> SymmetricKey? {
        var candidates = [true]
        // Swift String equality is canonical, so compare the bytes.
        if !passphrase.precomposedStringWithCanonicalMapping.utf8.elementsEqual(passphrase.utf8) { candidates.append(false) }
        for normalize in candidates {
            guard
                let kek = try? PassphraseKDF.deriveKey(
                    passphrase: passphrase, salt: slot.salt, iterations: slot.iterations, normalize: normalize
                ),
                let dekData = try? DataCipher.open(slot.wrapped, using: kek)
            else { continue }
            return SymmetricKey(data: dekData)
        }
        return nil
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
