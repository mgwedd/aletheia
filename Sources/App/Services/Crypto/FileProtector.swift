import AletheiaCore
import CryptoKit
import Foundation

/// The single choke point every PHI file read/write passes through, so
/// encryption is transparent to the stores above it.
///
/// It holds the folder's DEK when encryption is unlocked, or `nil` when
/// encryption is off — and with a `nil` key every method is a plain
/// passthrough, so the un-encrypted code path is byte-for-byte what it was
/// before encryption existed. That's what lets `Store`, `CommentStore`, and the
/// recorder route through it unconditionally.
///
/// Reads tolerate a **half-migrated folder**: a plaintext file is returned
/// as-is even while a key is held (it gets sealed on its next write), and an
/// envelope is only ever handed back decrypted. The one hard error is an
/// envelope with no key — an encrypted file read while the folder is locked —
/// which must surface, not silently look like missing content.
struct FileProtector: Sendable {
    let key: SymmetricKey?

    /// The passthrough protector used everywhere encryption is off.
    static let passthrough = FileProtector(key: nil)

    var isEncrypting: Bool { key != nil }

    enum ProtectorError: LocalizedError, Equatable {
        case locked

        var errorDescription: String? {
            switch self {
            case .locked:
                return "This data is encrypted. Unlock it with your recovery passphrase to open it."
            }
        }
    }

    // MARK: - Raw data

    /// Reads and (if sealed and we hold the key) decrypts `url`. Throws
    /// `.locked` for an envelope with no key; propagates a decryption failure
    /// (wrong key / tampering) and any file-read error.
    func data(contentsOf url: URL) throws -> Data {
        let raw = try Data(contentsOf: url)
        guard DataCipher.isEnvelope(raw) else { return raw } // legacy/opted-out plaintext
        guard let key else { throw ProtectorError.locked }
        return try DataCipher.open(raw, using: key)
    }

    /// Like `data(contentsOf:)` but returns `nil` when the file is absent
    /// (mirrors the old `try? Data(contentsOf:)` "missing → nil" behavior),
    /// while still throwing on a present-but-undecryptable file.
    func dataIfPresent(at url: URL) throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try data(contentsOf: url)
    }

    /// Writes `data`, sealing it first when a key is held. `options` defaults to
    /// atomic, matching the stores' existing writes.
    func write(_ data: Data, to url: URL, options: Data.WritingOptions = .atomic) throws {
        try seal(data).write(to: url, options: options)
    }

    /// Seals in memory when a key is held, otherwise returns the bytes
    /// unchanged. Used where a value is encrypted but not written to its own
    /// file (e.g. a database column).
    func seal(_ data: Data) throws -> Data {
        guard let key else { return data }
        return try DataCipher.seal(data, using: key)
    }

    /// Opens an in-memory blob that may or may not be an envelope, symmetric to
    /// `seal`. A plaintext blob is returned as-is; an envelope needs the key.
    func open(_ blob: Data) throws -> Data {
        guard DataCipher.isEnvelope(blob) else { return blob }
        guard let key else { throw ProtectorError.locked }
        return try DataCipher.open(blob, using: key)
    }

    // MARK: - UTF-8 strings

    func string(contentsOf url: URL) throws -> String {
        String(decoding: try data(contentsOf: url), as: UTF8.self)
    }

    func stringIfPresent(at url: URL) throws -> String? {
        guard let data = try dataIfPresent(at: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func write(_ string: String, to url: URL, options: Data.WritingOptions = .atomic) throws {
        try write(Data(string.utf8), to: url, options: options)
    }

    // MARK: - Large files (audio)

    /// Seals a large file in place using the streaming `ChunkedCipher`. A no-op
    /// when encryption is off or the file is already sealed. Used for the
    /// session audio, where reading the whole recording into memory to use the
    /// one-shot cipher would be wasteful.
    func sealLargeFileInPlace(at url: URL) throws {
        guard let key else { return }
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        guard !ChunkedCipher.isEnvelope(fileAt: url) else { return }

        let temp = url.deletingLastPathComponent()
            .appendingPathComponent(".\(UUID().uuidString).tmp")
        try ChunkedCipher.seal(fileAt: url, to: temp, using: key)
        _ = try FileManager.default.replaceItemAt(url, withItemAt: temp)
    }

    /// Returns a readable copy of a possibly-sealed large file. When it's a
    /// chunked envelope and we hold the key, it's decrypted to a temporary file
    /// the caller must delete (`isTemporary == true`); otherwise the original
    /// URL is returned untouched. Lets audio processing (which needs a real,
    /// seekable file) stay crypto-agnostic.
    func decryptedCopyOfLargeFile(at url: URL) throws -> (url: URL, isTemporary: Bool) {
        guard let key, ChunkedCipher.isEnvelope(fileAt: url) else { return (url, false) }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("aletheia-\(UUID().uuidString).caf")
        try ChunkedCipher.open(fileAt: url, to: temp, using: key)
        return (temp, true)
    }
}

/// Field-level coding for database TEXT columns, sharing the file envelope so a
/// column and a file are protected the same way. When a key is held a value is
/// stored as base64 of the envelope; otherwise it's plain text. Decode detects
/// which it is, so a column migrates lazily just like a file.
enum FieldCipher {
    static func encode(_ text: String, using protector: FileProtector) -> String {
        guard protector.isEncrypting, let sealed = try? protector.seal(Data(text.utf8)) else { return text }
        return sealed.base64EncodedString()
    }

    static func decode(_ stored: String, using protector: FileProtector) -> String {
        guard
            let data = Data(base64Encoded: stored),
            DataCipher.isEnvelope(data),
            let opened = try? protector.open(data)
        else { return stored }
        return String(decoding: opened, as: UTF8.self)
    }
}
