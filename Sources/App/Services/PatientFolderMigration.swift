import Foundation

/// Schema v2 changes patient directory names without changing patient or
/// session identity. A retained copy of the original JSON makes the old layout
/// recoverable; all directory moves happen on the same volume.
enum PatientFolderMigration {
    enum Failure: Error {
        case duplicateIdentity
        case destinationExists
    }

    private struct Move {
        let source: URL
        let destination: URL
        let patient: Patient
    }

    struct Outcome: Equatable {
        /// The retained JSON pre-image, or nil when nothing needed to change.
        var backup: URL?
        /// Patient folders left exactly as they were because their
        /// `patient.json` can't be read or decoded. The listing still reports
        /// them as damaged; the migration is retried on the next open.
        var skippedUnreadable: Int
    }

    /// Exposed so the upgrade and its rollback can be exercised with a real
    /// data folder. An interrupted run is safe to retry: a directory already
    /// under its UUID can still have a legacy `slug` inside patient.json.
    /// Throws `FileProtector.ProtectorError.locked` before touching anything
    /// when a sealed record can't be read yet; the caller retries after unlock.
    @discardableResult
    static func run(
        root: URL, protector: FileProtector, fileManager: FileManager = .default,
        beforeRewrite: ((URL) throws -> Void)? = nil
    ) throws -> Outcome {
        let patientsRoot = root.appendingPathComponent("Patients", isDirectory: true)
        guard fileManager.fileExists(atPath: patientsRoot.path) else { return Outcome(backup: nil, skippedUnreadable: 0) }
        let folders = try fileManager.contentsOfDirectory(
            at: patientsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var moves: [Move] = []
        var seen = Set<UUID>()
        var skipped = 0
        let names = Set(folders.map(\.lastPathComponent))
        for folder in folders {
            let metadata = folder.appendingPathComponent("patient.json")
            guard fileManager.fileExists(atPath: metadata.path) else { continue }
            let patient: Patient
            do {
                patient = try JSONDecoder.aletheia.decode(Patient.self, from: protector.data(contentsOf: metadata))
            } catch FileProtector.ProtectorError.locked {
                throw FileProtector.ProtectorError.locked
            } catch {
                // A damaged record isn't a reason to hold back every other
                // patient. Leave this folder untouched under its current name.
                skipped += 1
                continue
            }
            guard seen.insert(patient.id).inserted else { throw Failure.duplicateIdentity }
            let destination = patientsRoot.appendingPathComponent(patient.id.uuidString, isDirectory: true)
            let needsMove = folder.standardizedFileURL.path != destination.standardizedFileURL.path
            if needsMove && names.contains(destination.lastPathComponent) {
                throw Failure.destinationExists
            }
            if needsMove || patient.slug != patient.id.uuidString {
                moves.append(Move(source: folder, destination: destination, patient: patient))
            }
        }
        guard !moves.isEmpty else { return Outcome(backup: nil, skippedUnreadable: skipped) }

        // This is a file-only migration: the SQLite database keys by UUID and
        // needs no rewrite. Keep the JSON pre-image in MigrationBackup's files
        // directory; never copy audio or transcripts into a second plaintext copy.
        let name = "patient-folders-pre-v1-\(MigrationBackup.stamp(Date()))-\(UUID().uuidString)"
        let backup = BackupLayout.directory(.migrations, dataRoot: root)
            .appendingPathComponent(MigrationBackup.filesFolderName, isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try MigrationBackup.copyStructuredJSON(fromDataRoot: root, to: backup, fileManager: fileManager)

        var moved: [Move] = []
        do {
            for move in moves {
                if move.source.standardizedFileURL.path != move.destination.standardizedFileURL.path {
                    // Check again just before moving, in case another process
                    // created the target after preflight.
                    guard !fileManager.fileExists(atPath: move.destination.path) else {
                        throw Failure.destinationExists
                    }
                    try fileManager.moveItem(at: move.source, to: move.destination)
                }
                moved.append(move)
                try beforeRewrite?(move.destination)
                let old = move.patient
                let updated = Patient(
                    id: old.id, name: old.name, notes: old.notes,
                    createdAt: old.createdAt, slug: old.id.uuidString,
                    clinicalHistory: old.clinicalHistory, medications: old.medications)
                try protector.write(JSONEncoder.aletheia.encode(updated),
                                    to: move.destination.appendingPathComponent("patient.json"))
            }
        } catch {
            // Restore bytes before renaming back, so even a failed write never
            // leaves a partly upgraded identity file in the old directory.
            for move in moved.reversed() {
                let relative = "Patients/\(move.source.lastPathComponent)/patient.json"
                let original = backup.appendingPathComponent(relative)
                let live = move.destination.appendingPathComponent("patient.json")
                if fileManager.fileExists(atPath: original.path) {
                    // Copy beside the live file, then swap it in, so a failed
                    // copy never leaves the folder without its identity file.
                    let staged = live.deletingLastPathComponent()
                        .appendingPathComponent(".patient.json.restore-\(UUID().uuidString)")
                    if (try? fileManager.copyItem(at: original, to: staged)) != nil {
                        let swapped = fileManager.fileExists(atPath: live.path)
                            ? (try? fileManager.replaceItemAt(live, withItemAt: staged)) != nil
                            : (try? fileManager.moveItem(at: staged, to: live)) != nil
                        if !swapped { try? fileManager.removeItem(at: staged) }
                    }
                }
                if move.source.standardizedFileURL.path != move.destination.standardizedFileURL.path {
                    try? fileManager.moveItem(at: move.destination, to: move.source)
                }
            }
            throw error
        }
        return Outcome(backup: backup, skippedUnreadable: skipped)
    }
}
