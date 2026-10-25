import CryptoKit
import XCTest
@testable import Aletheia

/// Signing a progress note: the stored record, read-only behaviour through every
/// save path, tamper detection, reopening, and the activity log rows.
final class SignedNoteTests: XCTestCase {
    private var root: URL!
    private var store: Store!
    private var patient: Patient!
    private var session: SessionRecord!
    private var audits: [(AuditAction, String?, String?)] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SignedNoteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try makeStore(protector: .passthrough)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeStore(protector: FileProtector) throws {
        store = Store(root: root, protector: protector)
        store.onAudit = { [unowned self] action, id, detail in audits.append((action, id, detail?.text)) }
        patient = try store.createPatient(name: "Dana Cole")
        session = try store.createSession(for: patient)
    }

    private func noteURL(_ format: ProgressNoteFormat = .soap) -> URL {
        store.sessionDir(for: patient, session: session).appendingPathComponent(Store.noteFileName(for: format))
    }

    private func signatureURL(_ format: ProgressNoteFormat = .soap) -> URL {
        store.sessionDir(for: patient, session: session).appendingPathComponent(Store.noteSignatureFileName(for: format))
    }

    private func status(_ format: ProgressNoteFormat = .soap) throws -> NoteLifecycle.Status {
        try store.noteLifecycle(for: patient, session: session, format: format)
    }

    private func generateAndSign(_ text: String = "S: calm") throws -> SignedNote {
        try store.saveGeneratedNote(text, for: patient, session: session, format: .soap)
        return try store.signNote(for: patient, session: session, format: .soap, signer: "mw:501")
    }

    private func isCase(_ error: Error, _ expected: StoreError) -> Bool {
        guard let e = error as? StoreError else { return false }
        switch (e, expected) {
        case (.noteSigned, .noteSigned), (.noteUnreadable, .noteUnreadable): return true
        default: return false
        }
    }

    func testOlderSessionsReadAsDraft() throws {
        try store.saveNote("S: calm", for: patient, session: session, format: .soap)
        XCTAssertEqual(try status(), .draft)
        XCTAssertFalse(store.hasSignedNote(for: patient, session: session))
        XCTAssertFalse(FileManager.default.fileExists(atPath: signatureURL().path))
    }

    func testSigningStoresHashSignerAndTime() throws {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        try store.saveGeneratedNote("S: calm", for: patient, session: session, format: .soap)
        let record = try store.signNote(for: patient, session: session, format: .soap, signer: "mw:501", at: date)
        XCTAssertEqual(record.sha256, NoteLifecycle.sha256Hex("S: calm"))
        XCTAssertEqual(record.signer, "mw:501")
        XCTAssertEqual(record.signedAt, date)
        XCTAssertEqual(try status(), .signed(record))
        XCTAssertEqual(try store.signatureRecord(for: patient, session: session, format: .soap), record)
        XCTAssertTrue(store.hasSignedNote(for: patient, session: session))
    }

    func testSigningRecordsNoteSignedOnce() throws {
        _ = try generateAndSign()
        XCTAssertEqual(audits.filter { $0.0 == .noteSigned }.count, 1)
        XCTAssertEqual(audits.first { $0.0 == .noteSigned }?.1, session.id.uuidString)
        XCTAssertFalse((audits.first { $0.0 == .noteSigned }?.2 ?? "").contains("calm"), "no note text in the log")
    }

    func testEverySavePathIsRejectedOnceSigned() throws {
        _ = try generateAndSign()
        func assertSigned(_ body: () throws -> Void, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertThrowsError(try body(), label, file: file, line: line) {
                XCTAssertTrue(self.isCase($0, .noteSigned), label, file: file, line: line)
            }
        }
        assertSigned({ try self.store.saveEditedNote("changed", for: self.patient, session: self.session, format: .soap) }, "edit")
        assertSigned({ try self.store.saveGeneratedNote("regenerated", for: self.patient, session: self.session, format: .soap) }, "regenerate")
        assertSigned({ try self.store.saveNote("raw", for: self.patient, session: self.session, format: .soap) }, "saveNote")
        assertSigned({ _ = try self.store.restorePreviousNote(for: self.patient, session: self.session, format: .soap) }, "restore")
        XCTAssertEqual(try String(contentsOf: noteURL(), encoding: .utf8), "S: calm")
        XCTAssertEqual(store.generatedNoteBaseline(for: patient, session: session, format: .soap), "S: calm")
        XCTAssertNil(store.previousNote(for: patient, session: session, format: .soap), "a rejected save leaves no sidecar")
        XCTAssertEqual(try status().record?.sha256, NoteLifecycle.sha256Hex("S: calm"))
    }

    func testSigningAnotherFormatLeavesThisOneEditable() throws {
        _ = try generateAndSign()
        try store.saveGeneratedNote("B: calm", for: patient, session: session, format: .birp)
        XCTAssertEqual(try status(.birp), .draft)
        try store.saveEditedNote("B: calmer", for: patient, session: session, format: .birp)
        XCTAssertEqual(store.note(for: patient, session: session, format: .birp), "B: calmer")
    }

    func testSigningTwiceOrWithoutANoteIsRefused() throws {
        XCTAssertThrowsError(try store.signNote(for: patient, session: session, format: .soap))
        XCTAssertFalse(FileManager.default.fileExists(atPath: signatureURL().path))
        _ = try generateAndSign()
        XCTAssertThrowsError(try store.signNote(for: patient, session: session, format: .soap)) {
            XCTAssertTrue(self.isCase($0, .noteSigned))
        }
        XCTAssertEqual(audits.filter { $0.0 == .noteSigned }.count, 1)
    }

