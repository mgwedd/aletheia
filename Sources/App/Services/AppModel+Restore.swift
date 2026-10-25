import Foundation

extension AppModel {
    /// Restores an encrypted backup into `folder` (missing or empty), then opens
    /// that folder as the data folder and records the restore in its log. The
    /// folder you were using is left exactly as it was. Nothing is recorded when
    /// the restore is refused or fails.
    func restoreBackup(archive: URL, passphrase: String, into folder: URL) async -> BackupOutcome {
        let fallback = settings.dataRootURL
        let verdict = backupFolderVerdict
        do {
            try await Task.detached(priority: .userInitiated) {
                try BackupRestore.restore(
                    archive: archive,
                    passphrase: passphrase,
                    into: folder,
                    fallbackKeystoreRoot: fallback,
                    verdict: verdict
                )
            }.value
        } catch {
            return .failed(error.localizedDescription)
        }
        do {
            try settings.setDataRoot(folder)
        } catch {
            return .failed("The backup was restored to \(folder.lastPathComponent), but it couldn't be opened: \(error.localizedDescription)")
        }
        rebuildStore()
        if (try? encryption.unlock(passphrase: passphrase)) == nil {
            try? encryption.unlock(recoveryKey: passphrase)
        }
        rebuildStore()
        recordAudit(.backupRestored)
        return .success(folder)
    }
}
