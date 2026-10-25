import SQLite3
import XCTest
@testable import Aletheia

/// A schema upgrade that fails part-way changes nothing: the database stays at
/// its old version with every record readable, the failure is reported rather
/// than swallowed, and the next open (with a good migration) still works.
final class SchemaMigrationFailureTests: XCTestCase {
    private typealias M = SchemaMigrator.Migration

    private var root: URL!
    private var dbURL: URL { root.appendingPathComponent("aletheia.sqlite") }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SchemaMigrationFailureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private let shipped = SchemaMigrator.migrations

    /// A step that creates a table and then hits an error, so a naive runner
    /// would leave the table behind.
    private var brokenStep: M {
        M(version: SchemaMigrator.latestVersion + 1, sql: """
        CREATE TABLE half_done (a TEXT);
        INSERT INTO no_such_table VALUES (1);
        """)
    }

    private func record(_ text: String) -> PersistedRecord {
        PersistedRecord(
            id: UUID().uuidString, kind: "note", ownerID: UUID(), itemID: UUID(),
            payload: Data(text.utf8), createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
    }

    private func tableExists(_ name: String) throws -> Bool {
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(db, "SELECT count(*) FROM sqlite_master WHERE name = ?;", -1, &stmt, nil), SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, name, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        return sqlite3_column_int(stmt, 0) > 0
    }

    func testAFailedUpgradeLeavesTheVersionAndEveryRecordAsTheyWere() throws {
        let kept = record("a session note that must survive")
        do {
            let core = try SQLitePersistenceCore(opening: dbURL)
            XCTAssertTrue(core.put(kept))
            XCTAssertEqual(core.schemaVersion, SchemaMigrator.latestVersion)
        }

        XCTAssertThrowsError(try SQLitePersistenceCore(opening: dbURL, migrations: shipped + [brokenStep])) {
            guard let failure = $0 as? DatabaseOpenFailure else { return XCTFail("untyped error \($0)") }
            XCTAssertEqual(failure.kind, .migrationFailed, "a failed upgrade is reported, not swallowed")
        }

        XCTAssertFalse(try tableExists("half_done"), "the step's earlier statements are rolled back")
        let reopened = try SQLitePersistenceCore(opening: dbURL)
        XCTAssertEqual(reopened.schemaVersion, SchemaMigrator.latestVersion, "the version was not advanced")
        XCTAssertEqual(reopened.record(kind: kept.kind, id: kept.id)?.payload, kept.payload)
        XCTAssertEqual(reopened.allRecords(kind: "note").count, 1)
    }

    func testAFailedUpgradeKeepsAPreMigrationCopyOfTheOriginalData() throws {
        let kept = record("original")
        do {
            let core = try SQLitePersistenceCore(opening: dbURL, migrations: [shipped[0]])
            XCTAssertTrue(core.put(kept))
            XCTAssertEqual(core.schemaVersion, 1)
        }

        XCTAssertThrowsError(try SQLitePersistenceCore(opening: dbURL, migrations: [shipped[0], brokenStep.withVersion(2)]))

        let images = MigrationBackup.existing(for: dbURL)
        XCTAssertEqual(images.count, 1, "the safety copy is taken before any step runs")
        let copy = try SQLitePersistenceCore(opening: images[0], migrations: [shipped[0]])
        XCTAssertEqual(copy.record(kind: kept.kind, id: kept.id)?.payload, kept.payload)
    }

    func testAnOldDatabaseWithDataIsNotStampedWhenALaterStepFails() throws {
        // A database from before versioning: baseline tables and data, version 0.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(dbURL.path, &db), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, shipped[0].sql, nil, nil, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(db, """
        INSERT INTO records VALUES ('note', 'legacy-1', NULL, NULL, X'6869', 1.0, 1.0);
        """, nil, nil, nil), SQLITE_OK)
        sqlite3_close(db)

        XCTAssertThrowsError(try SQLitePersistenceCore(opening: dbURL, migrations: [shipped[0], brokenStep.withVersion(2)]))

        var check: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &check, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { sqlite3_close(check) }
        var stmt: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(check, "PRAGMA user_version;", -1, &stmt, nil), SQLITE_OK)
        XCTAssertEqual(sqlite3_step(stmt), SQLITE_ROW)
        XCTAssertEqual(sqlite3_column_int(stmt, 0), 0, "still the version it was, so the next open retries the whole upgrade")
        sqlite3_finalize(stmt)

        let recovered = try SQLitePersistenceCore(opening: dbURL)
        XCTAssertEqual(recovered.record(kind: "note", id: "legacy-1")?.payload, Data("hi".utf8))
        XCTAssertEqual(recovered.schemaVersion, SchemaMigrator.latestVersion)
    }

    func testAFileFromANewerAppIsRefusedAndLeftUntouched() throws {
        let kept = record("written by a newer build")
        do {
            let future = M(version: shipped.count + 1, sql: "CREATE TABLE IF NOT EXISTS future (a TEXT);")
            let core = try SQLitePersistenceCore(opening: dbURL, migrations: shipped + [future])
            XCTAssertTrue(core.put(kept))
        }
        let before = try Data(contentsOf: dbURL)

        XCTAssertThrowsError(try SQLitePersistenceCore(opening: dbURL)) {
            XCTAssertEqual(($0 as? DatabaseOpenFailure)?.kind, .schemaNewerThanApp)
        }

        // Opening refused without writing: the bytes on disk are the same.
        XCTAssertEqual(try Data(contentsOf: dbURL), before)
    }
}

private extension SchemaMigrator.Migration {
    func withVersion(_ version: Int) -> SchemaMigrator.Migration { .init(version: version, sql: sql) }
}
