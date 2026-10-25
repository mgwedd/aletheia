import CryptoKit
import Foundation

/// Restores an encrypted folder backup into a fresh or empty folder.
///
/// The key comes from the user's passphrase (or emergency recovery key): it opens the key wrapper kept
/// beside the archive (or, failing that, the one in the current data folder),
/// and that key opens the archive. A wrong passphrase, a wrong key wrapper, a
/// damaged or altered archive, or a folder that already holds files all end in
/// an error with nothing written. Existing data is never overwritten.
enum BackupRestore {
    enum Failure: LocalizedError, Equatable {
        case keyFileMissing
        case wrongPassphrase
        case folderNotAllowed(String)

        var errorDescription: String? {
            switch self {
            case .keyFileMissing:
                return "The key file for this backup wasn't found beside it. Keep the .aletheia-keystore.json file next to the backup."
            case .wrongPassphrase:
                return "That passphrase or recovery key doesn't open this backup."
            case .folderNotAllowed(let reason):
                return reason
            }
        }
    }

    /// Derives the archive key from `passphrase`.
    static func key(forArchive archive: URL, passphrase: String, fallbackKeystoreRoot: URL?) throws -> SymmetricKey {
        let beside = archive.deletingLastPathComponent()
        guard let keystore = Keystore.load(from: beside) ?? fallbackKeystoreRoot.flatMap({ Keystore.load(from: $0) }) else {
            throw Failure.keyFileMissing
        }
        do {
            return try keystore.unlock(passphrase: passphrase)
        } catch Keystore.KeystoreError.wrongPassphrase {
            // On a new Mac the emergency recovery key stands in for the passphrase.
            if keystore.hasRecoveryKey, let dek = try? keystore.unlock(recoveryKey: passphrase) { return dek }
            throw Failure.wrongPassphrase
        }
    }

    /// Restores `archive` into `destination` (missing or empty). `verdict` judges
    /// the destination (synced and network folders are refused).
    static func restore(
        archive: URL,
        passphrase: String,
        into destination: URL,
        fallbackKeystoreRoot: URL?,
        verdict: (URL) -> DataFolderPolicy.Verdict = { DataFolderPolicy.verdict(for: $0) }
    ) throws {
        let judged = verdict(destination)
        guard judged == .ok else { throw Failure.folderNotAllowed(judged.explanation) }
        try FolderBackupArchive.requireEmpty(destination)
        let key = try key(forArchive: archive, passphrase: passphrase, fallbackKeystoreRoot: fallbackKeystoreRoot)
        try FolderBackupArchive.restore(archive: archive, to: destination, using: key)
    }
}
