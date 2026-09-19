import XCTest
@testable import SessionNotes

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

    func testUpdateAndDeleteComment() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot))
        let session = UUID()
        let comment = try XCTUnwrap(store.addComment(sessionID: session, quotedText: "q", body: "original"))

        XCTAssertTrue(store.updateComment(id: comment.id, body: "edited"))
        XCTAssertEqual(store.comments(sessionID: session).first?.body, "edited")

        XCTAssertTrue(store.deleteComment(id: comment.id))
        XCTAssertTrue(store.comments(sessionID: session).isEmpty)
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
