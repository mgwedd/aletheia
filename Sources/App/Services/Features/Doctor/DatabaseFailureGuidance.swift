import Foundation

/// Plain-language guidance for a database that won't open: what's wrong, and
/// numbered steps to diagnose it, specific to the kind of failure.
///
/// The ordering rule is **never destructive first**: every list starts with
/// something safe (look, update, free space, or copy the folder aside), and
/// nothing here ever tells the therapist to delete, reset or re-create the data
/// folder or database. Restoring from a snapshot is always "rename the damaged
/// file, copy the snapshot in", never "delete".
///
/// Pure data in, strings out — unit-tested without a Mac.
struct DatabaseGuidance: Equatable {
    /// The one-line error, the same for every kind.
    let headline: String
    /// What has gone wrong, in plain words.
    let explanation: String
    /// Numbered diagnosing steps (rendered as 1., 2., …; the text has no numbers).
    let steps: [String]
    /// A single sentence for the Doctor check's "next step".
    let shortNextStep: String
}

enum DatabaseFailureGuidance {
    static let headline = "Notes and chat can't be saved right now"

    /// Names used in the steps, so they match what's really on disk.
    static let databaseFileName = "Aletheia.sqlite"
    static let snapshotsFolderName = ".snapshots"
    static let preUpgradeFolderName = MigrationBackup.directoryName   // "Backups"

    /// - Parameter dataFolder: the chosen data folder's path, shown on screen so
    ///   the steps can point at the real location (nil if none is known).
    static func guidance(for failure: DatabaseOpenFailure, dataFolder: String?) -> DatabaseGuidance {
        let folder = dataFolder ?? "your Aletheia data folder"
        switch failure.kind {
        case .schemaNewerThanApp:
            return DatabaseGuidance(
                headline: headline,
                explanation: "This data was last used by a newer version of Aletheia than the one that's running. Aletheia is deliberately not opening it, so an older version can't damage it. Nothing has been lost.",
                steps: [
                    "Don't change anything in the data folder.",
                    "Update Aletheia: choose Aletheia > Check for Updates… in the menu bar.",
                    "Quit and reopen Aletheia. The notes come back on their own once the app is new enough.",
                    "If you recently installed an older copy of Aletheia over a newer one, install the newer one again rather than switching back.",
                    "Still stuck? Open Aletheia Doctor and copy the report."
                ],
                shortNextStep: "Update Aletheia (Aletheia > Check for Updates…), then reopen it. Nothing has been lost."
            )

        case .cannotOpen:
            return DatabaseGuidance(
                headline: headline,
                explanation: "Aletheia couldn't open its database file. The folder may have moved, be on a drive that isn't connected, or not be readable and writable by your account.",
                steps: [
                    "Check that the data folder is where Aletheia expects it: \(folder). If it's on an external or network drive, reconnect the drive and wait for it to appear in Finder.",
                    "In Finder, select the folder and choose File > Get Info. Under Sharing & Permissions your account should have Read & Write.",
                    "If you moved or renamed the folder, open Settings and choose it again under Data Folder.",
                    "Quit and reopen Aletheia.",
                    "Open Aletheia Doctor to see exactly which check fails."
                ],
                shortNextStep: "Check the data folder is present and that your account can read and write it, then reopen Aletheia."
            )

        case .lockedOrDiskFull:
            return DatabaseGuidance(
                headline: headline,
                explanation: "Aletheia's database is locked by another program, the disk is full, or the disk reported an error. Nothing has been deleted.",
                steps: [
                    "Free up disk space: open System Settings > General > Storage and empty the Trash. A few free gigabytes is plenty.",
                    "Make sure no other program is using the data folder — quit any second copy of Aletheia, and pause sync or backup tools (iCloud Drive, Dropbox and similar) if the folder is inside one.",
                    "Quit and reopen Aletheia.",
                    "If it happens again, run First Aid on the disk in Disk Utility to check it for errors.",
                    "Before trying anything further, copy the whole data folder aside (Finder > right-click the folder > Duplicate)."
                ],
                shortNextStep: "Free up disk space and close any other program using the data folder, then reopen Aletheia."
            )

        case .migrationRefused:
            return DatabaseGuidance(
                headline: headline,
                explanation: "After an update, Aletheia has to upgrade its database, and it always saves a safety copy first. It couldn't write that copy, so it stopped without touching your data. Nothing has been lost.",
                steps: [
                    "Free up disk space — the safety copy is about the size of \(databaseFileName). Open System Settings > General > Storage and empty the Trash.",
                    "Check that your account can write to the data folder: \(folder). In Finder, File > Get Info, then Sharing & Permissions.",
                    "Quit and reopen Aletheia. The upgrade is retried on every launch.",
                    "For extra safety, copy the whole data folder aside first (Finder > right-click the folder > Duplicate).",
                    "Open Aletheia Doctor to check free space and folder access."
                ],
                shortNextStep: "Free up disk space and make sure the data folder is writable, then reopen Aletheia. Your data has not been changed."
            )

        case .migrationFailed:
            return DatabaseGuidance(
                headline: headline,
                explanation: "Aletheia tried to upgrade its database after an update and the upgrade failed. It was rolled back, so your data should be exactly as it was, and a safety copy from just before the upgrade is kept.",
                steps: withRestoreSteps(folder: folder, head: [
                    "Quit Aletheia and copy the whole data folder aside (Finder > right-click the folder > Duplicate) before trying anything else.",
                    "Reopen Aletheia once. If the message is still there, check for a newer version (Aletheia > Check for Updates…) — a fix may be available.",
                    "The pre-upgrade safety copy is in the \(preUpgradeFolderName) folder inside the data folder: \(folder). See the restore steps below only if the database is later reported as damaged."
                ], tail: [
                    "Open Aletheia Doctor and copy the report if you need help."
                ]),
                shortNextStep: "Copy the data folder aside, then reopen Aletheia or check for an update. A safety copy from before the upgrade is kept."
            )

        case .corrupt:
            return DatabaseGuidance(
                headline: headline,
                explanation: "The database file looks damaged. Aletheia will not overwrite or delete it, so anything still readable in it may be recoverable. Your transcripts, summaries and recordings are separate files and are not affected.",
                steps: withRestoreSteps(folder: folder, head: [
                    "Do not delete, move or \"clean up\" anything in the data folder, including \(databaseFileName). A damaged file can often still be recovered.",
                    "Quit Aletheia and copy the whole data folder aside (Finder > right-click the folder > Duplicate) to your Desktop or another drive. Do this before anything else."
                ], tail: [
                    "Open Aletheia Doctor and copy the report if you need help."
                ]),
                shortNextStep: "Don't delete anything. Copy the data folder aside, then restore the newest snapshot as described in the error steps."
            )

        case .unknown:
            return DatabaseGuidance(
                headline: headline,
                explanation: "Aletheia couldn't open its database for a reason it doesn't recognise. Nothing has been deleted.",
                steps: withRestoreSteps(folder: folder, head: [
                    "Don't delete or move anything in the data folder.",
                    "Quit Aletheia and copy the whole data folder aside (Finder > right-click the folder > Duplicate).",
                    "Reopen Aletheia. If the message is still there, check for a newer version (Aletheia > Check for Updates…)."
                ], tail: [
                    "Open Aletheia Doctor and copy the report if you need help."
                ]),
                shortNextStep: "Don't delete anything. Copy the data folder aside, then reopen Aletheia or check for an update."
            )
        }
    }

