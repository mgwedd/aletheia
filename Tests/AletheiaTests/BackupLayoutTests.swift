import CryptoKit
import XCTest
@testable import Aletheia

/// The single backup layout (`<dataRoot>/.backups/{migrations,snapshots,archives}`)
/// and the one-shot, non-destructive adoption of the two older locations
/// (`Backups/`, `.snapshots/`) plus archives once written flat in `.backups/`.
final class BackupLayoutTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory
            .appendingPathComponent("BackupLayoutTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: - Helpers

    @discardableResult
    private func plant(_ folder: String, _ name: String, _ contents: String = "x") throws -> URL {
        let dir = root.appendingPathComponent(folder, isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func exists(_ relative: String) -> Bool {
        fm.fileExists(atPath: root.appendingPathComponent(relative).path)
    }

    private func read(_ relative: String) throws -> String {
        String(decoding: try Data(contentsOf: root.appendingPathComponent(relative)), as: UTF8.self)
    }

    // MARK: - Layout paths

    func testLayoutPaths() {
        let data = URL(fileURLWithPath: "/data", isDirectory: true)
        XCTAssertEqual(BackupLayout.root(dataRoot: data).path, "/data/.backups")
        XCTAssertEqual(BackupLayout.directory(.migrations, dataRoot: data).path, "/data/.backups/migrations")
        XCTAssertEqual(BackupLayout.directory(.snapshots, dataRoot: data).path, "/data/.backups/snapshots")
        XCTAssertEqual(BackupLayout.directory(.archives, dataRoot: data).path, "/data/.backups/archives")
    }

    func testEveryKindHasItsOwnFolderUnderTheRoot() {
        let data = URL(fileURLWithPath: "/data", isDirectory: true)
        let dirs = BackupLayout.Kind.allCases.map { BackupLayout.directory($0, dataRoot: data) }
        XCTAssertEqual(Set(dirs).count, BackupLayout.Kind.allCases.count, "kinds never share a folder")
        for dir in dirs {
            XCTAssertEqual(dir.deletingLastPathComponent(), BackupLayout.root(dataRoot: data))
        }
    }

    func testComponentsAllPointAtTheLayout() {
        let dbURL = root.appendingPathComponent("Aletheia.sqlite")
        XCTAssertEqual(MigrationBackup.directory(for: dbURL), BackupLayout.directory(.migrations, dataRoot: root))
        XCTAssertEqual(DatabaseSnapshotManager(root: root).directory, BackupLayout.directory(.snapshots, dataRoot: root))
        XCTAssertEqual(LocalEncryptedBackupService(root: root, key: SymmetricKey(size: .bits256)).directory,
                       BackupLayout.directory(.archives, dataRoot: root))
    }

    // MARK: - Legacy adoption

    func testNothingToAdoptOnAFreshRoot() {
        let result = BackupLayout.adoptLegacy(dataRoot: root)
        XCTAssertEqual(result, BackupLayout.LegacyAdoption())
        XCTAssertTrue(result.isClean)
        XCTAssertFalse(result.didWork)
        XCTAssertFalse(exists(".backups"), "a fresh root must not grow an empty backup folder")
    }

    func testMissingRootDoesNotThrowOrCreateAnything() {
        let missing = root.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(BackupLayout.adoptLegacy(dataRoot: missing), BackupLayout.LegacyAdoption())
        XCTAssertFalse(fm.fileExists(atPath: missing.path))
    }

    func testFilesFromBothOldFoldersMoveIntoTheirSubfolders() throws {
        try plant("Backups", "Aletheia-pre-v1-20200101T000000Z.sqlite", "mig")
        try plant(".snapshots", "20200101-000000-pre-encryption-change.sqlite", "snap")
        try plant(".snapshots", "20200102-000000-manual.sqlite", "snap2")

        let result = BackupLayout.adoptLegacy(dataRoot: root)

        XCTAssertEqual(try read(".backups/migrations/Aletheia-pre-v1-20200101T000000Z.sqlite"), "mig")
        XCTAssertEqual(try read(".backups/snapshots/20200101-000000-pre-encryption-change.sqlite"), "snap")
        XCTAssertEqual(try read(".backups/snapshots/20200102-000000-manual.sqlite"), "snap2")
        XCTAssertEqual(result.moved.count, 3)
        XCTAssertTrue(result.isClean)
        XCTAssertTrue(result.didWork)
        XCTAssertFalse(exists("Backups"), "emptied legacy folder is removed")
        XCTAssertFalse(exists(".snapshots"), "emptied legacy folder is removed")
        XCTAssertEqual(Set(result.removedDirectories), ["Backups", ".snapshots"])
    }

    func testFlatArchivesInBackupsRootMoveToArchives() throws {
        let name = "20200101-000000-manual.\(EncryptedBackupArchive.fileExtension)"
        try plant(".backups", name, "sealed")

        let result = BackupLayout.adoptLegacy(dataRoot: root)

        XCTAssertEqual(try read(".backups/archives/\(name)"), "sealed")
        XCTAssertFalse(exists(".backups/\(name)"))
        XCTAssertTrue(exists(".backups"), "the new root itself is never removed")
        XCTAssertEqual(result.moved, [".backups/\(name)"])
    }

    func testAlreadyOrganisedBackupsRootIsLeftAlone() throws {
        try plant(".backups/snapshots", "20200101-000000-manual.sqlite", "keep")
        try plant(".backups/migrations", "a-pre-v1-20200101T000000Z.sqlite", "keep")
        try plant(".backups/archives", "b.\(EncryptedBackupArchive.fileExtension)", "keep")

        let result = BackupLayout.adoptLegacy(dataRoot: root)

        XCTAssertEqual(result, BackupLayout.LegacyAdoption())
        XCTAssertEqual(try read(".backups/snapshots/20200101-000000-manual.sqlite"), "keep")
        XCTAssertEqual(try read(".backups/migrations/a-pre-v1-20200101T000000Z.sqlite"), "keep")
    }

    func testNameCollisionIsSkippedNeverOverwritten() throws {
        try plant("Backups", "same.sqlite", "old-location")
        try plant("Backups", "unique.sqlite", "moves")
        try plant(".backups/migrations", "same.sqlite", "new-location")

        let result = BackupLayout.adoptLegacy(dataRoot: root)

        XCTAssertEqual(try read(".backups/migrations/same.sqlite"), "new-location", "existing file untouched")
        XCTAssertEqual(try read("Backups/same.sqlite"), "old-location", "colliding file stays put, intact")
        XCTAssertEqual(try read(".backups/migrations/unique.sqlite"), "moves")
        XCTAssertEqual(result.skippedCollisions, ["Backups/same.sqlite"])
        XCTAssertEqual(result.moved, ["Backups/unique.sqlite"])
        XCTAssertFalse(result.isClean)
        XCTAssertTrue(exists("Backups"), "old folder is kept while it still holds a file")
        XCTAssertTrue(result.removedDirectories.isEmpty)
    }

    func testFinderDSStoreDoesNotBlockRemovingTheOldFolder() throws {
        try plant("Backups", "a-pre-v1-20200101T000000Z.sqlite", "mig")
        try plant("Backups", ".DS_Store", "finder")

        let result = BackupLayout.adoptLegacy(dataRoot: root)

        XCTAssertEqual(result.moved, ["Backups/a-pre-v1-20200101T000000Z.sqlite"])
        XCTAssertFalse(exists("Backups"), "only Finder metadata remained, so the folder goes")
        XCTAssertFalse(exists(".backups/migrations/.DS_Store"), "Finder metadata is not adopted")
    }

    func testDSStoreAloneIsNotTreatedAsAFile() throws {
        try plant(".snapshots", ".DS_Store", "finder")
        let result = BackupLayout.adoptLegacy(dataRoot: root)
        XCTAssertTrue(result.moved.isEmpty)
        XCTAssertFalse(exists(".backups/snapshots"), "no destination folder is created for nothing")
        XCTAssertEqual(result.removedDirectories, [".snapshots"])
    }

    func testSecondRunIsANoOp() throws {
        try plant("Backups", "m.sqlite", "1")
        try plant(".snapshots", "s.sqlite", "2")
        let first = BackupLayout.adoptLegacy(dataRoot: root)
        XCTAssertTrue(first.didWork)

        let second = BackupLayout.adoptLegacy(dataRoot: root)
        XCTAssertEqual(second, BackupLayout.LegacyAdoption())
        XCTAssertEqual(try read(".backups/migrations/m.sqlite"), "1")
        XCTAssertEqual(try read(".backups/snapshots/s.sqlite"), "2")
    }

    func testSecondRunAfterCollisionReportsSameSkipWithoutLoss() throws {
        try plant("Backups", "same.sqlite", "old")
        try plant(".backups/migrations", "same.sqlite", "new")
        let first = BackupLayout.adoptLegacy(dataRoot: root)
        let second = BackupLayout.adoptLegacy(dataRoot: root)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try read("Backups/same.sqlite"), "old")
        XCTAssertEqual(try read(".backups/migrations/same.sqlite"), "new")
    }

    // MARK: - The components see adopted files

    func testSnapshotManagerSeesLegacySnapshots() throws {
        try plant(".snapshots", "20200101-000000-old.sqlite")
        let names = DatabaseSnapshotManager(root: root).snapshots().map(\.lastPathComponent)
        XCTAssertEqual(names, ["20200101-000000-old.sqlite"])
        XCTAssertTrue(exists(".backups/snapshots/20200101-000000-old.sqlite"))
        XCTAssertFalse(exists(".snapshots"))
    }

    func testMigrationBackupListingSeesLegacyPreImages() throws {
        let dbURL = root.appendingPathComponent("Aletheia.sqlite")
        let old = try XCTUnwrap(MigrationBackup.snapshotURL(
            forDatabaseAt: dbURL, fromVersion: 1, now: Date(timeIntervalSince1970: 1_600_000_000)))
        try plant("Backups", old.lastPathComponent)
        try plant("Backups", "notes.txt")   // not a pre-image: ignored by the listing

        let listed = MigrationBackup.existing(for: dbURL).map(\.lastPathComponent)

        XCTAssertEqual(listed, [old.lastPathComponent])
        XCTAssertTrue(exists(".backups/migrations/\(old.lastPathComponent)"))
    }

    func testArchiveServiceSeesFlatLegacyArchives() throws {
        let name = "20200101-000000-manual.\(EncryptedBackupArchive.fileExtension)"
        try plant(".backups", name)
        let service = LocalEncryptedBackupService(root: root, key: SymmetricKey(size: .bits256))
        XCTAssertEqual(service.archives().map(\.lastPathComponent), [name])
        XCTAssertTrue(exists(".backups/archives/\(name)"))
    }
}
