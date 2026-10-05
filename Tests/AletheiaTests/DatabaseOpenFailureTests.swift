import XCTest
import SQLite3
@testable import Aletheia

/// The typed reason a database failed to open — classification of SQLite result
/// codes, and that the real open path throws the right kind instead of returning
/// a silent nil — plus the chat-save paths reporting failure instead of dropping it.
final class DatabaseOpenFailureTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseOpenFailureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: Classification

    func testClassifiesSQLiteResultCodes() {
        XCTAssertEqual(DatabaseOpenFailure.classify(sqliteCode: SQLITE_CORRUPT), .corrupt)
        XCTAssertEqual(DatabaseOpenFailure.classify(sqliteCode: SQLITE_NOTADB), .corrupt)
        XCTAssertEqual(DatabaseOpenFailure.classify(sqliteCode: SQLITE_BUSY), .lockedOrDiskFull)
        XCTAssertEqual(DatabaseOpenFailure.classify(sqliteCode: SQLITE_LOCKED), .lockedOrDiskFull)
        XCTAssertEqual(DatabaseOpenFailure.classify(sqliteCode: SQLITE_FULL), .lockedOrDiskFull)
        XCTAssertEqual(DatabaseOpenFailure.classify(sqliteCode: SQLITE_IOERR), .lockedOrDiskFull)
        XCTAssertEqual(DatabaseOpenFailure.classify(sqliteCode: SQLITE_CANTOPEN), .cannotOpen)
        XCTAssertEqual(DatabaseOpenFailure.classify(sqliteCode: SQLITE_PERM), .cannotOpen)
        XCTAssertEqual(DatabaseOpenFailure.classify(sqliteCode: SQLITE_READONLY), .cannotOpen)
        XCTAssertEqual(DatabaseOpenFailure.classify(sqliteCode: SQLITE_ERROR), .unknown)
    }

    func testExtendedCodesClassifyByTheirPrimaryCode() {
        let ioErrWrite: Int32 = SQLITE_IOERR | (3 << 8)
        let cantOpenIsDir: Int32 = SQLITE_CANTOPEN | (4 << 8)
        XCTAssertEqual(DatabaseOpenFailure.classify(sqliteCode: ioErrWrite), .lockedOrDiskFull)
        XCTAssertEqual(DatabaseOpenFailure.classify(sqliteCode: cantOpenIsDir), .cannotOpen)
    }

    func testReasonIsSQLiteStaticTextOnly() {
        let failure = DatabaseOpenFailure(sqliteCode: SQLITE_NOTADB)
        XCTAssertTrue(failure.reason.contains("not a database"))
        XCTAssertFalse(failure.reason.contains("/"), "no paths in the reason")
    }

    // MARK: The real open path

    private func plantRawDatabase(named name: String, _ sql: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else {
            throw XCTSkip("couldn't open a raw SQLite database for the fixture")
        }
        defer { sqlite3_close(db) }
        XCTAssertEqual(sqlite3_exec(db, sql, nil, nil, nil), SQLITE_OK)
        return url
    }

    func testNewerSchemaThrowsSchemaNewerThanApp() throws {
        let latest = SchemaMigrator.latestVersion
        let url = try plantRawDatabase(named: "future.sqlite", "PRAGMA user_version = \(latest + 1);")
        XCTAssertThrowsError(try SQLitePersistenceCore(opening: url)) { error in
            guard let failure = error as? DatabaseOpenFailure else { return XCTFail("wrong error type: \(error)") }
            XCTAssertEqual(failure.kind, .schemaNewerThanApp)
            XCTAssertEqual(failure.dataVersion, latest + 1)
            XCTAssertEqual(failure.appVersion, latest)
        }
        XCTAssertNil(SQLitePersistenceCore(url: url), "the non-throwing init still returns nil")
    }

    func testGarbageFileThrowsCorrupt() throws {
        let url = root.appendingPathComponent("garbage.sqlite")
        try Data(String(repeating: "this is not a database ", count: 400).utf8).write(to: url)
        XCTAssertThrowsError(try SQLitePersistenceCore(opening: url)) { error in
            XCTAssertEqual((error as? DatabaseOpenFailure)?.kind, .corrupt)
        }
        // Left exactly as it was — never overwritten.
        XCTAssertEqual(try Data(contentsOf: url).count, "this is not a database ".utf8.count * 400)
    }

    func testDirectoryWhereTheFileShouldBeThrowsCannotOpen() throws {
        let url = root.appendingPathComponent("Aletheia.sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        XCTAssertThrowsError(try SQLitePersistenceCore(opening: url)) { error in
            XCTAssertNotNil(error as? DatabaseOpenFailure)
        }
    }

    func testCommentStoreOpeningThrowsAndLegacyInitStillReturnsNil() throws {
        let latest = SchemaMigrator.latestVersion
        _ = try plantRawDatabase(named: "Aletheia.sqlite", "PRAGMA user_version = \(latest + 1);")
        XCTAssertThrowsError(try CommentStore(opening: root)) { error in
            XCTAssertEqual((error as? DatabaseOpenFailure)?.kind, .schemaNewerThanApp)
        }
        XCTAssertNil(CommentStore(root: root))
    }

    func testCommentStoreOpeningSucceedsOnAFreshFolder() throws {
        XCTAssertNoThrow(try CommentStore(opening: root))
    }

    // MARK: Chat-save paths report failure instead of discarding it

    func testChatSavesThrowWhenTheDatabaseIsUnavailable() throws {
        let store = Store(root: root, commentStore: nil, openDatabaseIfMissing: false)
        let patient = try store.createPatient(name: "Sam")
        let thread = ChatThread(title: "t", messages: [ChatMessage(role: .user, text: "hi")])

        XCTAssertThrowsError(try store.saveChatThread(thread, for: patient)) { error in
            XCTAssertEqual(error as? DatabaseWriteError, .databaseUnavailable)
        }
        XCTAssertThrowsError(try store.deleteChatThread(id: thread.id, for: patient)) { error in
            XCTAssertEqual(error as? DatabaseWriteError, .databaseUnavailable)
        }
    }

    func testChatSavesSucceedWhenTheDatabaseIsOpen() throws {
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Sam")
        let thread = ChatThread(title: "t", messages: [ChatMessage(role: .user, text: "hi")])
        XCTAssertNoThrow(try store.saveChatThread(thread, for: patient))
        XCTAssertEqual(store.loadChatThreads(for: patient).count, 1)
    }
}
