import CryptoKit
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

    func testFailedSealLeavesNoDatabaseRow() throws {
        let invalidKey = SymmetricKey(data: Data([0x01]))
        let store = try XCTUnwrap(CommentStore(root: tempRoot, protector: FileProtector(key: invalidKey)))
        let sessionID = UUID()
        XCTAssertNil(store.addComment(sessionID: sessionID, quotedText: "private", body: "private"))
        XCTAssertFalse(store.saveNote(sessionID: sessionID, text: "private"))

        let core = try SQLitePersistenceCore(opening: CommentStore.databaseURL(root: tempRoot))
        XCTAssertTrue(core.allRecords(kind: "comment").isEmpty)
        XCTAssertTrue(core.allRecords(kind: "note").isEmpty)
    }

    func testBadEnvelopeIsReportedAndNeverShownAsCiphertext() throws {
        let key = SymmetricKey(size: .bits256)
        let sessionID = UUID()
        let store = try XCTUnwrap(CommentStore(root: tempRoot, protector: FileProtector(key: key)))
        let comment = try XCTUnwrap(store.addComment(sessionID: sessionID, quotedText: "private", body: "private"))
        let core = try SQLitePersistenceCore(opening: CommentStore.databaseURL(root: tempRoot))
        var record = try XCTUnwrap(core.record(kind: "comment", id: comment.id))
        var envelope = try XCTUnwrap(Data(base64Encoded: String(decoding: record.payload, as: UTF8.self)))
        envelope[envelope.count - 1] ^= 0xFF
        record.payload = Data(envelope.base64EncodedString().utf8)
        XCTAssertTrue(core.put(record))

        XCTAssertTrue(store.comments(sessionID: sessionID).isEmpty)
        let entries = store.unreadableEntries
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.kind, .databaseRecord)
        XCTAssertEqual(entries.first?.fileURL, CommentStore.databaseURL(root: tempRoot))
        XCTAssertEqual(core.record(kind: "comment", id: comment.id)?.payload, record.payload)
    }

    func testFailedReencryptLeavesOriginalPayload() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot))
        let sessionID = UUID()
        XCTAssertTrue(store.saveNote(sessionID: sessionID, text: "private"))
        let core = try SQLitePersistenceCore(opening: CommentStore.databaseURL(root: tempRoot))
        let before = try XCTUnwrap(core.record(kind: "note", id: sessionID.uuidString)?.payload)

        let invalidKey = SymmetricKey(data: Data([0x01]))
        XCTAssertFalse(store.reencrypt(to: FileProtector(key: invalidKey)))
        XCTAssertEqual(core.record(kind: "note", id: sessionID.uuidString)?.payload, before)
    }

    /// Flips the last envelope byte of a stored row so it no longer authenticates.
    private func damage(kind: String, id: String) throws -> Data {
        let core = try SQLitePersistenceCore(opening: CommentStore.databaseURL(root: tempRoot))
        var record = try XCTUnwrap(core.record(kind: kind, id: id))
        var envelope = try XCTUnwrap(Data(base64Encoded: String(decoding: record.payload, as: UTF8.self)))
        envelope[envelope.count - 1] ^= 0xFF
        record.payload = Data(envelope.base64EncodedString().utf8)
        XCTAssertTrue(core.put(record))
        return record.payload
    }

    private func storedPayload(kind: String, id: String) throws -> Data? {
        try SQLitePersistenceCore(opening: CommentStore.databaseURL(root: tempRoot)).record(kind: kind, id: id)?.payload
    }

    func testUnreadableNoteIsNotOverwritten() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot, protector: FileProtector(key: SymmetricKey(size: .bits256))))
        let sessionID = UUID()
        XCTAssertTrue(store.saveNote(sessionID: sessionID, text: "original"))
        let damaged = try damage(kind: "note", id: sessionID.uuidString)

        XCTAssertEqual(store.note(sessionID: sessionID), "")
        XCTAssertFalse(store.saveNote(sessionID: sessionID, text: "replacement"))
        XCTAssertEqual(try storedPayload(kind: "note", id: sessionID.uuidString), damaged)
    }

    func testUnreadableSessionChatIsNotOverwrittenOrCleared() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot, protector: FileProtector(key: SymmetricKey(size: .bits256))))
        let sessionID = UUID()
        XCTAssertTrue(store.saveSessionChat([ChatMessage(role: .user, text: "original")], sessionID: sessionID))
        let damaged = try damage(kind: "sessionChat", id: sessionID.uuidString)

        XCTAssertTrue(store.sessionChat(sessionID: sessionID).isEmpty)
        XCTAssertFalse(store.saveSessionChat([ChatMessage(role: .user, text: "new")], sessionID: sessionID))
        XCTAssertFalse(store.saveSessionChat([], sessionID: sessionID))
        XCTAssertEqual(try storedPayload(kind: "sessionChat", id: sessionID.uuidString), damaged)
    }

    func testUnreadableChatThreadIsNotOverwritten() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot, protector: FileProtector(key: SymmetricKey(size: .bits256))))
        let patientID = UUID()
        let thread = ChatThread(title: "original", messages: [ChatMessage(role: .user, text: "original")])
        XCTAssertTrue(store.saveChatThread(thread, patientID: patientID))
        let damaged = try damage(kind: "chatThread", id: thread.id.uuidString)

        XCTAssertTrue(store.chatThreads(patientID: patientID).isEmpty)
        var edited = thread
        edited.title = "replacement"
        XCTAssertFalse(store.saveChatThread(edited, patientID: patientID))
        XCTAssertEqual(try storedPayload(kind: "chatThread", id: thread.id.uuidString), damaged)
    }

    func testReencryptConvertsReadableRowsPastAnUnreadableOne() throws {
        let key = SymmetricKey(size: .bits256)
        let keyed = try XCTUnwrap(CommentStore(root: tempRoot, protector: FileProtector(key: key)))
        let damagedSession = UUID()
        XCTAssertTrue(keyed.saveNote(sessionID: damagedSession, text: "damaged"))
        let damaged = try damage(kind: "note", id: damagedSession.uuidString)
        let readableSession = UUID()
        XCTAssertTrue(keyed.saveNote(sessionID: readableSession, text: "readable"))

        XCTAssertFalse(keyed.reencrypt(to: .passthrough))
        XCTAssertEqual(try storedPayload(kind: "note", id: damagedSession.uuidString), damaged)
        let plain = try XCTUnwrap(CommentStore(root: tempRoot))
        XCTAssertEqual(plain.note(sessionID: readableSession), "readable")
    }

    func testRevokedKeyNeverWritesPlaintext() throws {
        let reference = ProtectionKey(SymmetricKey(size: .bits256))
        let store = try XCTUnwrap(CommentStore(root: tempRoot, protector: FileProtector(keyReference: reference, requiresKey: true)))
        reference.revoke()
        let sessionID = UUID()
        XCTAssertFalse(store.saveNote(sessionID: sessionID, text: "private"))
        XCTAssertNil(store.addComment(sessionID: sessionID, quotedText: "private", body: "private"))
        XCTAssertNil(try storedPayload(kind: "note", id: sessionID.uuidString))
    }
}
