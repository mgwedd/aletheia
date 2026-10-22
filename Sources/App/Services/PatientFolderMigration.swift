import Foundation

/// Schema v2 changes patient directory names without changing patient or
/// session identity. A retained copy of the original JSON makes the old layout
/// recoverable; all directory moves happen on the same volume.
enum PatientFolderMigration {
    enum Failure: Error {
        case duplicateIdentity
        case destinationExists
        case unreadableRecord
    }

    private struct Move {
        let source: URL
        let destination: URL
        let patient: Patient
    }

    /// Exposed so the upgrade and its rollback can be exercised with a real
    /// data folder. An interrupted run is safe to retry: a directory already
    /// under its UUID can still have a legacy `slug` inside patient.json.
    @discardableResult
    static func run(
        root: URL, protector: FileProtector, fileManager: FileManager = .default,
        beforeRewrite: ((URL) throws -> Void)? = nil
    ) throws -> URL? {
        let patientsRoot = root.appendingPathComponent("Patients", isDirectory: true)
        guard fileManager.fileExists(atPath: patientsRoot.path) else { return nil }
        let folders = try fileManager.contentsOfDirectory(
            at: patientsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var moves: [Move] = []
        var seen = Set<UUID>()
        let names = Set(folders.map(\.lastPathComponent))
        for folder in folders {
            let metadata = folder.appendingPathComponent("patient.json")
            guard fileManager.fileExists(atPath: metadata.path) else { continue }
            let patient: Patient
            do {
                patient = try JSONDecoder.aletheia.decode(Patient.self, from: protector.data(contentsOf: metadata))
            } catch {
                throw Failure.unreadableRecord
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
        guard !moves.isEmpty else { return nil }

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
                    try? fileManager.removeItem(at: live)
                    try? fileManager.copyItem(at: original, to: live)
                }
                if move.source.standardizedFileURL.path != move.destination.standardizedFileURL.path {
                    try? fileManager.moveItem(at: move.destination, to: move.source)
                }
            }
            throw error
        }
        return backup
    }
}
