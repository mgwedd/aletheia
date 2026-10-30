@testable import Aletheia
import Foundation
import XCTest

// MARK: - Subjects

/// Whether the data folder is left out of system backups.
struct BackupProtection {
    let folderIsExcluded: Bool
    let settingIsOn: Bool
    /// The Settings > Backups banner, as this build shows it.
    let banner: String
    let backUpNowOffered: Bool
}

/// A patient record that was damaged on disk.
struct DamagedRecord {
    let file: URL
    let bytes: Data
}

/// The files in the backups folder's snapshots directory.
struct SnapshotsFolder {
    let names: [String]
    let sizes: [String: Int]
}

/// What opening a data folder left behind and showed.
@MainActor
struct OpenedFolder {
    let app: InProcessDriver
    let before: FolderImage
    var warning: String? { app.appModel.schemaWarning }
    var stampVersion: Int? { FolderImage.stampVersion(in: app.root) }
}

/// Bytes of the stamp and every file under Patients/, keyed by relative path.
struct FolderImage: Equatable {
    let files: [String: Data]

    static func capture(_ root: URL) -> FolderImage {
        var found: [String: Data] = [:]
        let base = root.standardizedFileURL
        let prefix = base.path + "/"
        let stamp = base.appendingPathComponent(DataSchema.metadataFileName)
        if let data = try? Data(contentsOf: stamp) { found[DataSchema.metadataFileName] = data }
        let patients = base.appendingPathComponent("Patients")
        if let walker = FileManager.default.enumerator(at: patients, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in walker where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                found[url.standardizedFileURL.path.replacingOccurrences(of: prefix, with: "")] = try? Data(contentsOf: url)
            }
        }
        return FolderImage(files: found)
    }

    static func stampVersion(in root: URL) -> Int? {
        guard let data = try? Data(contentsOf: root.appendingPathComponent(DataSchema.metadataFileName)) else { return nil }
        return (try? JSONDecoder().decode(StoreMetadata.self, from: data))?.schemaVersion
    }
}

/// What the app holds for one patient after opening a folder.
struct OpenedPatientRecords {
    let listedNames: [String]
    let sessionCount: Int
    let transcript: String?
    let note: String?
    let commentBodies: [String]
}

/// The sidebar's footer about records that couldn't be read.
struct UnreadableFooter {
    let count: Int
    let visibleCount: Int
    /// The one line the sidebar shows about them.
    let title: String
    let listedNames: [String]
    let healthySessionTranscript: String?
}

/// What a "Back up now" left in the chosen folder.
struct BackupResult {
    let succeeded: Bool
    let failureReason: String?
    let filesWritten: [String]
    let filesReadableAsPlainText: [String]
}

// MARK: - Given

extension Given {
    /// Writes the data folder as an older build laid it out: schema stamp 1 and a folder named after the patient.
    func folderWrittenByOlderVersion(patient: Patient) throws {
        try writeStamp(1)
        let store = try XCTUnwrap(app.appModel.store)
        let uuidFolder = store.patientDir(for: patient)
        let legacy = uuidFolder.deletingLastPathComponent().appendingPathComponent(patient.name, isDirectory: true)
        try FileManager.default.moveItem(at: uuidFolder, to: legacy)
        let legacyPatient = Patient(
            id: patient.id, name: patient.name, notes: patient.notes, createdAt: patient.createdAt,
            slug: patient.name, clinicalHistory: patient.clinicalHistory, medications: patient.medications)
        try JSONEncoder.aletheia.encode(legacyPatient).write(to: legacy.appendingPathComponent("patient.json"))
    }

    func folderWrittenByNewerVersion() throws {
        try writeStamp(DataSchema.currentVersion + 1)
    }

    func writeStamp(_ version: Int) throws {
        let stamp = StoreMetadata(schemaVersion: version, lastWrittenBy: "fixture")
        try JSONEncoder().encode(stamp).write(to: app.root.appendingPathComponent(DataSchema.metadataFileName))
    }

    /// Overwrites a patient's patient.json with text that is not JSON.
    func corruptRecord(of patient: Patient) throws -> DamagedRecord {
        let store = try XCTUnwrap(app.appModel.store)
        let file = store.patientDir(for: patient).appendingPathComponent("patient.json")
        try Data("{ not json".utf8).write(to: file)
        return DamagedRecord(file: file, bytes: try Data(contentsOf: file))
    }

    /// One session with a transcript and, optionally, a note and a comment.
    func sessionOnFile(for patient: Patient, transcript: String, note: String? = nil, comment: String? = nil) throws {
        let store = try XCTUnwrap(app.appModel.store)
        let session = try store.createSession(for: patient, on: app.clock.now)
        try store.saveTranscript(transcript, for: patient, session: session)
        if let note { try store.saveSummary(note, for: patient, session: session) }
        if let comment { _ = app.appModel.commentStore?.addComment(sessionID: session.id, quotedText: "hello", body: comment) }
        app.appModel.refreshPatients()
    }
}

