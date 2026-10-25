import CryptoKit
import XCTest
@testable import Aletheia

/// Whatever is done to a record, the activity log gets a kind from a fixed list
/// and an opaque id, never a name or text.
final class PHIAuditPrivacyTests: XCTestCase {
    func testEveryRecordedDetailIsFromTheFixedListAndHoldsNoNameOrText() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let comments = try XCTUnwrap(CommentStore(root: root))
        let store = Store(root: root, commentStore: comments)
        let key = SymmetricKey(size: .bits256)
        let log = AuditLog(root: root, keyProvider: { key })
        let sink: (AuditAction, String?, String?) -> Void = { action, subject, detail in
            _ = try? log.record(action, subjectID: subject, detail: detail)
        }
        store.onAudit = sink
        comments.onAudit = sink

        let name = "Zebra Quokka"
        let text = "Client reports panic attacks"
        let patient = try store.createPatient(name: name)
        let session = try store.createSession(for: patient)
        try store.saveTranscript(text, for: patient, session: session)
        try store.saveEditedNote(text, for: patient, session: session, format: .soap)
        try store.saveGeneratedNote(text, for: patient, session: session, format: .soap, generatedFromTranscript: text)
        XCTAssertTrue(comments.saveNote(sessionID: session.id, text: text))
        let comment = try XCTUnwrap(comments.addComment(sessionID: session.id, quotedText: text, body: text))
        XCTAssertTrue(comments.updateComment(id: comment.id, body: text))
        XCTAssertTrue(comments.deleteComment(id: comment.id))
        let thread = ChatThread(title: text)
        try store.saveChatThread(thread, for: patient)
        try store.deleteChatThread(id: thread.id, for: patient)
        try Data("audio".utf8).write(to: store.micRecordingURL(for: patient, session: session))
        try store.deleteRecordings(for: patient, session: session)
        try store.deletePatient(patient)

        let rows = log.entries()
        XCTAssertGreaterThanOrEqual(rows.count, 10)
        for row in rows {
            let detail = try XCTUnwrap(row.detail, "\(row.action) has no detail")
            XCTAssertTrue(PHIAuditDetail.all.contains(detail), "unexpected detail \(detail)")
            XCTAssertNotNil(row.subjectID.flatMap(UUID.init(uuidString:)), "subject must be an opaque id")
            let whole = String(describing: row)
            for secret in [name, "Zebra", "Quokka", text, "panic"] {
                XCTAssertFalse(whole.contains(secret), "row leaks \(secret)")
            }
        }
    }
}
