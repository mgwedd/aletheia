import XCTest
@testable import Aletheia

final class CommentStoreTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testCommentsRoundTripAndOrderByCreation() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot))
        let session = UUID()
        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 2000)
        store.addComment(sessionID: session, quotedText: "sleep", body: "worse this week", now: t0)
        store.addComment(sessionID: session, quotedText: "", body: "follow up on meds", now: t1)

        let comments = store.comments(sessionID: session)
        XCTAssertEqual(comments.map(\.body), ["worse this week", "follow up on meds"])
        XCTAssertEqual(comments.first?.quotedText, "sleep")
    }

    func testCommentsAreIsolatedBySession() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot))
        let sessionA = UUID()
        let sessionB = UUID()
        let sessionC = UUID()
        store.addComment(sessionID: sessionA, quotedText: "", body: "A")
        store.addComment(sessionID: sessionB, quotedText: "", body: "B")
        store.addComment(sessionID: sessionC, quotedText: "", body: "C")

        XCTAssertEqual(store.comments(sessionID: sessionA).map(\.body), ["A"])
        XCTAssertEqual(store.comments(sessionID: sessionC).map(\.body), ["C"])
    }

    /// Opening a session reads its private note; a session that has none must
    /// read as empty without a row being created for it.
    func testReadingAMissingNoteDoesNotInsertARow() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot))
        let session = UUID()

        XCTAssertEqual(store.note(sessionID: session), "")
        XCTAssertEqual(store.note(sessionID: session), "")

        let core = try SQLitePersistenceCore(opening: CommentStore.databaseURL(root: tempRoot))
        XCTAssertTrue(core.allRecords(kind: "note").isEmpty, "a read must not upsert an empty note")
    }

    func testReadingAnExistingNoteLeavesItUntouched() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot))
        let session = UUID()
        let t0 = Date(timeIntervalSince1970: 1000)
        store.saveNote(sessionID: session, text: "kept", now: t0)

        XCTAssertEqual(store.note(sessionID: session), "kept")

        let core = try SQLitePersistenceCore(opening: CommentStore.databaseURL(root: tempRoot))
        let record = try XCTUnwrap(core.allRecords(kind: "note").first)
        XCTAssertEqual(record.updatedAt, t0, "reading must not bump updatedAt")
    }

    func testUpdateAndDeleteComment() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot))
        let session = UUID()
        let comment = try XCTUnwrap(store.addComment(sessionID: session, quotedText: "q", body: "original"))

        XCTAssertTrue(store.updateComment(id: comment.id, body: "edited"))
        XCTAssertEqual(store.comments(sessionID: session).first?.body, "edited")

        XCTAssertTrue(store.deleteComment(id: comment.id))
        XCTAssertTrue(store.comments(sessionID: session).isEmpty)
    }

    func testResolvePersistsAcrossReopen() throws {
        let session = UUID()
        let id: String
        do {
            let store = try XCTUnwrap(CommentStore(root: tempRoot))
            let comment = try XCTUnwrap(store.addComment(sessionID: session, quotedText: "q", body: "b"))
            id = comment.id
            XCTAssertFalse(comment.resolved)
            XCTAssertTrue(store.setCommentResolved(id: id, resolved: true))
            XCTAssertEqual(store.comments(sessionID: session).first?.resolved, true)
        }
        // Reopen the same database: the resolved flag survived to disk.
        let reopened = try XCTUnwrap(CommentStore(root: tempRoot))
        XCTAssertEqual(reopened.comments(sessionID: session).first?.resolved, true)
        XCTAssertTrue(reopened.setCommentResolved(id: id, resolved: false))
        XCTAssertEqual(reopened.comments(sessionID: session).first?.resolved, false)
    }

    func testNotesUpsertAndPersistAcrossReopen() throws {
        let session = UUID()
        do {
            let store = try XCTUnwrap(CommentStore(root: tempRoot))
            store.saveNote(sessionID: session, text: "first")
            store.saveNote(sessionID: session, text: "second") // upsert, not duplicate
            XCTAssertEqual(store.note(sessionID: session), "second")
        }
        // Reopen the same file: data persisted to disk.
        let reopened = try XCTUnwrap(CommentStore(root: tempRoot))
        XCTAssertEqual(reopened.note(sessionID: session), "second")
    }

    func testMissingNoteIsEmpty() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot))
        XCTAssertEqual(store.note(sessionID: UUID()), "")
    }
}