    func testEditingTheFileOutsideTheAppIsReportedAsAltered() throws {
        let record = try generateAndSign()
        try Data("S: calm, edited elsewhere".utf8).write(to: noteURL())
        XCTAssertEqual(try status(), .altered(record))
        XCTAssertThrowsError(try store.saveEditedNote("again", for: patient, session: session, format: .soap)) {
            XCTAssertTrue(self.isCase($0, .noteSigned))
        }
    }

    func testAnUnreadableSignatureFailsClosed() throws {
        _ = try generateAndSign()
        try Data("not json".utf8).write(to: signatureURL())
        XCTAssertThrowsError(try status()) { XCTAssertTrue(self.isCase($0, .noteUnreadable)) }
        XCTAssertThrowsError(try store.saveEditedNote("x", for: patient, session: session, format: .soap))
        XCTAssertEqual(try String(contentsOf: noteURL(), encoding: .utf8), "S: calm")
    }

    func testReopeningMakesADraftAndKeepsTheSignedText() throws {
        _ = try generateAndSign()
        try store.reopenSignedNote(for: patient, session: session, format: .soap)
        XCTAssertEqual(try status(), .draft)
        XCTAssertFalse(FileManager.default.fileExists(atPath: signatureURL().path))
        XCTAssertEqual(store.previousNote(for: patient, session: session, format: .soap), "S: calm")
        XCTAssertEqual(audits.filter { $0.0 == .phiAmended && ($0.2 ?? "").contains("reopened") }.count, 1)
        try store.saveEditedNote("S: calmer", for: patient, session: session, format: .soap)
        XCTAssertEqual(store.note(for: patient, session: session, format: .soap), "S: calmer")
        let second = try store.signNote(for: patient, session: session, format: .soap, signer: "mw:501")
        XCTAssertEqual(second.sha256, NoteLifecycle.sha256Hex("S: calmer"))
    }

    func testReopeningAnUnsignedNoteDoesNothing() throws {
        try store.saveGeneratedNote("S: calm", for: patient, session: session, format: .soap)
        let before = audits.count
        try store.reopenSignedNote(for: patient, session: session, format: .soap)
        XCTAssertEqual(audits.count, before, "reopening an unsigned note logs nothing")
        XCTAssertNil(store.previousNote(for: patient, session: session, format: .soap))
    }

    func testTranscriptIsReadOnlyOnceANoteIsSigned() throws {
        try store.saveTranscribedText("[00:00] hello", for: patient, session: session)
        _ = try generateAndSign()
        XCTAssertThrowsError(try store.saveTranscript("edited", for: patient, session: session)) {
            XCTAssertTrue(self.isCase($0, .noteSigned))
        }
        XCTAssertThrowsError(try store.saveTranscribedText("again", for: patient, session: session)) {
            XCTAssertTrue(self.isCase($0, .noteSigned))
        }
        XCTAssertEqual(store.transcript(for: patient, session: session), "[00:00] hello")
        XCTAssertEqual(store.rawTranscripts(for: patient, session: session).map(\.name), ["transcript.raw.txt"],
                       "a refused re-transcription leaves no stray raw file")
        try store.reopenSignedNote(for: patient, session: session, format: .soap)
        XCTAssertNoThrow(try store.saveTranscript("edited", for: patient, session: session))
    }

    func testSignatureIsSealedOnDiskAndRoundTripsWhenEncrypted() throws {
        try? FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        audits = []
        try makeStore(protector: FileProtector(key: SymmetricKey(size: .bits256)))
        let record = try generateAndSign("S: very private")
        let onDisk = try Data(contentsOf: signatureURL())
        XCTAssertTrue(DataCipher.isEnvelope(onDisk))
        XCTAssertNil(onDisk.range(of: Data(record.signer.utf8)))
        XCTAssertEqual(try status(), .signed(record))
    }

    func testMigratorSealsSignatureAndRawTranscriptFiles() throws {
        try store.saveTranscribedText("[00:00] hello", for: patient, session: session)
        _ = try generateAndSign()
        let files = DataMigrator.sessionFiles(in: store.sessionDir(for: patient, session: session))
        XCTAssertTrue(files.contains("note.soap.signed.json"))
        XCTAssertTrue(files.contains("transcript.raw.txt"))
    }

    func testPsychotherapyNotesAreNotPartOfSigning() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/App/Views/SessionDetailView.swift"), encoding: .utf8)
        let psychotherapyView = try XCTUnwrap(source.components(separatedBy: "private var myNotesView").last?
            .components(separatedBy: "\n    }\n").first)
        XCTAssertFalse(psychotherapyView.contains("signNote"))
        XCTAssertFalse(psychotherapyView.contains("NoteLifecycle"))
    }

    func testTheViewOffersSignAndShowsSignedNotesReadOnly() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/App/Views/SessionDetailView.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("NoteLifecycle.signButton"))
        XCTAssertTrue(source.contains("confirmationDialog(NoteLifecycle.signTitle"))
        XCTAssertTrue(source.contains("Chip(\"Signed\", tone: .ok)"))
        XCTAssertTrue(source.contains("isEditable: transcriptReadError == nil && !note.sessionHasSigned"))
    }
}
