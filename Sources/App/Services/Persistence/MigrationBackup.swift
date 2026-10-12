import Foundation

/// Pre-migration safety: before a schema upgrade transforms a clinician's data,
/// the database is snapshotted to a retained, versioned pre-image so a bad
/// migration is always recoverable. This type is the pure policy — *where* a
/// snapshot goes and *which* old snapshots may be pruned — while the core takes
/// the actual snapshot via `VACUUM INTO`.
///
/// The rule (see docs/DATA-SAFETY.md): **never migrate without a pre-image, and
/// never prune a pre-image until the clinician has attested the migrated data is
/// correct.** So snapshots are created here and kept indefinitely; pruning is a
/// separate, attestation-gated step the UI drives later via `prunable(_:...)`.
///
/// Snapshots live in `<dataRoot>/.backups/migrations/` (see `BackupLayout`, the
/// one place the backup layout is defined), so #91's system-backup exclusion
/// (applied to the whole data root) already covers them, and the same
/// encryption protector that seals live payloads sealed theirs. Older builds
/// used `<dataRoot>/Backups/`; `BackupLayout.adoptLegacy` moves those in.
enum MigrationBackup {
    static let fileExtension = "sqlite"
    /// Marker in a snapshot's file name, between the base name and the version.
    private static let marker = "-pre-v"

    /// The migration pre-image directory for a given database file (the data
    /// root is the database's parent folder). Pure — touches no disk.
    static func directory(for dbURL: URL) -> URL {
        BackupLayout.directory(.migrations, dataRoot: dbURL.deletingLastPathComponent())
    }

    /// Existing pre-migration snapshots for a database, newest first. Adopts any
    /// legacy `Backups/` folder first so an upgraded install sees its old
    /// pre-images. Files that aren't snapshots this type wrote are ignored.
    static func existing(for dbURL: URL, fileManager: FileManager = .default) -> [URL] {
        BackupLayout.adoptLegacy(dataRoot: dbURL.deletingLastPathComponent(), fileManager: fileManager)
        let entries = (try? fileManager.contentsOfDirectory(
            at: directory(for: dbURL), includingPropertiesForKeys: nil)) ?? []
        return entries
            .compactMap { url -> (url: URL, at: Date)? in
                metadata(of: url).map { (url, $0.createdAt) }
            }
            .sorted { $0.at > $1.at }
            .map(\.url)
    }

    /// Where to snapshot a database at `fromVersion` before upgrading it, or nil
    /// when there's nothing to protect: a brand-new or baseline database
    /// (`fromVersion <= 0`) holds no prior data a migration could corrupt, so no
    /// pre-image is taken.
    static func snapshotURL(forDatabaseAt dbURL: URL, fromVersion: Int, now: Date = Date()) -> URL? {
        guard fromVersion > 0 else { return nil }
        let base = dbURL.deletingPathExtension().lastPathComponent
        let name = "\(base)\(marker)\(fromVersion)-\(stamp(now)).\(fileExtension)"
        return directory(for: dbURL).appendingPathComponent(name)
    }

    /// Parses a snapshot file name back into the version it was taken *from* and
    /// when, or nil if the URL isn't a snapshot this type wrote. Robust to a base
    /// name that itself contains dashes (it anchors on the last `-pre-v`).
    static func metadata(of url: URL) -> (fromVersion: Int, createdAt: Date)? {
        let name = url.deletingPathExtension().lastPathComponent
        guard let range = name.range(of: marker, options: .backwards) else { return nil }
        let suffix = name[range.upperBound...]                 // "<version>-<stamp>"
        guard let dash = suffix.firstIndex(of: "-") else { return nil }
        guard let version = Int(suffix[..<dash]) else { return nil }
        guard let date = parseStamp(String(suffix[suffix.index(after: dash)...])) else { return nil }
        return (version, date)
    }

