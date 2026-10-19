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
        // Listings can come back as /private/var while the temp dir is /var.
        let prunable = MigrationBackup.prunable(MigrationBackup.existing(for: dbURL), keepMostRecent: 0)
        XCTAssertEqual(prunable.map { $0.resolvingSymlinksInPath() }, [snapshot.resolvingSymlinksInPath()])
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

    // MARK: - Restore guidance, refusal text, and bundle pruning

    func testRestoreStepsPointToTheFilesFolderAndWarnAgainstReplace() {
        let failure = DatabaseOpenFailure(kind: .unknown, reason: "r")
        let steps = DatabaseFailureGuidance.guidance(for: failure, dataFolder: "/Users/mike/Aletheia").steps
        let step = steps.first {
            $0.contains(MigrationBackup.filesFolderName)
                && $0.contains("patient.json")
                && $0.contains("session.json")
                && $0.contains("ditto")
        }
        XCTAssertNotNil(step, "the manual restore must cover per-file and ditto restore of patient.json and session.json")
        XCTAssertFalse(step?.contains("Merge") ?? true, "Finder does not offer Merge when same-named items differ")
        XCTAssertTrue(step?.contains("Replace") ?? false, "must still warn against Replace")
        XCTAssertTrue(step?.contains(DatabaseFailureGuidance.preUpgradeFolderName) ?? false)
    }

    func testMigrationRefusedForFilesKeepsFileDetailAndOmitsSQLiteCode() {
        let filesFailure = SQLitePersistenceCore.migrationRefusedFailure(
            problem: .files("patient.json: Permission denied"),
            from: 1,
            to: 2,
            sqliteCode: 5 // SQLITE_BUSY — must be ignored for a file-copy error
        )
        XCTAssertEqual(filesFailure.kind, .migrationRefused)
        XCTAssertNil(filesFailure.sqliteCode, "a file-copy failure must not attach an unrelated SQLite error code")
        XCTAssertTrue(filesFailure.reason.contains("patient and session files"))
        XCTAssertTrue(filesFailure.reason.contains("patient.json: Permission denied"))
        XCTAssertFalse(filesFailure.reason.contains("SQLite error"))

        let dbFailure = SQLitePersistenceCore.migrationRefusedFailure(
            problem: .database,
            from: 1,
            to: 2,
            sqliteCode: 13 // SQLITE_FULL
        )
        XCTAssertEqual(dbFailure.kind, .migrationRefused)
        XCTAssertEqual(dbFailure.sqliteCode, 13)
        XCTAssertTrue(dbFailure.reason.contains("the database"))
        XCTAssertTrue(dbFailure.reason.contains("SQLite error 13"))
    }

    func testPruningSnapshotsAlsoDeletesMatchingFilesBundles() throws {
        try plantDataFolder()
        let (core, dbURL) = try makeCore()
        let t0 = Date(timeIntervalSince1970: 1_600_000_000)
        let oldSnapshot = try XCTUnwrap(MigrationBackup.snapshotURL(forDatabaseAt: dbURL, fromVersion: 1, now: t0))
        let newSnapshot = try XCTUnwrap(MigrationBackup.snapshotURL(forDatabaseAt: dbURL, fromVersion: 2, now: t0.addingTimeInterval(86_400)))

        XCTAssertNil(core.takePreMigrationImage(to: oldSnapshot))
        XCTAssertNil(core.takePreMigrationImage(to: newSnapshot))

        let oldBundle = MigrationBackup.filesBundleURL(forSnapshot: oldSnapshot)
        let newBundle = MigrationBackup.filesBundleURL(forSnapshot: newSnapshot)
        XCTAssertTrue(fm.fileExists(atPath: oldBundle.path))
        XCTAssertTrue(fm.fileExists(atPath: newBundle.path))

        let pruned = MigrationBackup.prune(for: dbURL, keepMostRecent: 1)
        XCTAssertEqual(pruned.map(\.lastPathComponent), [oldSnapshot.lastPathComponent])
        XCTAssertFalse(fm.fileExists(atPath: oldSnapshot.path))
        XCTAssertFalse(fm.fileExists(atPath: oldBundle.path), "pruning a snapshot must also delete its paired files/ bundle")
        XCTAssertTrue(fm.fileExists(atPath: newSnapshot.path))
        XCTAssertTrue(fm.fileExists(atPath: newBundle.path))

        // Pruning the last snapshot cleans up the now-empty files/ directory too.
        _ = MigrationBackup.prune(for: dbURL, keepMostRecent: 0)
        XCTAssertFalse(fm.fileExists(atPath: newBundle.deletingLastPathComponent().path))
    }
}
