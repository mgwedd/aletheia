import XCTest
@testable import Aletheia

/// Psychotherapy notes live apart from the clinical record: their own stored
/// kind, a one-time idempotent move from the old kind, and a separate export.
final class PsychotherapyNoteSeparationTests: XCTestCase {
    private func date(_ day: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 3, day: day, hour: 9, minute: 30))!
    }

    // MARK: Migration

    func testMigrationMovesOldNotesAndASecondRunDoesNothing() throws {
        let core = InMemoryPersistenceCore()
        let repository = AnnotationRepository(core: core, protector: .passthrough)
        let sessionA = UUID(), sessionB = UUID()
        XCTAssertTrue(repository.saveNote(sessionID: sessionA, text: "first"))
        XCTAssertTrue(repository.saveNote(sessionID: sessionB, text: "second"))
        // Put both back as rows of the old kind, as an earlier version wrote them.
        for session in [sessionA, sessionB] {
            let current = try XCTUnwrap(core.record(kind: AnnotationRepository.noteKind, id: session.uuidString))
            XCTAssertTrue(core.put(PersistedRecord(
                id: current.id, kind: "note", ownerID: current.ownerID, itemID: current.itemID,
                payload: current.payload, createdAt: current.createdAt, updatedAt: current.updatedAt)))
            XCTAssertTrue(core.remove(kind: AnnotationRepository.noteKind, id: session.uuidString))
        }
        XCTAssertEqual(core.allRecords(kind: "note").count, 2)

        XCTAssertEqual(repository.migrateLegacyNotes(), 2)
        XCTAssertTrue(core.allRecords(kind: "note").isEmpty)
        XCTAssertEqual(repository.note(sessionID: sessionA), "first")
        XCTAssertEqual(repository.note(sessionID: sessionB), "second")

        let before = core.allRecords(kind: AnnotationRepository.noteKind)
        XCTAssertEqual(repository.migrateLegacyNotes(), 0)
        XCTAssertEqual(core.allRecords(kind: AnnotationRepository.noteKind), before)
    }

    func testMigrationKeepsTheNewerRowWhenBothKindsExist() {
        let core = InMemoryPersistenceCore()
        let repository = AnnotationRepository(core: core, protector: .passthrough)
        let session = UUID()
        XCTAssertTrue(repository.saveNote(sessionID: session, text: "new"))
        XCTAssertTrue(core.put(PersistedRecord(id: session.uuidString, kind: "note", itemID: session, payload: Data("stale".utf8))))

        XCTAssertEqual(repository.migrateLegacyNotes(), 1)
        XCTAssertTrue(core.allRecords(kind: "note").isEmpty)
        XCTAssertEqual(repository.note(sessionID: session), "new")
    }

    // MARK: Authorization

    func testPsychotherapyExportRequiresAuthorization() throws {
        XCTAssertThrowsError(try PsychotherapyExport.sessionDocument(
            patientName: "Jane Doe", date: date(5), note: "private", authorized: false)
        ) { XCTAssertEqual($0 as? PsychotherapyExport.ExportError, .notAuthorized) }
        let entry = PsychotherapyNoteEntry(date: date(5), note: "private", comments: [])
        XCTAssertThrowsError(try PsychotherapyExport.archiveFiles(
            patientName: "Jane Doe", entries: [entry], exportedOn: date(6), authorized: false)
        ) { XCTAssertEqual($0 as? PsychotherapyExport.ExportError, .notAuthorized) }

        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("psy-\(UUID().uuidString).zip")
        XCTAssertThrowsError(try PsychotherapyExport.write(
            patientName: "Jane Doe", sessionCount: 1, loadEntry: { _ in entry }, to: destination, authorized: false,
            progress: { _, _ in }, isCancelled: { false }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSessionExportIsItsOwnLabelledDocumentNamedByInitials() throws {
        let document = try PsychotherapyExport.sessionDocument(
            patientName: "Jane Doe", date: date(5), note: "  Process notes.  ", authorized: true)
        XCTAssertEqual(document.title, "Psychotherapy note: keep separate from the medical record")
        XCTAssertEqual(document.markdown, "Process notes.")
        XCTAssertEqual(
            PsychotherapyExport.sessionFileBase(patientName: "Jane Doe", date: date(5)),
            "J.D. - 2026-03-05 - Psychotherapy note")
        XCTAssertThrowsError(try PsychotherapyExport.sessionDocument(
            patientName: "Jane Doe", date: date(5), note: " \n", authorized: true)
        ) { XCTAssertEqual($0 as? PsychotherapyExport.ExportError, .nothingToExport) }
    }

    @MainActor func testExportErrorsReadInPlainWords() {
        for error in [PsychotherapyExport.ExportError.notAuthorized, .nothingToExport] {
            let message = ExportJobCenter.message(for: error)
            XCTAssertFalse(message.contains("ExportError"), message)
            XCTAssertFalse(message.contains("error 1"), message)
        }
        XCTAssertTrue(ExportJobCenter.message(for: PsychotherapyExport.ExportError.nothingToExport)
            .contains("psychotherapy note or private comment"))
    }

    func testArchiveHoldsOnlyPsychotherapyMaterialUnderItsTitle() throws {
        let entry = PsychotherapyNoteEntry(
            date: date(5), note: "Process notes.",
            comments: [ArchiveComment(anchorSeconds: nil, quotedText: "", body: "Private comment.", resolved: false)])
        let files = try PsychotherapyExport.archiveFiles(
            patientName: "Jane Doe", entries: [entry, PsychotherapyNoteEntry(date: date(6), note: "", comments: [])],
            exportedOn: date(7), authorized: true)
        XCTAssertEqual(files.count, 3)
        XCTAssertEqual(files[0].path, "Jane Doe psychotherapy notes/Read me.txt")
        XCTAssertTrue(files[1].path.hasSuffix("/Psychotherapy note.txt"), files[1].path)
        XCTAssertTrue(files[2].path.hasSuffix("/Private comments.txt"), files[2].path)
        XCTAssertTrue(files[1].text.contains("Process notes."))
        XCTAssertTrue(files[2].text.contains("Private comment."))
        for file in files { XCTAssertTrue(file.text.hasPrefix(PsychotherapyExport.title), file.path) }
    }

    // MARK: Record exports leave them out

    func testRecordExportsNeverContainPsychotherapyNoteOrComments() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("psy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        SessionSearch.index = SearchIndex()
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient, on: date(5))
        try store.saveTranscript("Transcript text.", for: patient, session: session)
        try store.saveNote("Generated body.", for: patient, session: session, format: .soap)
        let annotations = try XCTUnwrap(CommentStore(root: root))
        XCTAssertTrue(annotations.saveNote(sessionID: session.id, text: "PRIVATE-PROCESS-NOTE"))
        _ = annotations.addComment(sessionID: session.id, quotedText: "Transcript", body: "PRIVATE-COMMENT")

        let loaded = try ArchiveLoader.load(store: store, patient: patient, session: session)
        let files = PatientArchive.files(
            patientName: patient.name, background: "", sessions: [loaded], exportedOn: date(6))
        XCTAssertTrue(files.contains { $0.text.contains("Generated body.") })
        for file in files {
            XCTAssertFalse(file.text.contains("PRIVATE"), file.path)
            XCTAssertFalse(file.path.contains("Comments"), file.path)
        }

        // The separate export reads the same material back.
        let entry = PsychotherapyExport.load(store: store, session: session)
        XCTAssertEqual(entry.note, "PRIVATE-PROCESS-NOTE")
        XCTAssertEqual(entry.comments.map(\.body), ["PRIVATE-COMMENT"])
    }

    func testPatientChatAndToolScopeLeaveThePsychotherapyNoteOut() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("psy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        SessionSearch.index = SearchIndex()
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient, on: date(5))
        try store.saveTranscript("Transcript text.", for: patient, session: session)
        let annotations = try XCTUnwrap(CommentStore(root: root))
        XCTAssertTrue(annotations.saveNote(sessionID: session.id, text: "PRIVATE-PROCESS-NOTE"))

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "anything")
        XCTAssertFalse(context.text.contains("PRIVATE-PROCESS-NOTE"))
        let scope = store.localToolScope(for: patient)
        XCTAssertFalse(scope.sessions.contains { $0.notes.contains("PRIVATE-PROCESS-NOTE") })
    }

    func testLabels() {
        XCTAssertEqual(NoteKind.progress.title, "Progress note")
        XCTAssertEqual(NoteKind.psychotherapy.title, "Psychotherapy note")
        XCTAssertTrue(NoteKind.psychotherapyBanner.contains("separate from the clinical record"))
        XCTAssertEqual(NotesPane.mine.label, "Psychotherapy note")
    }
}