// MARK: - When

extension When {
    func lookAtBackupProtection() -> BackupProtection {
        let offered = app.appModel.featureRegistry.contains(id: AtRestEncryptionFeatureModule.id)
        return BackupProtection(
            folderIsExcluded: BackupExclusion.isExcluded(at: app.root),
            settingIsOn: app.settings.keepDataOutOfSystemBackups,
            banner: BackupsBanner.text(
                excluded: app.settings.keepDataOutOfSystemBackups, backUpNowOffered: offered),
            backUpNowOffered: offered)
    }

    func keepDataOutOfBackups(_ on: Bool) { app.settings.keepDataOutOfSystemBackups = on }

    func deletePatientAndLookAtSnapshots(_ patient: Patient) throws -> SnapshotsFolder {
        try app.appModel.deletePatient(patient)
        let dir = BackupLayout.directory(.snapshots, dataRoot: app.root)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        var sizes: [String: Int] = [:]
        for n in names {
            sizes[n] = (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(n).path)[.size] as? Int) ?? 0
        }
        return SnapshotsFolder(names: names, sizes: sizes)
    }

    /// Opens the data folder in a fresh launch.
    func openDataFolder() -> OpenedFolder {
        let before = FolderImage.capture(app.root)
        app.relaunch(tier: app.tier)
        return OpenedFolder(app: app, before: before)
    }

    /// Turns encryption on, then backs up to a new folder outside the data folder.
    /// Reports which files in that folder contain `secret` as readable text.
    func backUpNowToAnotherFolder(containingSecret secret: String) async throws -> BackupResult {
        // BACKUP-08 is for a dev build: Back Up Now needs at-rest encryption.
        XCTAssertTrue(
            app.appModel.featureRegistry.contains(id: AtRestEncryptionFeatureModule.id),
            "BACKUP-08 needs a build that includes at-rest encryption")
        try app.encryption.enable(passphrase: "correct horse battery staple 7", iterations: 100_000)
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("aletheia-backup-target-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let outcome = await app.appModel.backUpNow(to: folder)
        let names = ((try? FileManager.default.subpathsOfDirectory(atPath: folder.path)) ?? []).sorted()
        let needle = Data(secret.utf8)
        let readable = names.filter { name in
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(name)) else { return false }
            return data.range(of: needle) != nil
        }
        var failure: String?
        var ok = false
        switch outcome {
        case .success: ok = true
        case .notConfigured: failure = "not configured"
        case .failed(let why): failure = why
        }
        return BackupResult(succeeded: ok, failureReason: failure, filesWritten: names, filesReadableAsPlainText: readable)
    }

    func lookAtRecords(of patient: Patient) throws -> OpenedPatientRecords {
        let model = app.appModel
        let store = try XCTUnwrap(model.store)
        let current = try XCTUnwrap(model.patients.first { $0.id == patient.id }, "\(patient.name) is not listed")
        let sessions = try store.listSessions(for: current)
        let first = sessions.first
        return OpenedPatientRecords(
            listedNames: model.patients.map(\.name),
            sessionCount: sessions.count,
            transcript: first.flatMap { store.transcript(for: current, session: $0) },
            note: first.flatMap { store.summary(for: current, session: $0) },
            commentBodies: first.map { store.comments(for: $0).map(\.body) } ?? [])
    }

    func lookAtUnreadableFooter(healthy: Patient) throws -> UnreadableFooter {
        let model = app.appModel
        let store = try XCTUnwrap(model.store)
        let current = try XCTUnwrap(model.patients.first { $0.id == healthy.id }, "\(healthy.name) is not listed")
        let session = try store.listSessions(for: current).first
        let visible = model.unreadablePatients.filter { !app.settings.isDamagedRecordDismissed(id: $0.id) }
        return UnreadableFooter(
            count: model.unreadablePatients.count, visibleCount: visible.count,
            title: DamagedRecordsNotice.title(count: visible.count),
            listedNames: model.patients.map(\.name),
            healthySessionTranscript: session.flatMap { store.transcript(for: current, session: $0) })
    }
}

// MARK: - Then

extension Then where Subject == BackupProtection {
    func leavesFolderOutOfBackupsByDefault() {
        expect(subject.settingIsOn, "expected the keep-out-of-backups option to be on by default")
        expect(subject.folderIsExcluded, "expected the data folder to be left out of Time Machine and iCloud backups by default")
        bannerSaysFolderIsLeftOut()
        bannerSaysWhoArrangesBackups()
    }
    func leavesFolderInBackups() {
        expect(!subject.folderIsExcluded, "expected the data folder to be included in Time Machine while the keep-out option is off")
        let b = subject.banner.lowercased()
        expect(b.contains(Copy.backupBannerIncluded), "expected the banner to say Time Machine includes the folder, got: \(subject.banner)")
        expect(b.contains(Copy.backupBannerEncryptedDisk), "expected the banner to say to use an encrypted disk, got: \(subject.banner)")
    }
    func leavesFolderOutOfBackups() {
        expect(subject.folderIsExcluded, "expected the data folder to be left out of Time Machine and iCloud backups (option on: \(subject.settingIsOn))")
        bannerSaysFolderIsLeftOut()
    }
}

