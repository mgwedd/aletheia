import XCTest
@testable import SessionNotes

/// `AnnotationRepository` against the in-memory core: identity, per-session
/// scoping, creation ordering, singleton note upsert, and comment
/// edit/delete. `CommentStoreTests`/`CommentAnchorTests` cover the same
/// behaviors end-to-end through `CommentStore` on real SQLite; these pin the
/// repository's own contract in isolation.
final class AnnotationRepositoryTests: XCTestCase {
    private var core: InMemoryPersistenceCore!
    private var repository: AnnotationRepository!

    override func setUp() {
        super.setUp()
        core = InMemoryPersistenceCore()
        repository = AnnotationRepository(core: core, protector: .passthrough)
    }

    // MARK: - Comments

    func testCommentsRoundTripAndOrderByCreation() {
        let session = UUID()
        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 2000)
        repository.addComment(sessionID: session, quotedText: "sleep", body: "worse this week", now: t0)
        repository.addComment(sessionID: session, quotedText: "", body: "follow up on meds", now: t1)

        let comments = repository.comments(sessionID: session)
        XCTAssertEqual(comments.map(\.body), ["worse this week", "follow up on meds"])
        XCTAssertEqual(comments.first?.quotedText, "sleep")
    }

    func testCommentsAreIsolatedBySession() {
        let sessionA = UUID(), sessionB = UUID()
        repository.addComment(sessionID: sessionA, quotedText: "", body: "A")
        repository.addComment(sessionID: sessionB, quotedText: "", body: "B")

        XCTAssertEqual(repository.comments(sessionID: sessionA).map(\.body), ["A"])
        XCTAssertEqual(repository.comments(sessionID: sessionB).map(\.body), ["B"])
    }

    func testAddCommentAssignsFreshIdentityPerComment() {
        let session = UUID()
        let first = repository.addComment(sessionID: session, quotedText: "", body: "first")
        let second = repository.addComment(sessionID: session, quotedText: "", body: "second")

        XCTAssertNotEqual(first?.id, second?.id)
        XCTAssertEqual(repository.comments(sessionID: session).count, 2)
    }

    func testUpdateCommentEditsBodyOnlyAndBumpsUpdatedAt() throws {
        let session = UUID()
        let t0 = Date(timeIntervalSince1970: 1000)
        let t1 = Date(timeIntervalSince1970: 5000)
        let comment = try XCTUnwrap(
            repository.addComment(sessionID: session, quotedText: "q", body: "original", anchorSeconds: 12, now: t0)
        )

        XCTAssertTrue(repository.updateComment(id: comment.id, body: "edited", now: t1))

        let updated = try XCTUnwrap(repository.comments(sessionID: session).first)
        XCTAssertEqual(updated.body, "edited")
        XCTAssertEqual(updated.quotedText, "q", "editing the body leaves the quoted passage alone")
        XCTAssertEqual(updated.anchorSeconds, 12, "editing the body leaves the anchor alone")
        XCTAssertEqual(updated.updatedAt, t1)
        XCTAssertEqual(updated.createdAt, t0, "createdAt never changes")
    }

    func testUpdateUnknownCommentFails() {
        XCTAssertFalse(repository.updateComment(id: "does-not-exist", body: "x"))
    }

    func testDeleteComment() throws {
        let session = UUID()
        let comment = try XCTUnwrap(repository.addComment(sessionID: session, quotedText: "", body: "gone"))

        XCTAssertTrue(repository.deleteComment(id: comment.id))
        XCTAssertTrue(repository.comments(sessionID: session).isEmpty)
        XCTAssertTrue(repository.deleteComment(id: comment.id), "deleting an absent comment is not an error")
    }

    // MARK: - Notes

    func testNoteIsASingletonUpsertKeyedBySession() {
        let session = UUID()
        XCTAssertTrue(repository.saveNote(sessionID: session, text: "first"))
        XCTAssertTrue(repository.saveNote(sessionID: session, text: "second"))

        XCTAssertEqual(repository.note(sessionID: session), "second")
        XCTAssertEqual(core.records(kind: "note", itemID: session).count, 1, "upsert, not a second row")
    }

    func testNotesAreIsolatedBySession() {
        let a = UUID(), b = UUID()
        repository.saveNote(sessionID: a, text: "A's note")
        repository.saveNote(sessionID: b, text: "B's note")

        XCTAssertEqual(repository.note(sessionID: a), "A's note")
        XCTAssertEqual(repository.note(sessionID: b), "B's note")
    }

    func testMissingNoteIsEmptyString() {
        XCTAssertEqual(repository.note(sessionID: UUID()), "")
    }
}
