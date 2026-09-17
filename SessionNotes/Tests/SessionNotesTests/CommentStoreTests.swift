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
        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 2000)
        store.addComment(patientSlug: "jane-doe", sessionFolder: "2026-03-05_Session", quotedText: "sleep", body: "worse this week", now: t0)
        store.addComment(patientSlug: "jane-doe", sessionFolder: "2026-03-05_Session", quotedText: "", body: "follow up on meds", now: t1)

        let comments = store.comments(patientSlug: "jane-doe", sessionFolder: "2026-03-05_Session")
        XCTAssertEqual(comments.map(\.body), ["worse this week", "follow up on meds"])
        XCTAssertEqual(comments.first?.quotedText, "sleep")
    }

    func testCommentsAreIsolatedBySession() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot))
        store.addComment(patientSlug: "jane-doe", sessionFolder: "2026-03-05_Session", quotedText: "", body: "A")
        store.addComment(patientSlug: "jane-doe", sessionFolder: "2026-01-05_Session", quotedText: "", body: "B")
        // Same folder name, different patient must not bleed across.
        store.addComment(patientSlug: "john-roe", sessionFolder: "2026-03-05_Session", quotedText: "", body: "C")

        XCTAssertEqual(store.comments(patientSlug: "jane-doe", sessionFolder: "2026-03-05_Session").map(\.body), ["A"])
        XCTAssertEqual(store.comments(patientSlug: "john-roe", sessionFolder: "2026-03-05_Session").map(\.body), ["C"])
    }

    func testUpdateAndDeleteComment() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot))
        let comment = try XCTUnwrap(store.addComment(patientSlug: "p", sessionFolder: "s", quotedText: "q", body: "original"))

        XCTAssertTrue(store.updateComment(id: comment.id, body: "edited"))
        XCTAssertEqual(store.comments(patientSlug: "p", sessionFolder: "s").first?.body, "edited")

        XCTAssertTrue(store.deleteComment(id: comment.id))
        XCTAssertTrue(store.comments(patientSlug: "p", sessionFolder: "s").isEmpty)
    }

    func testNotesUpsertAndPersistAcrossReopen() throws {
        do {
            let store = try XCTUnwrap(CommentStore(root: tempRoot))
            store.saveNote(patientSlug: "p", sessionFolder: "s", text: "first")
            store.saveNote(patientSlug: "p", sessionFolder: "s", text: "second") // upsert, not duplicate
            XCTAssertEqual(store.note(patientSlug: "p", sessionFolder: "s"), "second")
        }
        // Reopen the same file: data persisted to disk.
        let reopened = try XCTUnwrap(CommentStore(root: tempRoot))
        XCTAssertEqual(reopened.note(patientSlug: "p", sessionFolder: "s"), "second")
    }

    func testMissingNoteIsEmpty() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot))
        XCTAssertEqual(store.note(patientSlug: "p", sessionFolder: "nope"), "")
    }
}
