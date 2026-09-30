import Foundation

/// Runs the Doctor checks against injected probes and assembles a
/// `DoctorReport`. All the *judgement* (what counts as ok, a warning or a
/// problem, and what to tell the therapist) lives here as pure functions of probe
/// values; all the I/O lives behind `DoctorProbing`. So the whole thing is unit
/// tested with stub probes — no real disk, SQLite database or Ollama needed.
///
/// ```
///   probes ─▶ dataFolderChecks ─┐
///           ─▶ databaseChecks ──┤   (folder-dependent checks are skipped
///           ─▶ keystoreChecks ──┤    when there's no usable data folder)
///           ─▶ snapshotChecks ──┼─▶ DoctorReport
///           ─▶ recordChecks ────┤
///           ─▶ whisperChecks ───┤
///           ─▶ ToolHealth rows ─┘   (reused, not re-implemented)
/// ```
struct DoctorRunner {
    let probes: DoctorProbing

    /// Below this much free space on the data folder's volume, saving is likely to
    /// fail: a problem.
    static let lowDiskFailedBytes: Int64 = 100 * 1024 * 1024
    /// Below this, it's worth freeing space soon: a warning.
    static let lowDiskWarningBytes: Int64 = 1024 * 1024 * 1024

    func run() async -> DoctorReport {
        let environment = probes.environment()
        let now = probes.now()
        var checks: [DoctorCheck] = []

        let folder = probes.dataFolder()
        checks += Self.dataFolderChecks(folder)

        // Everything that lives *in* the data folder only makes sense once the
        // folder itself is there.
        if folder.path != nil, folder.exists, folder.isDirectory {
            checks += Self.databaseChecks(
                probes.database(),
                supportedSchemaVersion: environment.supportedSchemaVersion,
                dataFolder: folder.path
            )
            checks += Self.keystoreChecks(probes.keystore())
            checks += Self.snapshotChecks(probes.snapshots(), now: now)
            checks += Self.recordChecks(probes.unreadableEntries())
        }

        checks += Self.whisperChecks(file: probes.whisperModelFile(), digest: probes.whisperModelDigest())
        let toolHealth = await probes.toolHealthChecks()
        checks += Self.toolChecks(toolHealth)

        return DoctorReport(checks: checks, generatedAt: now, environment: environment)
    }

    // MARK: - Data folder

    static func dataFolderChecks(_ probe: DataFolderProbe) -> [DoctorCheck] {
        guard let path = probe.path else {
            return [DoctorCheck(
                id: "dataFolder.present", category: .dataFolder, title: "Data folder chosen",
                status: .failed,
                detail: "No data folder has been chosen, so nothing can be saved.",
                nextStep: "Open Settings and choose a data folder."
            )]
        }
        guard probe.exists, probe.isDirectory else {
            let what = probe.exists ? "is a file rather than a folder" : "can't be found"
            return [DoctorCheck(
                id: "dataFolder.present", category: .dataFolder, title: "Data folder present",
                status: .failed,
                detail: "The data folder \(what): \(path)",
                nextStep: "If it's on an external or network drive, reconnect it. If you moved or renamed it, choose it again under Settings > Data Folder. Don't create a new empty folder in its place."
            )]
        }

        var checks = [DoctorCheck(
            id: "dataFolder.present", category: .dataFolder, title: "Data folder present",
            status: .ok, detail: "Found at \(path)."
        )]

        switch (probe.readable, probe.writable) {
        case (true, true):
            checks.append(DoctorCheck(
                id: "dataFolder.access", category: .dataFolder, title: "Data folder readable and writable",
                status: .ok, detail: "Aletheia can read and write the data folder."
            ))
        case (true, false):
            checks.append(DoctorCheck(
                id: "dataFolder.access", category: .dataFolder, title: "Data folder readable and writable",
                status: .failed,
                detail: "Aletheia can read the data folder but not write to it, so new notes and chat can't be saved.",
                nextStep: "In Finder, select the folder, choose File > Get Info, and give your account Read & Write under Sharing & Permissions. Check the drive isn't read-only or locked."
            ))
        default:
            checks.append(DoctorCheck(
                id: "dataFolder.access", category: .dataFolder, title: "Data folder readable and writable",
                status: .failed,
                detail: "Aletheia can't read the data folder.",
                nextStep: "In Finder, select the folder, choose File > Get Info, and give your account Read & Write under Sharing & Permissions."
            ))
        }

        checks.append(freeSpaceCheck(probe.freeBytes))
        return checks
    }

