import SQLite3
import XCTest
@testable import SessionNotes

/// The time-anchor column added to comments: it round-trips, defaults to nil,
/// and a database created before the column upgrades in place on open.
final class CommentAnchorTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testAnchorRoundTripsAndDefaultsToNil() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot))
        store.addComment(patientSlug: "p", sessionFolder: "s", quotedText: "barely slept", body: "note", anchorSeconds: 42)
        store.addComment(patientSlug: "p", sessionFolder: "s", quotedText: "", body: "no anchor")

        let comments = store.comments(patientSlug: "p", sessionFolder: "s")
        XCTAssertEqual(comments.first?.anchorSeconds, 42)
        XCTAssertNil(comments.last?.anchorSeconds)
    }

    /// Simulates a database written before the anchor column existed, then opens
    /// it with the current `CommentStore` (which must add the column) and checks
    /// the old row reads back with a nil anchor and new anchored rows work.
    func testOpeningPreAnchorDatabaseUpgradesInPlace() throws {
        let dbURL = tempRoot.appendingPathComponent("SessionNotes.sqlite")

        var raw: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(dbURL.path, &raw, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil), SQLITE_OK)
        let oldSchema = """
        CREATE TABLE comments (
            id TEXT PRIMARY KEY,
            session_key TEXT NOT NULL,
            quoted_text TEXT NOT NULL,
            body TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        );
        INSERT INTO comments (id, session_key, quoted_text, body, created_at, updated_at)
        VALUES ('c1', 'p/s', 'quote', 'old comment', 1000, 1000);
        """
        XCTAssertEqual(sqlite3_exec(raw, oldSchema, nil, nil, nil), SQLITE_OK)
        sqlite3_close(raw)

        // Open with the real store: createSchema must ALTER in the missing column.
        let store = try XCTUnwrap(CommentStore(root: tempRoot))
        let existing = store.comments(patientSlug: "p", sessionFolder: "s")
        XCTAssertEqual(existing.map(\.body), ["old comment"])
        XCTAssertNil(existing.first?.anchorSeconds, "a pre-anchor row reads back with no anchor")

        // And a freshly anchored comment persists into the upgraded table.
        store.addComment(patientSlug: "p", sessionFolder: "s", quotedText: "later", body: "new", anchorSeconds: 90)
        let anchored = store.comments(patientSlug: "p", sessionFolder: "s").first(where: { $0.body == "new" })
        XCTAssertEqual(anchored?.anchorSeconds, 90)
    }
}
