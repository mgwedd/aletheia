import CryptoKit
import Foundation

/// The at-rest envelope for a single blob of PHI (a transcript, a summary, a
/// chat file, an audio file, a database export). Every sealed file on disk has
/// the same shape:
///
///   ┌────────┬─────────┬──────────────────────────────────────────────┐
///   │ magic  │ version │ AES-256-GCM combined box                      │
///   │ 4 B    │ 1 B     │ nonce(12) ‖ ciphertext(n) ‖ tag(16)           │
///   │ "ALT1" │ 0x01    │ (CryptoKit `SealedBox.combined`)              │
///   └────────┴─────────┴──────────────────────────────────────────────┘
///
/// The GCM tag authenticates the whole ciphertext, so a truncated or tampered
/// file fails to open rather than decrypting to garbage. The magic prefix lets
/// read paths tell a sealed file from a legacy plaintext one during migration
/// (`isEnvelope`), so enabling encryption can convert lazily without a flag day.
///
/// This type is deliberately key-agnostic: it seals and opens with whatever
/// `SymmetricKey` it's handed. Where that key comes from — and how it's wrapped
/// for a passphrase or the Keychain — is `Keystore`'s job, kept separate so the
/// cipher can be reasoned about and tested on its own.
public enum DataCipher {
    /// 4-byte file magic ("ALT1" = Aletheia envelope). Bumping the trailing
    /// digit alongside `version` is how a future incompatible format would be
    /// distinguished from this one.
    public static let magic = Data("ALT1".utf8)
    /// Envelope layout version. Present so `open` can reject a newer format
    /// loudly instead of misreading it.
    public static let version: UInt8 = 1

    private static var headerCount: Int { magic.count + 1 }

    public enum CipherError: LocalizedError, Equatable {
        case notAnEnvelope
        case unsupportedVersion(UInt8)
        case truncated

        public var errorDescription: String? {
            switch self {
            case .notAnEnvelope:
                return "This file isn't an Aletheia encrypted file."
            case let .unsupportedVersion(v):
                return "This file uses a newer encryption format (v\(v)) than this copy of Aletheia understands. Please update the app."
            case .truncated:
                return "This encrypted file is incomplete or damaged and can't be read."
            }
        }
    }

    /// Whether `data` starts with the envelope magic. Cheap header peek used by
    /// migration/read paths to route a blob to `open` vs. treat it as legacy
    /// plaintext. A true result doesn't guarantee the body decrypts — only that
    /// the file claims to be one of ours.
    public static func isEnvelope(_ data: Data) -> Bool {
        data.count >= magic.count && data.prefix(magic.count) == magic
    }

    /// Seals `plaintext` under `key` into the envelope above. A fresh random
    /// 96-bit nonce is generated per call by CryptoKit, so sealing the same
    /// bytes twice yields different ciphertext (no deterministic leakage).
    public static func seal(_ plaintext: Data, using key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else {
            // `combined` is only nil for a non-default nonce size, which we
            // never use — treat it as a programming error surfaced at runtime.
            throw CipherError.truncated
        }
        var out = Data(capacity: headerCount + combined.count)
        out.append(magic)
        out.append(version)
        out.append(combined)
        return out
    }

    /// Opens an envelope produced by `seal`. Throws `notAnEnvelope` for a blob
    /// that isn't ours, `unsupportedVersion` for a newer layout, `truncated`
    /// for a short file, and CryptoKit's authentication error for a wrong key
    /// or tampered ciphertext.
    public static func open(_ envelope: Data, using key: SymmetricKey) throws -> Data {
        guard isEnvelope(envelope) else { throw CipherError.notAnEnvelope }
        guard envelope.count > headerCount else { throw CipherError.truncated }
        let version = envelope[envelope.startIndex + magic.count]
        guard version == Self.version else { throw CipherError.unsupportedVersion(version) }
        let combined = envelope.subdata(in: (envelope.startIndex + headerCount)..<envelope.endIndex)
        let box = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(box, using: key)
    }
}