    /// Pure mapping from free bytes to a check row.
    static func freeSpaceCheck(_ freeBytes: Int64?) -> DoctorCheck {
        guard let free = freeBytes else {
            return DoctorCheck(
                id: "dataFolder.space", category: .dataFolder, title: "Free disk space",
                status: .warning,
                detail: "Couldn't read how much space is free on the data folder's disk."
            )
        }
        let amount = ByteCountFormatter.string(fromByteCount: free, countStyle: .file)
        if free < lowDiskFailedBytes {
            return DoctorCheck(
                id: "dataFolder.space", category: .dataFolder, title: "Free disk space",
                status: .failed,
                detail: "Only \(amount) free — saving is likely to fail.",
                nextStep: "Free up space: open System Settings > General > Storage and empty the Trash."
            )
        }
        if free < lowDiskWarningBytes {
            return DoctorCheck(
                id: "dataFolder.space", category: .dataFolder, title: "Free disk space",
                status: .warning,
                detail: "\(amount) free — getting low.",
                nextStep: "Free up some space soon: open System Settings > General > Storage."
            )
        }
        return DoctorCheck(
            id: "dataFolder.space", category: .dataFolder, title: "Free disk space",
            status: .ok, detail: "\(amount) free."
        )
    }

    // MARK: - Database

    static func databaseChecks(_ probe: DatabaseProbe, supportedSchemaVersion: Int, dataFolder: String?) -> [DoctorCheck] {
        var checks: [DoctorCheck] = []
        let inspection = probe.inspection

        // 1. Does it open?
        if let failure = probe.appFailure ?? inspection.failure {
            let guidance = DatabaseFailureGuidance.guidance(for: failure, dataFolder: dataFolder)
            checks.append(DoctorCheck(
                id: "database.open", category: .database, title: "Database opens",
                status: .failed,
                detail: "Aletheia can't open its database, so notes and chat can't be saved. \(kindDescription(failure.kind)) (\(failure.reason))",
                nextStep: guidance.shortNextStep
            ))
        } else if !inspection.fileExists {
            checks.append(DoctorCheck(
                id: "database.open", category: .database, title: "Database opens",
                status: .warning,
                detail: "The database file doesn't exist yet. It's created automatically when Aletheia opens this folder.",
                nextStep: "Quit and reopen Aletheia."
            ))
        } else {
            checks.append(DoctorCheck(
                id: "database.open", category: .database, title: "Database opens",
                status: .ok, detail: "Aletheia's database opens normally."
            ))
        }

        // 2. Schema version vs this build.
        if let version = inspection.schemaVersion {
            if version > supportedSchemaVersion {
                checks.append(DoctorCheck(
                    id: "database.schema", category: .database, title: "Database format",
                    status: .failed,
                    detail: "Database format v\(version) is newer than this version of Aletheia understands (v\(supportedSchemaVersion)).",
                    nextStep: "Update Aletheia (Aletheia > Check for Updates…). Nothing has been lost."
                ))
            } else if version < supportedSchemaVersion {
                checks.append(DoctorCheck(
                    id: "database.schema", category: .database, title: "Database format",
                    status: .warning,
                    detail: "Database format v\(version) is older than this version (v\(supportedSchemaVersion)); it's upgraded when Aletheia opens it.",
                    nextStep: "Quit and reopen Aletheia. A safety copy is saved before any upgrade."
                ))
            } else {
                checks.append(DoctorCheck(
                    id: "database.schema", category: .database, title: "Database format",
                    status: .ok, detail: "Database format v\(version), which this version of Aletheia supports."
                ))
            }
        }

        // 3. Integrity (count only — the messages name tables and pages).
        switch inspection.integrity {
        case .ok:
            checks.append(DoctorCheck(
                id: "database.integrity", category: .database, title: "Database integrity",
                status: .ok, detail: "SQLite's integrity check passed."
            ))
        case .problems(let count):
            checks.append(DoctorCheck(
                id: "database.integrity", category: .database, title: "Database integrity",
                status: .failed,
                detail: "SQLite's integrity check reported \(count) problem\(count == 1 ? "" : "s") in the database file.",
                nextStep: "Don't delete anything. Quit Aletheia, copy the whole data folder aside, then restore the newest file from the \(DatabaseFailureGuidance.snapshotsFolderName) or \(DatabaseFailureGuidance.preUpgradeFolderName) folder inside it: rename \(DatabaseFailureGuidance.databaseFileName) (don't delete it), copy the snapshot in, and rename the copy to \(DatabaseFailureGuidance.databaseFileName)."
            ))
        case .notRun:
            // If the file is missing or wouldn't open, that's already reported
            // above; only flag a check that couldn't run for no visible reason.
            if inspection.fileExists && probe.appFailure == nil && inspection.failure == nil {
                checks.append(DoctorCheck(
                    id: "database.integrity", category: .database, title: "Database integrity",
                    status: .warning, detail: "The integrity check couldn't be run."
                ))
            }
        }
        return checks
    }

