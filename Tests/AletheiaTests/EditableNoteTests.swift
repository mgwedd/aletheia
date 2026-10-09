import CryptoKit
import XCTest
@testable import Aletheia

/// Hand-editing a generated note: the pure edit-state rules, and the Store
/// layer that keeps a baseline (`note.<format>.generated.txt`) and the previous
/// edited version (`note.<format>.previous.txt`) beside each per-format note.
final class EditableNoteTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("EditableNoteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession(_ store: Store) throws -> (Patient, SessionRecord) {
        let patient = try store.createPatient(name: "Dana Cole")
        return (patient, try store.createSession(for: patient))
    }

    // MARK: - Pure rules

    func testStateIsNoneForMissingOrBlankNote() {
        XCTAssertEqual(NoteEditing.state(current: nil, baseline: "x"), .none)
        XCTAssertEqual(NoteEditing.state(current: "  \n", baseline: "x"), .none)
    }

    func testStateIsGeneratedWhenTextMatchesBaselineIgnoringWhitespace() {
        XCTAssertEqual(NoteEditing.state(current: "S: calm\n", baseline: "S: calm"), .generated)
        XCTAssertEqual(NoteEditing.state(current: "a\r\nb", baseline: "a\nb"), .generated)
    }

    func testStateIsEditedWhenTextDiffersFromBaseline() {
        XCTAssertEqual(NoteEditing.state(current: "S: calmer", baseline: "S: calm"), .edited)
    }

    func testNoteWithoutBaselineReadsAsGenerated() {
        XCTAssertEqual(NoteEditing.state(current: "a note", baseline: nil), .generated)
    }

    func testCanSaveRequiresContentAndAChange() {
        XCTAssertTrue(NoteEditing.canSave(draft: "new text", original: "old text"))
        XCTAssertFalse(NoteEditing.canSave(draft: "old text\n", original: "old text"), "unchanged writes nothing")
        XCTAssertFalse(NoteEditing.canSave(draft: " \n ", original: "old text"), "blank is refused")
    }

    func testOnlyEditedNotesAreArchivedBeforeReplacing() {
        XCTAssertTrue(NoteEditing.shouldArchiveBeforeReplacing(.edited))
        XCTAssertFalse(NoteEditing.shouldArchiveBeforeReplacing(.generated))
        XCTAssertFalse(NoteEditing.shouldArchiveBeforeReplacing(.none))
    }

    // MARK: - File names

    func testSidecarsAreNotNotesButAreRecognisedAsSidecars() {
        let generated = Store.noteSidecarFileName(for: .soap, .generated)
        let previous = Store.noteSidecarFileName(for: .birp, .previous)
        XCTAssertEqual(generated, "note.soap.generated.txt")
        XCTAssertEqual(previous, "note.birp.previous.txt")
        for name in [generated, previous] {
            XCTAssertTrue(Store.isNoteSidecarFileName(name))
            XCTAssertFalse(Store.isNoteFileName(name), "must not be read as an extra note")
        }
        XCTAssertTrue(Store.isNoteFileName("note.soap.txt"))
        XCTAssertFalse(Store.isNoteSidecarFileName("note.soap.txt"))
        XCTAssertFalse(Store.isNoteSidecarFileName("note..generated.txt"))
        XCTAssertFalse(Store.isNoteSidecarFileName("summary.txt"))
    }

    func testDataMigratorSealsSidecarsWithTheSession() throws {
        let dir = root.appendingPathComponent("S", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for name in ["note.soap.txt", "note.soap.generated.txt", "note.soap.previous.txt", "audio.caf"] {
            try Data("x".utf8).write(to: dir.appendingPathComponent(name))
        }
        let files = DataMigrator.sessionFiles(in: dir)
        XCTAssertTrue(files.contains("note.soap.txt"))
        XCTAssertTrue(files.contains("note.soap.generated.txt"))
        XCTAssertTrue(files.contains("note.soap.previous.txt"))
        XCTAssertFalse(files.contains("audio.caf"))
    }

    // MARK: - Store

    func testReadingStateWritesNothing() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        let dir = store.sessionDir(for: patient, session: session)
        let before = Set(try FileManager.default.contentsOfDirectory(atPath: dir.path))

        XCTAssertEqual(store.noteEditState(for: patient, session: session, format: .soap), .none)
        XCTAssertNil(store.generatedNoteBaseline(for: patient, session: session, format: .soap))
        XCTAssertNil(store.previousNote(for: patient, session: session, format: .soap))

        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), before)
    }

    func testGeneratedNoteIsGeneratedUntilEdited() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)

        try store.saveGeneratedNote("S: calm", for: patient, session: session, format: .soap)
        XCTAssertEqual(store.noteEditState(for: patient, session: session, format: .soap), .generated)
        XCTAssertEqual(store.generatedNoteBaseline(for: patient, session: session, format: .soap), "S: calm")

        try store.saveEditedNote("S: calm, brighter affect", for: patient, session: session, format: .soap)
        XCTAssertEqual(store.note(for: patient, session: session, format: .soap), "S: calm, brighter affect")
        XCTAssertEqual(store.noteEditState(for: patient, session: session, format: .soap), .edited)
        XCTAssertEqual(store.generatedNoteBaseline(for: patient, session: session, format: .soap), "S: calm",
                       "an edit does not move the baseline")
    }

    func testEditingOneFormatLeavesOthersAlone() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveGeneratedNote("soap v1", for: patient, session: session, format: .soap)
        try store.saveGeneratedNote("birp v1", for: patient, session: session, format: .birp)

        try store.saveEditedNote("soap edited", for: patient, session: session, format: .soap)

        XCTAssertEqual(store.noteEditState(for: patient, session: session, format: .soap), .edited)
        XCTAssertEqual(store.noteEditState(for: patient, session: session, format: .birp), .generated)
        XCTAssertEqual(store.note(for: patient, session: session, format: .birp), "birp v1")
    }

    func testEditedNoteIsMirroredToSummary() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveGeneratedNote("v1", for: patient, session: session, format: .soap)
        try store.saveEditedNote("v1 edited", for: patient, session: session, format: .soap)
        XCTAssertEqual(store.summary(for: patient, session: session), "v1 edited")
    }

    func testRegeneratingOverAnEditedNoteKeepsTheEditAsPrevious() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveGeneratedNote("v1", for: patient, session: session, format: .soap)
        try store.saveEditedNote("my careful edit", for: patient, session: session, format: .soap)

        try store.saveGeneratedNote("v2", for: patient, session: session, format: .soap)

        XCTAssertEqual(store.note(for: patient, session: session, format: .soap), "v2")
        XCTAssertEqual(store.previousNote(for: patient, session: session, format: .soap), "my careful edit")
        XCTAssertEqual(store.noteEditState(for: patient, session: session, format: .soap), .generated)
        XCTAssertEqual(store.generatedNoteBaseline(for: patient, session: session, format: .soap), "v2")
    }

    func testRegeneratingOverUntouchedNoteKeepsNoPrevious() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveGeneratedNote("v1", for: patient, session: session, format: .soap)
        try store.saveGeneratedNote("v2", for: patient, session: session, format: .soap)
        XCTAssertNil(store.previousNote(for: patient, session: session, format: .soap))
    }

    func testRestorePreviousSwapsSoItIsReversible() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveGeneratedNote("v1", for: patient, session: session, format: .soap)
        try store.saveEditedNote("edit", for: patient, session: session, format: .soap)
        try store.saveGeneratedNote("v2", for: patient, session: session, format: .soap)

        XCTAssertEqual(try store.restorePreviousNote(for: patient, session: session, format: .soap), "edit")
        XCTAssertEqual(store.note(for: patient, session: session, format: .soap), "edit")
        XCTAssertEqual(store.previousNote(for: patient, session: session, format: .soap), "v2")
        XCTAssertEqual(store.noteEditState(for: patient, session: session, format: .soap), .edited)
        XCTAssertEqual(store.summary(for: patient, session: session), "edit")

        // And back again.
        XCTAssertEqual(try store.restorePreviousNote(for: patient, session: session, format: .soap), "v2")
        XCTAssertEqual(store.note(for: patient, session: session, format: .soap), "v2")
    }

    func testRestoreWithoutPreviousIsANoOp() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveGeneratedNote("v1", for: patient, session: session, format: .soap)
        XCTAssertNil(try store.restorePreviousNote(for: patient, session: session, format: .soap))
        XCTAssertEqual(store.note(for: patient, session: session, format: .soap), "v1")
    }

    func testSidecarsAreNotLeakedIntoPatientChatContext() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveTranscript("Some transcript.", for: patient, session: session)
        try store.saveGeneratedNote("v1 generated", for: patient, session: session, format: .soap)
        try store.saveEditedNote("the edited text", for: patient, session: session, format: .soap)
        try store.saveGeneratedNote("v2 generated", for: patient, session: session, format: .soap)

        let text = store.gatherCitedPatientContext(for: patient, relevantTo: "anything").text
        XCTAssertTrue(text.contains("Generated progress note (SOAP):\nv2 generated"))
        XCTAssertFalse(text.contains("the edited text"), "the previous version is not chat context")
        XCTAssertEqual(text.components(separatedBy: "Generated progress note").count - 1, 1)
    }

    func testSidecarsAreSealedWhenEncryptionIsOn() throws {
        let store = Store(root: root, protector: FileProtector(key: SymmetricKey(size: .bits256)))
        let (patient, session) = try makeSession(store)
        try store.saveGeneratedNote("PHI generated", for: patient, session: session, format: .soap)
        try store.saveEditedNote("PHI edited", for: patient, session: session, format: .soap)
        try store.saveGeneratedNote("PHI v2", for: patient, session: session, format: .soap)

        let dir = store.sessionDir(for: patient, session: session)
        for kind in Store.NoteSidecar.allCases {
            let raw = try Data(contentsOf: dir.appendingPathComponent(Store.noteSidecarFileName(for: .soap, kind)))
            XCTAssertNil(String(data: raw, encoding: .utf8)?.range(of: "PHI"), "\(kind) must not be plaintext")
        }
        XCTAssertEqual(store.previousNote(for: patient, session: session, format: .soap), "PHI edited")
    }
}
