import Foundation

/// One patient in an all-records export: what the layout needs before any
/// session is read.
struct AllRecordsPatient: Equatable {
    var name: String
    var background: String
    var sessionCount: Int
}

/// A recording found for a session, by the name it gets in the export.
struct AllRecordsRecording: Equatable {
    var name: String
    var url: URL
}

/// Where an all-records export reads from. `Store` backs it in the app; tests
/// pass a fake. Called off the main actor.
protocol AllRecordsSource {
    var patients: [AllRecordsPatient] { get }
    /// Patient records that couldn't be read, so aren't in the export.
    var unreadablePatientCount: Int { get }
    /// Session records that couldn't be read, so aren't in the export.
    var unreadableSessionCount: Int { get }
    func loadSession(patient: Int, session: Int) throws -> ArchiveSession
    /// Recordings on disk for the session, if any.
    func recordings(patient: Int, session: Int) -> [AllRecordsRecording]
    /// A readable copy of a recording; a temporary copy is the caller's to move or delete.
    func readableRecording(at url: URL) throws -> (url: URL, isTemporary: Bool)
}

/// Reads every patient and session from a `Store`.
struct StoreAllRecordsSource: AllRecordsSource {
    let store: Store
    let patients: [AllRecordsPatient]
    let unreadablePatientCount: Int
    let unreadableSessionCount: Int
    private let records: [(patient: Patient, sessions: [SessionRecord])]

    /// Throws `ProtectorError.locked` while the folder is locked: a locked store
    /// lists no patients, which must not pass for an empty export.
    init(store: Store) throws {
        if store.isLocked { throw FileProtector.ProtectorError.locked }
        let listing = try store.patientListing()
        var records: [(patient: Patient, sessions: [SessionRecord])] = []
        var unreadableSessions = 0
        for patient in listing.patients {
            let sessions = try store.sessionListing(for: patient)
            records.append((patient, sessions.sessions))
            unreadableSessions += sessions.unreadable.count
        }
        self.unreadableSessionCount = unreadableSessions
        self.store = store
        self.records = records
        self.patients = records.map {
            AllRecordsPatient(name: $0.patient.name, background: $0.patient.notes, sessionCount: $0.sessions.count)
        }
        self.unreadablePatientCount = listing.unreadable.count
    }

    func loadSession(patient: Int, session: Int) throws -> ArchiveSession {
        try ArchiveLoader.load(store: store, patient: records[patient].patient, session: records[patient].sessions[session])
    }

    func recordings(patient: Int, session: Int) -> [AllRecordsRecording] {
        let record = records[patient]
        let session = record.sessions[session]
        return [
            AllRecordsRecording(name: AllRecordsExport.micRecordingName, url: store.micRecordingURL(for: record.patient, session: session)),
            AllRecordsRecording(name: AllRecordsExport.callRecordingName, url: store.callRecordingURL(for: record.patient, session: session)),
        ].filter { FileManager.default.fileExists(atPath: $0.url.path) }
    }

    func readableRecording(at url: URL) throws -> (url: URL, isTemporary: Bool) {
        try store.readableRecording(at: url)
    }
}

/// Every patient's records as a folder of ordinary files, for keeping or for
/// leaving Aletheia. It needs no license key. The folder is written beside its
/// final name and renamed when complete, so a cancelled or failed export leaves
/// nothing behind.
///
///     Aletheia records 2026-10-23/
///       Read me.txt
///       Jane Doe records/            (the per-patient layout, see PatientArchive)
///         Sessions/2026-09-16 14.30/
///           Transcript.txt
///           Recording - microphone.caf
enum AllRecordsExport {
    static let micRecordingName = "Recording - microphone.caf"
    static let callRecordingName = "Recording - call.caf"

    /// "Aletheia records 2026-10-23", made unique among `existing` names.
    static func folderName(exportedOn: Date, existing: Set<String>) -> String {
        var taken = Set(existing.map { $0.lowercased() })
        return PatientArchive.uniqueName("Aletheia records \(dayFormatter.string(from: exportedOn))", taken: &taken)
    }

