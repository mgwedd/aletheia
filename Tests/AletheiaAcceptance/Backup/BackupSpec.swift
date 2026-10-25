import XCTest

final class BackupSpec: AcceptanceCase {
    func test_BACKUP_01() async throws {
        then(when.lookAtBackupProtection()).leavesFolderInBackups()
    }

    func test_BACKUP_02() async throws {
        when.keepDataOutOfBackups(true)

        then(when.lookAtBackupProtection()).leavesFolderOutOfBackups()
    }

    func test_BACKUP_03() async throws {
        try pending("Show backups folder in Finder is a button action inside SettingsView that calls NSWorkspace; no seam to observe it without a UI driver")
    }

    func test_BACKUP_04() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        try await given.sessions(1, for: jane)

        let snapshots = try when.deletePatientAndLookAtSnapshots(jane)

        then(snapshots).holdsASnapshotTakenBeforeTheDelete()
    }

    func test_BACKUP_05() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        try given.sessionOnFile(for: jane, transcript: "Therapist: hello.", note: "Opening note.", comment: "Follow up")
        try given.folderWrittenByOlderVersion(patient: jane)

        let opened = when.openDataFolder()

        then(opened).wasUpgradedInPlace()
        then(try when.lookAtRecords(of: jane)).isIntact(
            patient: "Jane Doe", transcript: "Therapist: hello.", note: "Opening note.", comment: "Follow up")
    }

    func test_BACKUP_06() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        try given.sessionOnFile(for: jane, transcript: "Therapist: hello.")
        try given.folderWrittenByNewerVersion()

        let opened = when.openDataFolder()

        then(opened).askedForANewerApp()
        then(opened).leftFilesUntouched()
    }

    func test_BACKUP_07() async throws {
        let healthy = try await given.patient(named: "Sam Lee")
        let broken = try await given.patient(named: "Jane Doe")
        try given.sessionOnFile(for: healthy, transcript: "Therapist: hello.")
        let damaged = try given.corruptRecord(of: broken)

        given.appRelaunched()

        let footer = try when.lookAtUnreadableFooter(healthy: healthy)
        then(footer).saysOneRecordCouldntBeRead()
        then(footer).opensEverythingElse("Sam Lee", transcript: "Therapist: hello.")
        then(damaged).isLeftUntouched()
    }

    func test_BACKUP_08() async throws {
        let jane = try await given.patient(named: "Jane Doe")
        try given.sessionOnFile(for: jane, transcript: "zebra-marker-transcript", note: "zebra-marker-note", comment: "zebra-marker-comment")

        let result = try await when.backUpNowToAnotherFolder(containingSecret: "zebra-marker")

        then(result).wroteAnArchive()
        then(result).holdsNoReadableSessionText()
    }
}
