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
    /// Where the sealed archive goes (a folder on this Mac).
    let destination: BackupService
    private let fileManager = FileManager.default

    /// Snapshot-then-seal. `.notConfigured` if the destination isn't usable on
    /// this build, `.failed` if the snapshot or seal fails, else
    /// `.success(archiveURL)`. The temporary snapshot is always removed, even on
    /// failure — it's a plaintext-structured copy and shouldn't linger.
    func backUpNow(reason: String) async -> BackupOutcome {
        guard destination.isConfigured else { return .notConfigured }
        guard let temp = try? PrivateStaging.scratchFile(prefix: "aletheia-backup", ext: "sqlite") else {
            return .failed("Couldn't prepare a private folder for the snapshot.")
        }
        defer { PrivateStaging.remove(temp) }
        // The snapshot writer needs the path free; it creates the file itself.
        PrivateStaging.remove(temp)
        guard store.snapshot(to: temp) else {
            return .failed("Couldn't take a consistent snapshot of the database.")
        }
        return await destination.backUp(databaseURL: temp, reason: reason)
    }

    /// Restore the most recent archive over `databaseURL`.
    /// PRECONDITION: no store may be open on `databaseURL` — the caller closes it
    /// first and rebuilds afterwards.
    func restoreLatest(to databaseURL: URL) async -> BackupOutcome {
        await destination.restoreLatest(to: databaseURL)
    }
}