    /// Plain-language name for a failure kind, for the Doctor detail line.
    static func kindDescription(_ kind: DatabaseOpenFailure.Kind) -> String {
        switch kind {
        case .cannotOpen: return "The file couldn't be opened (missing folder, permissions, or a drive that isn't connected)."
        case .lockedOrDiskFull: return "The database is locked by another program, the disk is full, or the disk reported an error."
        case .schemaNewerThanApp: return "The data was written by a newer version of Aletheia."
        case .migrationRefused: return "A database upgrade was stopped because its safety copy couldn't be written."
        case .migrationFailed: return "A database upgrade failed and was rolled back."
        case .corrupt: return "The database file looks damaged."
        case .unknown: return "The database couldn't be opened for an unrecognised reason."
        }
    }

    // MARK: - Encryption

    static func keystoreChecks(_ probe: KeystoreProbe) -> [DoctorCheck] {
        switch probe {
        case .notInUse:
            return []   // nothing to check when encryption isn't in use
        case .present(let unlocked):
            return [DoctorCheck(
                id: "encryption.keystore", category: .encryption, title: "Encryption keystore",
                status: .ok,
                detail: unlocked
                    ? "The keystore is present and unlocked."
                    : "The keystore is present. Enter your passphrase in Aletheia to unlock your notes."
            )]
        case .unreadable:
            return [DoctorCheck(
                id: "encryption.keystore", category: .encryption, title: "Encryption keystore",
                status: .failed,
                detail: "This folder uses encryption but its keystore file can't be read. Without it the encrypted notes can't be opened.",
                nextStep: "Don't delete or move anything. Restore the keystore file (.aletheia-keystore.json) from a backup of the data folder if you have one."
            )]
        }
    }

    // MARK: - Snapshots & backups

    static func snapshotChecks(_ probe: SnapshotProbe, now: Date) -> [DoctorCheck] {
        guard probe.totalCount > 0, let newest = probe.newest else {
            // Snapshots are taken before updates that change the database and before
            // encryption changes, so a fresh install legitimately has none.
            return [DoctorCheck(
                id: "backups.snapshots", category: .backups, title: "Database snapshots",
                status: .ok,
                detail: "No snapshots yet. Aletheia saves one before an update changes the database and before encryption changes — that's normal until one has happened."
            )]
        }
        let noun = probe.totalCount == 1 ? "snapshot" : "snapshots"
        return [DoctorCheck(
            id: "backups.snapshots", category: .backups, title: "Database snapshots",
            status: .ok,
            detail: "\(probe.totalCount) \(noun) kept; the newest is \(age(of: newest, now: now))."
        )]
    }

    /// "less than a day old", "1 day old", "12 days old".
    static func age(of date: Date, now: Date) -> String {
        let days = Int(max(0, now.timeIntervalSince(date)) / 86_400)
        switch days {
        case 0: return "less than a day old"
        case 1: return "1 day old"
        default: return "\(days) days old"
        }
    }

    // MARK: - Records

