import Foundation

/// Produces a **consistent** encrypted backup: take a point-in-time snapshot of
/// the live database (SQLite `VACUUM INTO`, safe to run while the store is open),
/// then seal *that snapshot* into the destination's archive — never the live
/// file, which another connection may be mid-write on.
///
/// ```
/// live store ──VACUUM INTO──▶ temp snapshot ──seal(key)──▶ .aletheiabackup
///  (open OK)                  (consistent)     BackupService   destination
///                                   └── deleted after sealing ──┘
/// ```
///
/// This composes the existing snapshot primitive (`CommentStore.snapshot(to:)`)
/// with a `BackupService` destination, so "Back up now" always captures a
/// coherent whole. Restore is delegated to the destination unchanged (unseal →
/// atomic replace) and keeps its "no open store on the target" precondition.
struct BackupCoordinator {
    /// The live, open store the backup is taken from.
    let store: CommentStore
    /// Where the sealed archive goes (local folder today; iCloud once #60 lands).
    let destination: BackupService
    private let fileManager = FileManager.default

    /// Snapshot-then-seal. `.notConfigured` if the destination isn't usable on
    /// this build, `.failed` if the snapshot or seal fails, else
    /// `.success(archiveURL)`. The temporary snapshot is always removed, even on
    /// failure — it's a plaintext-structured copy and shouldn't linger.
    func backUpNow(reason: String) async -> BackupOutcome {
        guard destination.isConfigured else { return .notConfigured }
        let temp = fileManager.temporaryDirectory
            .appendingPathComponent("aletheia-backup-\(UUID().uuidString).sqlite")
        guard store.snapshot(to: temp) else {
            return .failed("Couldn't take a consistent snapshot of the database.")
        }
        defer { try? fileManager.removeItem(at: temp) }
        return await destination.backUp(databaseURL: temp, reason: reason)
    }

    /// Restore the most recent archive over `databaseURL`.
    /// PRECONDITION: no store may be open on `databaseURL` — the caller closes it
    /// first and rebuilds afterwards.
    func restoreLatest(to databaseURL: URL) async -> BackupOutcome {
        await destination.restoreLatest(to: databaseURL)
    }
}
