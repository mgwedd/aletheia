import CryptoKit
import Foundation

/// Produces and restores an **end-to-end-encrypted** backup of the SQLite store.
///
/// The archive is the database file sealed with the streaming `ChunkedCipher`
/// (AES-256-GCM) under a key the *user* holds — the same recovery-passphrase key
/// machinery as the at-rest `FileProtector`, which never leaves the Mac. So the
/// resulting blob is opaque: it's safe to sit in a Time Machine backup, on an
/// external drive, or — the point of the CloudKit path — uploaded to the user's
/// private iCloud, where the server only ever stores ciphertext it cannot read.
///
/// Streaming (not the one-shot cipher) keeps memory flat regardless of database
/// size. This type is deliberately key-agnostic and destination-agnostic: it
/// turns a plaintext DB file into an encrypted archive and back, and nothing
/// more. Where the archive is stored is a `BackupService`'s job; producing a
/// consistent source copy (via `VACUUM INTO`) is the caller's.
enum EncryptedBackupArchive {
    /// File extension for an encrypted backup blob.
    static let fileExtension = "aletheiabackup"

    enum ArchiveError: LocalizedError, Equatable {
        case sourceMissing
        case notAnArchive

        var errorDescription: String? {
            switch self {
            case .sourceMissing: return "The database to back up wasn't found."
            case .notAnArchive: return "That file isn't an Aletheia encrypted backup."
            }
        }
    }

    /// Seals `source` into an encrypted archive at `destination`. The parent of
    /// `destination` must exist; any existing file there is replaced.
    static func create(from source: URL, to destination: URL, using key: SymmetricKey) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { throw ArchiveError.sourceMissing }
        // Seal to a temp file first, then move into place, so a crash mid-write
        // never leaves a truncated "backup" that looks valid.
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("backup-\(UUID().uuidString).\(fileExtension)")
        try ChunkedCipher.seal(fileAt: source, to: temp, using: key)
        try replaceItem(at: destination, with: temp)
    }

    /// Opens an encrypted archive at `source`, writing the recovered database to
    /// `destination`. Throws if `source` isn't a valid archive (wrong file, or a
    /// wrong/tampered key surfaces as a decryption error from `ChunkedCipher`).
    static func restore(from source: URL, to destination: URL, using key: SymmetricKey) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { throw ArchiveError.sourceMissing }
        guard ChunkedCipher.isEnvelope(fileAt: source) else { throw ArchiveError.notAnArchive }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("restore-\(UUID().uuidString).sqlite")
        try ChunkedCipher.open(fileAt: source, to: temp, using: key)
        try replaceItem(at: destination, with: temp)
    }

    /// True when `url` looks like one of our encrypted archives.
    static func isArchive(_ url: URL) -> Bool {
        url.pathExtension == fileExtension && ChunkedCipher.isEnvelope(fileAt: url)
    }

    // MARK: - Helpers

    /// Moves `replacement` onto `destination`, replacing any existing file, and
    /// creating the parent directory if needed.
    private static func replaceItem(at destination: URL, with replacement: URL) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: replacement)
        } else {
            try fm.moveItem(at: replacement, to: destination)
        }
    }
}