extension Then where Subject == BackupProtection {
    fileprivate func bannerSaysFolderIsLeftOut() {
        expect(subject.banner.lowercased().contains(Copy.backupBannerKeptOut), "expected the banner to say the folder is kept out of Time Machine and iCloud backups, got: \(subject.banner)")
    }

    /// A released build has no Back Up Now, so the banner must say so and leave the
    /// arranging to the clinician; a build that has it points at the button instead.
    fileprivate func bannerSaysWhoArrangesBackups() {
        let b = subject.banner.lowercased()
        if subject.backUpNowOffered {
            expect(b.contains(Copy.backupBannerUseBackUpNow), "expected the banner to point at Back Up Now, got: \(subject.banner)")
        } else {
            expect(b.contains(Copy.backupBannerNotAvailable), "expected the banner to say Back Up Now is not available, got: \(subject.banner)")
            expect(b.contains(Copy.backupBannerUpToYou), "expected the banner to say arranging a backup is up to you, got: \(subject.banner)")
            expect(b.contains(Copy.backupBannerEncryptedDisk), "expected the banner to mention an encrypted disk, got: \(subject.banner)")
        }
    }
}

extension Then where Subject == SnapshotsFolder {
    func holdsASnapshotTakenBeforeTheDelete() {
        let match = subject.names.filter { $0.hasSuffix(Copy.backupSnapshotSuffix) }
        expect(!match.isEmpty, "expected a \"\(Copy.backupSnapshotSuffix)\" snapshot, found \(subject.names)")
        expect(match.allSatisfy { (subject.sizes[$0] ?? 0) > 0 }, "expected the snapshot to hold data")
    }
}

extension Then where Subject == OpenedPatientRecords {
    func isIntact(patient: String, transcript: String, note: String, comment: String) {
        expect(subject.listedNames.contains(patient), "expected \(patient) in the sidebar, found \(subject.listedNames)")
        expectEqual(subject.sessionCount, 1, "sessions")
        expectEqual(subject.transcript, transcript, "the transcript")
        expectEqual(subject.note, note, "the note")
        expectEqual(subject.commentBodies, [comment], "the comments")
    }
}

@MainActor
extension Then where Subject == OpenedFolder {
    func wasUpgradedInPlace() {
        expectEqual(subject.stampVersion, DataSchema.currentVersion, "the folder's schema version")
        expect(subject.warning == nil, "expected no warning, found \(subject.warning ?? "")")
    }

    func askedForANewerApp() {
        expect(subject.warning?.contains(Copy.backupNewerVersionPhrase) == true,
               "expected an Update Aletheia warning about a \(Copy.backupNewerVersionPhrase), found \(subject.warning ?? "none")")
    }

    func leftFilesUntouched() {
        let after = FolderImage.capture(subject.app.root)
        let missing = subject.before.files.keys.filter { after.files[$0] == nil }.sorted()
        let changed = subject.before.files.filter { after.files[$0.key] != nil && after.files[$0.key] != $0.value }.keys.sorted()
        expectEqual(missing, [], "files that disappeared")
        expectEqual(changed, [], "files that changed")
    }
}

extension Then where Subject == UnreadableFooter {
    func saysOneRecordCouldntBeRead() {
        expectEqual(subject.visibleCount, 1, "records the sidebar says couldn't be read")
        expectEqual(subject.title, "1 record couldn't be read", "the sidebar's line about them")
    }
    func opensEverythingElse(_ healthy: String, transcript: String) {
        expectEqual(subject.listedNames, [healthy], "the patients listed")
        expectEqual(subject.healthySessionTranscript, transcript, "the healthy session's transcript")
    }
}

extension Then where Subject == DamagedRecord {
    func isLeftUntouched() {
        expectEqual((try? Data(contentsOf: subject.file)) ?? Data(), subject.bytes, "the damaged file's bytes")
    }
}

extension Then where Subject == BackupResult {
    func wroteAnArchive() {
        expect(subject.succeeded, "expected the backup to finish, it said: \(subject.failureReason ?? "nothing")")
        expect(!subject.filesWritten.isEmpty, "expected files in the chosen folder")
    }
    func holdsNoReadableSessionText() {
        expectEqual(subject.filesReadableAsPlainText, [], "files in the backup folder that show session text")
    }
}
