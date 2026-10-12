import XCTest
@testable import Aletheia

/// The pre-migration image holds the database and the small structured JSON
/// (patient.json / session.json), never audio, so a restore returns both to one
/// point (#95).
final class PreMigrationImageTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("PreMigrationImageTests-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    // MARK: - Fixtures

    private func write(_ relative: String, _ text: String) throws {
        let url = root.appendingPathComponent(relative)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    /// Two patients, three sessions, with the audio and notes a migration never touches.
    private func plantDataFolder() throws {
        try write("Patients/Alice/patient.json", "alice-v1")
        try write("Patients/Alice/2024-01-01_Session/session.json", "alice-s1")
        try write("Patients/Alice/2024-01-01_Session/mic.caf", "AUDIO")
        try write("Patients/Alice/2024-01-01_Session/transcript.txt", "TRANSCRIPT")
        try write("Patients/Alice/2024-02-01_Session/session.json", "alice-s2")
        try write("Patients/Bob/patient.json", "bob-v1")
        try write("Patients/Bob/2024-03-01_Session/session.json", "bob-s1")
        try write("Patients/Bob/2024-03-01_Session/call.caf", "AUDIO")
    }

    // MARK: - Which files are copied

    func testListsOnlyPatientAndSessionJSON() throws {
        try plantDataFolder()
        XCTAssertEqual(MigrationBackup.structuredJSONFiles(inDataRoot: root), [
            "Patients/Alice/2024-01-01_Session/session.json",
            "Patients/Alice/2024-02-01_Session/session.json",
            "Patients/Alice/patient.json",
            "Patients/Bob/2024-03-01_Session/session.json",
            "Patients/Bob/patient.json",
        ])
    }

    func testIgnoresHiddenFoldersAndFoldersWithoutJSON() throws {
        try write("Patients/.hidden/patient.json", "x")
        try write("Patients/NoJSON/notes.txt", "x")
        try write(".backups/migrations/Aletheia-pre-v1-20200101T000000Z.sqlite", "db")
        XCTAssertEqual(MigrationBackup.structuredJSONFiles(inDataRoot: root), [])
    }

    func testEmptyDataFolderHasNoFiles() {
        XCTAssertEqual(MigrationBackup.structuredJSONFiles(inDataRoot: root), [])
    }

    // MARK: - Copy

    func testCopyMirrorsRelativePathsAndBytesWithoutAudio() throws {
        try plantDataFolder()
        let bundle = root.appendingPathComponent("bundle")
        let count = try MigrationBackup.copyStructuredJSON(fromDataRoot: root, to: bundle)
        XCTAssertEqual(count, 5)
        XCTAssertEqual(try read(bundle.appendingPathComponent("Patients/Alice/patient.json")), "alice-v1")
        XCTAssertEqual(try read(bundle.appendingPathComponent("Patients/Bob/2024-03-01_Session/session.json")), "bob-s1")
        XCTAssertFalse(fm.fileExists(atPath: bundle.appendingPathComponent("Patients/Alice/2024-01-01_Session/mic.caf").path))
        XCTAssertFalse(fm.fileExists(atPath: bundle.appendingPathComponent("Patients/Alice/2024-01-01_Session/transcript.txt").path))
    }

    func testCopyOfAnEmptyFolderStillCreatesTheBundle() throws {
        let bundle = root.appendingPathComponent("bundle")
        XCTAssertEqual(try MigrationBackup.copyStructuredJSON(fromDataRoot: root, to: bundle), 0)
        XCTAssertTrue(fm.fileExists(atPath: bundle.path))
    }

    func testCopyNeverOverwritesAnExistingBundle() throws {
        try plantDataFolder()
        let bundle = root.appendingPathComponent("bundle")
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)
        try write("bundle/marker.txt", "keep")
        XCTAssertThrowsError(try MigrationBackup.copyStructuredJSON(fromDataRoot: root, to: bundle))
        XCTAssertEqual(try read(bundle.appendingPathComponent("marker.txt")), "keep")
    }

    func testCopyThrowsWhenTheDestinationCannotBeCreated() throws {
        try plantDataFolder()
        try write("blocker", "a file where a folder is needed")
        let bundle = root.appendingPathComponent("blocker/bundle")
        XCTAssertThrowsError(try MigrationBackup.copyStructuredJSON(fromDataRoot: root, to: bundle))
        XCTAssertFalse(fm.fileExists(atPath: bundle.path))
    }

    // MARK: - Pairing with the snapshot

    func testBundleIsNamedAfterItsSnapshotInAFilesFolder() {
        let snapshot = MigrationBackup.directory(for: root.appendingPathComponent("Aletheia.sqlite"))
            .appendingPathComponent("Aletheia-pre-v2-20240101T000000Z.sqlite")
        let bundle = MigrationBackup.filesBundleURL(forSnapshot: snapshot)
        XCTAssertEqual(bundle.lastPathComponent, "Aletheia-pre-v2-20240101T000000Z")
        XCTAssertEqual(bundle.deletingLastPathComponent().lastPathComponent, MigrationBackup.filesFolderName)
    }

    func testTheFilesFolderIsNotMistakenForASnapshot() throws {
        let dbURL = root.appendingPathComponent("Aletheia.sqlite")
        let snapshot = try XCTUnwrap(MigrationBackup.snapshotURL(forDatabaseAt: dbURL, fromVersion: 2))
        try fm.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("db".utf8).write(to: snapshot)
        try MigrationBackup.copyStructuredJSON(fromDataRoot: root, to: MigrationBackup.filesBundleURL(forSnapshot: snapshot))

        XCTAssertEqual(MigrationBackup.existing(for: dbURL).map(\.lastPathComponent), [snapshot.lastPathComponent])
        XCTAssertEqual(MigrationBackup.prunable(MigrationBackup.existing(for: dbURL), keepMostRecent: 0), [snapshot])
    }

    // MARK: - The whole image, through the real database core

    private func makeCore() throws -> (SQLitePersistenceCore, URL) {
        let dbURL = root.appendingPathComponent("Aletheia.sqlite")
        let core = try XCTUnwrap(SQLitePersistenceCore(url: dbURL))
        let record = PersistedRecord(
            id: "n1", kind: "note", ownerID: nil, itemID: nil,
            payload: Data("kept".utf8),
            createdAt: Date(timeIntervalSince1970: 1_600_000_000), updatedAt: Date(timeIntervalSince1970: 1_600_000_000))
        XCTAssertTrue(core.put(record))
        return (core, dbURL)
    }

    func testImageHoldsTheDatabaseAndTheJSONTogether() throws {
        try plantDataFolder()
        let (core, dbURL) = try makeCore()
        let snapshot = try XCTUnwrap(MigrationBackup.snapshotURL(forDatabaseAt: dbURL, fromVersion: 1))

        XCTAssertNil(core.takePreMigrationImage(to: snapshot))

        let copy = try XCTUnwrap(SQLitePersistenceCore(url: snapshot))
        XCTAssertEqual(copy.record(kind: "note", id: "n1").map { String(decoding: $0.payload, as: UTF8.self) }, "kept")
        let bundle = MigrationBackup.filesBundleURL(forSnapshot: snapshot)
        XCTAssertEqual(try read(bundle.appendingPathComponent("Patients/Alice/patient.json")), "alice-v1")
    }

    func testRestoringTheBundleBringsTheJSONBackToTheImagePoint() throws {
        try plantDataFolder()
        let (core, dbURL) = try makeCore()
        let snapshot = try XCTUnwrap(MigrationBackup.snapshotURL(forDatabaseAt: dbURL, fromVersion: 1))
        XCTAssertNil(core.takePreMigrationImage(to: snapshot))

        // A migration (or a later edit) rewrites the live file...
        try write("Patients/Alice/patient.json", "alice-CHANGED")
        // ...and a restore is a plain copy of the bundle over the data folder.
        let bundle = MigrationBackup.filesBundleURL(forSnapshot: snapshot)
        for relative in MigrationBackup.structuredJSONFiles(inDataRoot: bundle) {
            try fm.removeItem(at: root.appendingPathComponent(relative))
            try fm.copyItem(at: bundle.appendingPathComponent(relative), to: root.appendingPathComponent(relative))
        }
        XCTAssertEqual(try read(root.appendingPathComponent("Patients/Alice/patient.json")), "alice-v1")
    }

    func testAnExistingSnapshotIsNeverOverwritten() throws {
        try plantDataFolder()
        let (core, dbURL) = try makeCore()
        let snapshot = try XCTUnwrap(MigrationBackup.snapshotURL(forDatabaseAt: dbURL, fromVersion: 1))
        try fm.createDirectory(at: snapshot.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("earlier".utf8).write(to: snapshot)

        XCTAssertEqual(core.takePreMigrationImage(to: snapshot), .database)
        XCTAssertEqual(try read(snapshot), "earlier")
    }

    func testAFailedJSONCopyRemovesTheDatabaseSnapshotSoNoPreImageIsHalfThere() throws {
        try plantDataFolder()
        let (core, dbURL) = try makeCore()
        let snapshot = try XCTUnwrap(MigrationBackup.snapshotURL(forDatabaseAt: dbURL, fromVersion: 1))
        // Block the bundle: something already sits where it must be written.
        let bundle = MigrationBackup.filesBundleURL(forSnapshot: snapshot)
        try fm.createDirectory(at: bundle, withIntermediateDirectories: true)

        let result = core.takePreMigrationImage(to: snapshot)
        guard case .files = result else { return XCTFail("expected a files failure, got \(String(describing: result))") }
        XCTAssertFalse(fm.fileExists(atPath: snapshot.path))
        XCTAssertTrue(MigrationBackup.existing(for: dbURL).isEmpty)
    }

    // MARK: - Restore guidance

    func testRestoreStepsPointToTheFilesFolderAndWarnAgainstReplace() {
        let failure = DatabaseOpenFailure(kind: .unknown, reason: "r")
        let steps = DatabaseFailureGuidance.guidance(for: failure, dataFolder: "/Users/mike/Aletheia").steps
        let step = steps.first { $0.contains(MigrationBackup.filesFolderName) && $0.contains("Merge") }
        XCTAssertNotNil(step, "the manual restore must cover the patient and session files")
        XCTAssertTrue(step?.contains("never Replace") ?? false, "Replace would remove recordings")
        XCTAssertTrue(step?.contains(DatabaseFailureGuidance.preUpgradeFolderName) ?? false)
    }
}