    /// `head` steps, then the manual-restore steps, then any `tail` steps.
    private static func withRestoreSteps(folder: String, head: [String], tail: [String] = []) -> [String] {
        var steps = head
        steps.append(contentsOf: restoreSteps(folder: folder))
        steps.append(contentsOf: tail)
        return steps
    }

    /// Where the data folder is and how to restore from a snapshot by hand.
    /// Renames, never deletes; copies, never moves.
    private static func restoreSteps(folder: String) -> [String] {
        [
            "Find a snapshot. Aletheia keeps safety copies of the database in two hidden folders inside the data folder (\(folder)): \(snapshotsFolderName) (taken before updates and encryption changes) and \(preUpgradeFolderName) (taken before database upgrades). In Finder press Command-Shift-. (period) to show hidden folders. The newest .sqlite file is the most recent copy.",
            "To restore by hand — only after you've copied the whole folder aside and with Aletheia quit: rename \(databaseFileName) to Aletheia-damaged.sqlite (rename it, don't delete it), copy the snapshot into the data folder (copy, don't move), and rename the copy to \(databaseFileName). Then reopen Aletheia. Notes written after that snapshot was taken won't be in it, which is why the damaged file is kept.",
            "If you also keep another backup of this folder (an encrypted backup from Settings, an external drive, or Time Machine if you've included it), restoring \(databaseFileName) from there works the same way."
        ]
    }
}