    static func recordChecks(_ probe: UnreadableEntriesProbe) -> [DoctorCheck] {
        switch probe {
        case .notAvailable:
            return []   // not reported until the Store API lands; see UnreadableEntriesProbe
        case .count(let count) where count == 0:
            return [DoctorCheck(
                id: "records.unreadable", category: .records, title: "Patient and session records",
                status: .ok, detail: "Every patient and session record on disk could be read."
            )]
        case .count(let count):
            return [DoctorCheck(
                id: "records.unreadable", category: .records, title: "Patient and session records",
                status: .failed,
                detail: "\(count) patient or session record\(count == 1 ? "" : "s") on disk couldn't be read, so \(count == 1 ? "it" : "they") may be missing from your lists.",
                nextStep: "Don't delete or edit anything. Copy the whole data folder aside first; the unreadable records are still on disk and can often be repaired."
            )]
        }
    }

    // MARK: - Transcription model

    static func whisperChecks(file: WhisperModelFileProbe, digest: WhisperDigestProbe) -> [DoctorCheck] {
        // A missing model file is already reported by the reused ToolHealth
        // "Transcription model" row; this adds what that row doesn't check.
        guard file.exists else { return [] }
        var checks: [DoctorCheck] = []

        let expected = Int64(file.expectedMB) * 1_048_576
        let redownload = "Re-download it in Settings > Speech-to-Text Model."
        if let size = file.sizeBytes {
            let amount = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            if size == 0 {
                checks.append(DoctorCheck(
                    id: "tools.whisperFile", category: .tools, title: "Transcription model file",
                    status: .failed, detail: "The model file is empty — the download was probably interrupted.",
                    nextStep: redownload
                ))
            } else if size < expected / 2 {
                checks.append(DoctorCheck(
                    id: "tools.whisperFile", category: .tools, title: "Transcription model file",
                    status: .failed,
                    detail: "The model file is \(amount), much smaller than the expected \(file.expectedMB) MB — the download was probably interrupted.",
                    nextStep: redownload
                ))
            } else if size > expected * 2 {
                checks.append(DoctorCheck(
                    id: "tools.whisperFile", category: .tools, title: "Transcription model file",
                    status: .warning,
                    detail: "The model file is \(amount), much larger than the expected \(file.expectedMB) MB.",
                    nextStep: redownload
                ))
            } else {
                checks.append(DoctorCheck(
                    id: "tools.whisperFile", category: .tools, title: "Transcription model file",
                    status: .ok, detail: "Present, \(amount) — a sensible size for this model."
                ))
            }
        }

        // The pinned-digest comparison (`WhisperModelPins`); omitted when the digest
        // couldn't be computed.
        switch digest {
        case .unavailable:
            break
        case .matches:
            checks.append(DoctorCheck(
                id: "tools.whisperDigest", category: .tools, title: "Transcription model integrity",
                status: .ok, detail: "The model file's SHA-256 matches the pinned value."
            ))
        case .mismatch:
            checks.append(DoctorCheck(
                id: "tools.whisperDigest", category: .tools, title: "Transcription model integrity",
                status: .failed,
                detail: "The model file's SHA-256 doesn't match the pinned value — it may be corrupted or altered.",
                nextStep: redownload
            ))
        }
        return checks
    }

    // MARK: - Reused ToolHealth rows

    /// Turns the existing setup checks into Doctor rows. The data-folder row is
    /// dropped because Doctor has its own, richer data-folder checks.
    static func toolChecks(_ toolChecks: [ToolHealthCheck]) -> [DoctorCheck] {
        toolChecks
            .filter { $0.kind != .dataFolder }
            .map(doctorCheck(from:))
    }

    static func doctorCheck(from tool: ToolHealthCheck) -> DoctorCheck {
        let status: DoctorStatus
        switch tool.status {
        case .ok: status = .ok
        case .warning: status = .warning
        case .failed: status = .failed
        }
        var next: String?
        if status != .ok, let action = Setup.action(for: tool) {
            next = "In Settings > Setup Assistant, use “\(action.label)”."
        }
        return DoctorCheck(
            id: "tools.\(tool.kind)", category: .tools, title: tool.title,
            status: status, detail: tool.detail, nextStep: next
        )
    }
}
