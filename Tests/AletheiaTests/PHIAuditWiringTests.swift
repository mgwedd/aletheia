import CryptoKit
import XCTest
@testable import Aletheia

/// Each change to a patient record adds exactly one activity-log entry that
/// names only the kind of record.
final class PHIAuditWiringTests: XCTestCase {
    private var root: URL!
    private var log: AuditLog!
    private var store: Store!
    private var comments: CommentStore!
    private var patient: Patient!
    private var session: SessionRecord!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        comments = try XCTUnwrap(CommentStore(root: root))
        store = Store(root: root, commentStore: comments)
        let key = SymmetricKey(size: .bits256)
        log = AuditLog(root: root, keyProvider: { key })
        let sink: (AuditAction, String?, AuditDetail?) -> Void = { [log] action, subject, detail in
            _ = try? log?.record(action, subjectID: subject, detail: detail)
        }
        store.onAudit = sink
        comments.onAudit = sink
        patient = try store.createPatient(name: "Zebra Quokka")
        session = try store.createSession(for: patient)
        clear()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Entries so far, ignoring those written during setup.
    private var baseline = 0
    private func clear() { baseline = log.entries().count }
    private func rows(_ action: AuditAction? = nil) -> [AuditEvent] {
        let all = Array(log.entries().dropFirst(baseline))
        return action.map { wanted in all.filter { $0.action == wanted } } ?? all
    }

    private func assertOne(_ action: AuditAction, _ detail: String, subject: String? = nil,
                           file: StaticString = #filePath, line: UInt = #line) {
        let all = rows()
        XCTAssertEqual(all.count, 1, "exactly one row", file: file, line: line)
        XCTAssertEqual(all.first?.action, action, file: file, line: line)
        XCTAssertEqual(all.first?.detail, detail, file: file, line: line)
        if let subject { XCTAssertEqual(all.first?.subjectID, subject, file: file, line: line) }
    }

    func testCreatingAPatientRecordsOneEntry() throws {
        let created = try store.createPatient(name: "Another Person")
        assertOne(.phiCreated, "patient", subject: created.id.uuidString)
    }

    func testCreatingASessionRecordsOneEntry() throws {
        let created = try store.createSession(for: patient)
        assertOne(.phiCreated, "session", subject: created.id.uuidString)
    }

    func testSavingATranscriptRecordsOneEntry() throws {
        try store.saveTranscript("hello there", for: patient, session: session)
        assertOne(.phiAmended, "transcript", subject: session.id.uuidString)
    }

    func testSavingAnEditedNoteRecordsOneEntry() throws {
        try store.saveEditedNote("my edit", for: patient, session: session, format: .soap)
        assertOne(.phiAmended, "note", subject: session.id.uuidString)
    }

    func testSavingAGeneratedNoteRecordsOneEntry() throws {
        try store.saveGeneratedNote("generated", for: patient, session: session, format: .soap, generatedFromTranscript: "t")
        assertOne(.phiAmended, "note", subject: session.id.uuidString)
    }

    func testRestoringAPreviousNoteRecordsOneEntry() throws {
        try store.saveGeneratedNote("first", for: patient, session: session, format: .soap)
        try store.saveEditedNote("edited", for: patient, session: session, format: .soap)
        try store.saveGeneratedNote("second", for: patient, session: session, format: .soap)
        clear()
        _ = try store.restorePreviousNote(for: patient, session: session, format: .soap)
        assertOne(.phiAmended, "note")
    }

    func testSavingATherapistNoteRecordsOneEntryPerWindow() throws {
        let start = Date()
        XCTAssertTrue(comments.saveNote(sessionID: session.id, text: "a", now: start))
        XCTAssertTrue(comments.saveNote(sessionID: session.id, text: "ab", now: start.addingTimeInterval(5)))
        assertOne(.phiAmended, "therapist note", subject: session.id.uuidString)
        XCTAssertTrue(comments.saveNote(
            sessionID: session.id, text: "abc", now: start.addingTimeInterval(CommentStore.noteAuditWindow + 1)))
        XCTAssertEqual(rows(.phiAmended).count, 2)
    }

    func testAddingAndEditingACommentRecordOneEntryEach() throws {
        let comment = try XCTUnwrap(comments.addComment(sessionID: session.id, quotedText: "q", body: "b"))
        assertOne(.phiAmended, "comment", subject: session.id.uuidString)
        clear()
        XCTAssertTrue(comments.updateComment(id: comment.id, body: "b2"))
        assertOne(.phiAmended, "comment", subject: session.id.uuidString)
    }

    func testDeletingRecordingsRecordsOneEntry() throws {
        try store.deleteRecordings(for: patient, session: session)
        XCTAssertTrue(rows().isEmpty, "nothing on disk, nothing deleted")
        try Data("audio".utf8).write(to: store.micRecordingURL(for: patient, session: session))
        try store.deleteRecordings(for: patient, session: session)
        assertOne(.phiDeleted, "audio recording", subject: session.id.uuidString)
    }

    func testDeletingAPatientRecordsOneEntry() throws {
        try store.deletePatient(patient)
        assertOne(.phiDeleted, "patient", subject: patient.id.uuidString)
    }

    func testDeletingAMissingPatientRecordsNothing() throws {
        try store.deletePatient(patient)
        clear()
        XCTAssertThrowsError(try store.deletePatient(patient))
        XCTAssertTrue(rows().isEmpty)
    }

    func testAPatientChangeThatFailsRecordsNothing() {
        XCTAssertThrowsError(try store.createPatient(name: "   "))
        XCTAssertTrue(rows().isEmpty)
    }
}
