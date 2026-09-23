import AletheiaCore
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
        enum Kind: String, Codable { case passphrase }

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
        case noPassphraseWrapping
        case cannotRemoveLastWrapping
        case malformed

        var errorDescription: String? {
            switch self {
            case .wrongPassphrase:
                return "That passphrase didn't unlock the encrypted data. Check it and try again."
            case .noPassphraseWrapping:
                return "This encrypted folder has no recovery passphrase set."
            case .cannotRemoveLastWrapping:
                return "You can't remove the only way to unlock the data. Add another first."
            case .malformed:
                return "The encryption keystore for this folder is damaged."
            }
        }
    }

    // MARK: - Creation

    /// Creates a new keystore around a fresh random DEK, sealed under a KEK
    /// derived from `passphrase`. Returns both the keystore (to persist) and the
    /// live DEK (to seal files with this session). The DEK exists only in memory
    /// here; only its wrapped form is ever serialized.
    static func create(
        passphrase: String,
        label: String = "Recovery passphrase",
        iterations: Int = PassphraseKDF.defaultIterations,
        now: Date = Date()
    ) throws -> (keystore: Keystore, dek: SymmetricKey) {
        let dek = SymmetricKey(size: .bits256)
        let wrapping = try makePassphraseWrapping(
            dek: dek, passphrase: passphrase, label: label, iterations: iterations, now: now
        )
        return (Keystore(version: currentVersion, wrappings: [wrapping]), dek)
    }

    // MARK: - Unlock

    /// Tries every passphrase wrapping and returns the DEK if one opens.
    /// A wrong passphrase (or a tampered slot) fails GCM authentication on all
    /// of them and surfaces as `wrongPassphrase`.
    func unlock(passphrase: String) throws -> SymmetricKey {
        let passphraseSlots = wrappings.filter { $0.kind == .passphrase }
        guard !passphraseSlots.isEmpty else { throw KeystoreError.noPassphraseWrapping }
        for slot in passphraseSlots {
            if let dek = try? Self.openPassphraseWrapping(slot, passphrase: passphrase) {
                return dek
            }
        }
        throw KeystoreError.wrongPassphrase
    }

    // MARK: - Managing wrappings

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
        let wrapping = try Self.makePassphraseWrapping(
            dek: dek, passphrase: passphrase, label: label, iterations: iterations, now: now
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

    // MARK: - Disk

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
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try data.write(to: root.appendingPathComponent(Self.fileName), options: .atomic)
    }

    // MARK: - Internals

    private static func makePassphraseWrapping(
        dek: SymmetricKey,
        passphrase: String,
        label: String,
        iterations: Int,
        now: Date
    ) throws -> Wrapping {
        let salt = PassphraseKDF.randomSalt()
        let kek = try PassphraseKDF.deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let dekData = dek.withUnsafeBytes { Data($0) }
        let wrapped = try DataCipher.seal(dekData, using: kek)
        return Wrapping(
            id: UUID().uuidString,
            kind: .passphrase,
            kdf: "pbkdf2-hmac-sha256",
            salt: salt.base64EncodedString(),
            iterations: iterations,
            wrappedKey: wrapped.base64EncodedString(),
            label: label,
            createdAt: iso8601.string(from: now)
        )
    }

    private static func openPassphraseWrapping(_ slot: Wrapping, passphrase: String) throws -> SymmetricKey {
        guard
            let saltB64 = slot.salt, let salt = Data(base64Encoded: saltB64),
            let wrapped = Data(base64Encoded: slot.wrappedKey)
        else { throw KeystoreError.malformed }
        let iterations = slot.iterations ?? PassphraseKDF.defaultIterations
        let kek = try PassphraseKDF.deriveKey(passphrase: passphrase, salt: salt, iterations: iterations)
        let dekData = try DataCipher.open(wrapped, using: kek)
        return SymmetricKey(data: dekData)
    }

    private static let iso8601: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}