    /// Of the given snapshot URLs, the ones safe to delete: keep the
    /// `keepMostRecent` newest (by capture time) and return the rest for the
    /// caller to delete. Pure — it deletes nothing. Files it can't parse as
    /// snapshots are never returned, so unrelated files are safe in the folder.
    static func prunable(_ urls: [URL], keepMostRecent keep: Int) -> [URL] {
        let dated = urls.compactMap { url -> (url: URL, at: Date)? in
            metadata(of: url).map { (url, $0.createdAt) }
        }
        guard dated.count > max(0, keep) else { return [] }
        return dated
            .sorted { $0.at > $1.at }          // newest first
            .dropFirst(max(0, keep))           // keep the newest `keep`
            .map(\.url)
    }

    // MARK: - Structured JSON (patient.json / session.json)

    /// Sub-folder of the migrations folder that holds, per pre-image, a copy of
    /// the small structured JSON files. It has no `-pre-v` marker, so
    /// `existing`/`metadata`/`prunable` never mistake it for a snapshot.
    static let filesFolderName = "files"

    /// Where the JSON copy for a given database snapshot goes: a folder named
    /// after the snapshot, so the two are paired by name.
    ///
    /// ```
    /// .backups/migrations/Aletheia-pre-v2-<stamp>.sqlite
    /// .backups/migrations/files/Aletheia-pre-v2-<stamp>/Patients/<slug>/patient.json
    ///                                                   Patients/<slug>/<session>/session.json
    /// ```
    static func filesBundleURL(forSnapshot snapshot: URL) -> URL {
        snapshot.deletingLastPathComponent()
            .appendingPathComponent(filesFolderName, isDirectory: true)
            .appendingPathComponent(snapshot.deletingPathExtension().lastPathComponent, isDirectory: true)
    }

    /// Paths, relative to the data root, of every `patient.json` and
    /// `session.json`. Audio, transcripts and notes are never listed: a
    /// migration doesn't rewrite them, and copying them would make the pre-image
    /// expensive. Sorted for a stable result.
    static func structuredJSONFiles(inDataRoot dataRoot: URL, fileManager: FileManager = .default) -> [String] {
        let patientsRoot = dataRoot.appendingPathComponent("Patients", isDirectory: true)
        var found: [String] = []
        for patientDir in directories(in: patientsRoot, fileManager) {
            let patientName = patientDir.lastPathComponent
            if fileManager.fileExists(atPath: patientDir.appendingPathComponent("patient.json").path) {
                found.append("Patients/\(patientName)/patient.json")
            }
            for sessionDir in directories(in: patientDir, fileManager) {
                if fileManager.fileExists(atPath: sessionDir.appendingPathComponent("session.json").path) {
                    found.append("Patients/\(patientName)/\(sessionDir.lastPathComponent)/session.json")
                }
            }
        }
        return found.sorted()
    }

    /// Copies the structured JSON files into `bundle`, keeping their relative
    /// paths so a restore is a plain copy over the data folder. Refuses to write
    /// into a bundle that already exists (a pre-image is never overwritten) and
    /// removes a partly written bundle on failure. Returns how many files were copied.
    @discardableResult
    static func copyStructuredJSON(fromDataRoot dataRoot: URL, to bundle: URL, fileManager: FileManager = .default) throws -> Int {
        guard !fileManager.fileExists(atPath: bundle.path) else {
            throw CocoaError(.fileWriteFileExists)
        }
        let relativePaths = structuredJSONFiles(inDataRoot: dataRoot, fileManager: fileManager)
        do {
            try fileManager.createDirectory(at: bundle, withIntermediateDirectories: true)
            for relative in relativePaths {
                let destination = bundle.appendingPathComponent(relative)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fileManager.copyItem(at: dataRoot.appendingPathComponent(relative), to: destination)
            }
        } catch {
            try? fileManager.removeItem(at: bundle)
            throw error
        }
        return relativePaths.count
    }

    private static func directories(in url: URL, _ fileManager: FileManager) -> [URL] {
        let entries = (try? fileManager.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    // MARK: - Timestamp (filesystem-safe, sortable, UTC)

    static func stamp(_ date: Date) -> String { stampFormatter.string(from: date) }

    private static func parseStamp(_ s: String) -> Date? { stampFormatter.date(from: s) }

    private static let stampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return f
    }()
}