    /// Each patient's top folder, unique even when two patients share a name.
    static func patientFolders(_ patients: [AllRecordsPatient]) -> [String] {
        var taken = Set<String>()
        return patients.map { PatientArchive.uniqueName(PatientArchive.defaultRootName(patientName: $0.name), taken: &taken) }
    }

    /// The records would be copied off this Mac by a sync client, so nothing is written.
    struct SyncedFolderRefusal: LocalizedError, Equatable {
        var errorDescription: String? {
            "That folder syncs to the cloud (iCloud Drive or another synced folder), so the records would be copied off this Mac. Nothing was exported. Choose a folder on this Mac that doesn't sync."
        }
    }

    /// Whether `folder` is in iCloud Drive or another cloud-synced place, by the same
    /// detection the data-folder chooser uses plus the export folder's path check.
    static func isSyncedFolder(_ folder: URL) -> Bool {
        if ExportDestinationCheck.pathLooksSynced(folder) { return true }
        switch DataFolderPolicy.verdict(for: folder) {
        case .iCloudDrive, .iCloudDesktopDocuments, .thirdPartyCloud: return true
        case .ok, .networkVolume, .removableUnencrypted: return false
        }
    }

    static func write(
        from source: AllRecordsSource,
        to destination: URL,
        exportedOn: Date = Date(),
        progress: (Double, String) -> Void,
        isCancelled: () -> Bool
    ) throws -> PatientArchiveWriter.Outcome {
        if isSyncedFolder(destination.deletingLastPathComponent()) { throw SyncedFolderRefusal() }
        let fm = FileManager.default
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            let outcome = try fill(staging, from: source, exportedOn: exportedOn, progress: progress, isCancelled: isCancelled)
            if isCancelled() { throw CancellationError() }
            try fm.moveItem(at: staging, to: destination)
            progress(1, "Done")
            return outcome
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    private static func fill(
        _ folder: URL, from source: AllRecordsSource, exportedOn: Date,
        progress: (Double, String) -> Void, isCancelled: () -> Bool
    ) throws -> PatientArchiveWriter.Outcome {
        let patients = source.patients
        let roots = patientFolders(patients)
        let total = max(patients.reduce(0) { $0 + $1.sessionCount }, 1)
        var done = 0
        var sessionCount = 0
        var fileCount = 0
        var recordingCount = 0
        var byteCount = 0

        for (p, patient) in patients.enumerated() {
            var sessions: [ArchiveSession] = []
            for s in 0..<patient.sessionCount {
                if isCancelled() { throw CancellationError() }
                progress(0.98 * Double(done) / Double(total),
                         "Patient \(p + 1) of \(patients.count) · session \(s + 1) of \(patient.sessionCount)")
                sessions.append(try source.loadSession(patient: p, session: s))
                done += 1
            }
            let recordings = sessions.indices.map { source.recordings(patient: p, session: $0) }
            let files = PatientArchive.files(
                patientName: patient.name, background: patient.background, sessions: sessions,
                exportedOn: exportedOn, rootName: roots[p], hasRecording: { !recordings[$0].isEmpty }
            )
            for file in files {
                let data = Data(file.text.utf8)
                try write(data, to: folder.appendingPathComponent(file.path))
                byteCount += data.count
            }
            fileCount += files.count

            let sessionFolders = PatientArchive.sessionFolders(for: sessions.map(\.date))
            for s in sessions.indices {
                for recording in recordings[s] {
                    if isCancelled() { throw CancellationError() }
                    let target = folder.appendingPathComponent("\(roots[p])/Sessions/\(sessionFolders[s])/\(recording.name)")
                    byteCount += try copyRecording(recording.url, to: target, source: source)
                    recordingCount += 1
                }
            }
            sessionCount += sessions.count
        }

        let readMe = Data(readMeText(
            exportedOn: exportedOn, patientCount: patients.count, sessionCount: sessionCount,
            recordingCount: recordingCount, unreadablePatientCount: source.unreadablePatientCount,
            unreadableSessionCount: source.unreadableSessionCount
        ).utf8)
        try write(readMe, to: folder.appendingPathComponent("Read me.txt"))
        return PatientArchiveWriter.Outcome(
            sessionCount: sessionCount, fileCount: fileCount + recordingCount + 1,
            byteCount: byteCount + readMe.count, patientCount: patients.count
        )
    }

    private static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .withoutOverwriting)
    }

    /// Copies (or, for a decrypted temporary copy, moves) a recording into place.
    /// Returns its size in bytes.
    private static func copyRecording(_ url: URL, to target: URL, source: AllRecordsSource) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        let readable = try source.readableRecording(at: url)
        if readable.isTemporary {
            do { try fm.moveItem(at: readable.url, to: target) } catch {
                try? fm.removeItem(at: readable.url)
                throw error
            }
        } else {
            try fm.copyItem(at: readable.url, to: target)
        }
        return (try? fm.attributesOfItem(atPath: target.path)[.size] as? Int) ?? 0
    }

    static func readMeText(
        exportedOn: Date, patientCount: Int, sessionCount: Int, recordingCount: Int,
        unreadablePatientCount: Int, unreadableSessionCount: Int
    ) -> String {
        var lines = [
            "Aletheia records",
            "Exported on \(longFormatter.string(from: exportedOn)).",
            "",
            "There is one folder per patient. Each holds a Sessions folder with one folder per session, oldest first: the transcript and notes as plain text files that open in any text editor, and any kept recordings as audio files that open in QuickTime Player.",
            "",
            "These files are not encrypted by Aletheia. Keep them on an encrypted disk, and delete them when your record-keeping rules allow.",
            "",
            "Patients: \(patientCount)",
            "Sessions: \(sessionCount)",
            "Recordings: \(recordingCount)",
        ]
        if unreadablePatientCount > 0 {
            lines.append("Patient records that couldn't be read and are not included: \(unreadablePatientCount)")
        }
        if unreadableSessionCount > 0 {
            lines.append("Session records that couldn't be read and are not included: \(unreadableSessionCount)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static let longFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .long
        return f
    }()
}

/// Whether a folder chosen for an export is a safe place for patient records.
/// The decision is pure; `ExportDestinationInspector` does the system reads.
enum ExportDestinationCheck {
    struct Warning: Equatable {
        let title: String
        let message: String
    }

    static func warnings(volumeEncrypted: Bool?, isSynced: Bool) -> [Warning] {
        var warnings: [Warning] = []
        if isSynced { warnings.append(synced) }
        switch volumeEncrypted {
        case false?: warnings.append(unencrypted)
        case nil: warnings.append(unknown)
        case true?: break
        }
        return warnings
    }

    /// iCloud Drive and File Provider folders (Dropbox, Google Drive, OneDrive, ...).
    static func pathLooksSynced(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.contains("/Library/Mobile Documents/") || path.hasSuffix("/Library/Mobile Documents")
            || path.contains("/Library/CloudStorage/") || path.hasSuffix("/Library/CloudStorage")
    }

    static let synced = Warning(
        title: "This folder syncs to the cloud",
        message: "The folder you chose is in iCloud Drive or another synced folder, so the records would be copied off this Mac. Choose a folder that doesn't sync."
    )
    static let unencrypted = Warning(
        title: "This disk isn't encrypted",
        message: "The folder you chose is on a disk that isn't encrypted, so anyone who has the disk can read these records. Choose a folder on this Mac with FileVault on, or an encrypted external drive (in Finder, Control-click the drive and choose Encrypt)."
    )
    static let unknown = Warning(
        title: "Couldn't confirm this disk is encrypted",
        message: "Aletheia couldn't tell whether the disk you chose is encrypted. Export only to this Mac with FileVault on, or to an encrypted external drive."
    )
}

/// Reads what `ExportDestinationCheck` needs about a folder.
struct ExportDestinationInspector {
    var encryption: DiskEncryptionProbing = DiskEncryptionProbe()
    var isUbiquitous: (URL) -> Bool = { url in
        (try? url.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem) ?? false
    }

    func warnings(for folder: URL) -> [ExportDestinationCheck.Warning] {
        ExportDestinationCheck.warnings(
            volumeEncrypted: encryption.isDataVolumeEncrypted(folder),
            isSynced: ExportDestinationCheck.pathLooksSynced(folder) || isUbiquitous(folder)
        )
    }
}
