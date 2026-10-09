import CryptoKit
import XCTest
@testable import Aletheia

/// The Store side of note staleness: the fingerprint recorded beside each
/// generated note, its sealing, and that the therapist's own notes are never
/// involved.
final class NoteFreshnessStoreTests: XCTestCase {
    private var root: URL!
    private let key = SymmetricKey(size: .bits256)
    private var keyed: FileProtector { FileProtector(key: key) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NoteFreshnessStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession(_ store: Store) throws -> (Patient, SessionRecord) {
        let patient = try store.createPatient(name: "Dana Cole")
        return (patient, try store.createSession(for: patient))
    }

    func testNoteWithoutAFingerprintReadsAsNil() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveNote("soap text", for: patient, session: session, format: .soap)
        XCTAssertNil(store.noteTranscriptFingerprint(for: patient, session: session, format: .soap))
    }

    func testGeneratedNoteRecordsTheTranscriptFingerprint() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveNote("soap text", for: patient, session: session, format: .soap, generatedFromTranscript: "v1")

        let recorded = store.noteTranscriptFingerprint(for: patient, session: session, format: .soap)
        XCTAssertEqual(recorded, NoteFreshness.fingerprint(of: "v1"))
        XCTAssertFalse(NoteFreshness.isOutdated(recorded: recorded, transcript: "v1"))
    }

    func testEditingTheSavedTranscriptMakesTheNoteOutdated() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveTranscript("v1", for: patient, session: session)
        try store.saveNote("soap text", for: patient, session: session, format: .soap, generatedFromTranscript: "v1")

        try store.saveTranscript("v1 with a correction", for: patient, session: session)
        let current = try XCTUnwrap(store.transcript(for: patient, session: session))
        let recorded = store.noteTranscriptFingerprint(for: patient, session: session, format: .soap)
        XCTAssertTrue(NoteFreshness.isOutdated(recorded: recorded, transcript: current))
    }

    func testRegeneratingUpdatesTheFingerprint() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveNote("old", for: patient, session: session, format: .soap, generatedFromTranscript: "v1")
        try store.saveNote("new", for: patient, session: session, format: .soap, generatedFromTranscript: "v2")

        let recorded = store.noteTranscriptFingerprint(for: patient, session: session, format: .soap)
        XCTAssertFalse(NoteFreshness.isOutdated(recorded: recorded, transcript: "v2"))
        XCTAssertTrue(NoteFreshness.isOutdated(recorded: recorded, transcript: "v1"))
    }

    func testFormatsKeepSeparateFingerprints() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveNote("soap", for: patient, session: session, format: .soap, generatedFromTranscript: "v1")
        try store.saveNote("birp", for: patient, session: session, format: .birp, generatedFromTranscript: "v2")

        XCTAssertEqual(store.noteTranscriptFingerprint(for: patient, session: session, format: .soap), NoteFreshness.fingerprint(of: "v1"))
        XCTAssertEqual(store.noteTranscriptFingerprint(for: patient, session: session, format: .birp), NoteFreshness.fingerprint(of: "v2"))
        XCTAssertNil(store.noteTranscriptFingerprint(for: patient, session: session, format: .dap))
    }

    func testSavingWithoutATranscriptKeepsTheRecordedFingerprint() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveNote("generated", for: patient, session: session, format: .soap, generatedFromTranscript: "v1")
        try store.saveNote("generated, then hand-edited", for: patient, session: session, format: .soap)

        XCTAssertEqual(store.noteTranscriptFingerprint(for: patient, session: session, format: .soap), NoteFreshness.fingerprint(of: "v1"))
        XCTAssertEqual(store.note(for: patient, session: session, format: .soap), "generated, then hand-edited")
    }

    func testSidecarIsNotMistakenForANote() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveNote("soap text", for: patient, session: session, format: .soap, generatedFromTranscript: "v1")

        XCTAssertEqual(Store.noteMetaFileName(for: .soap), "note.soap.meta.json")
        XCTAssertTrue(Store.isNoteMetaFileName("note.soap.meta.json"))
        XCTAssertTrue(Store.isNoteMetaFileName("note.retired.meta.json"))
        XCTAssertFalse(Store.isNoteMetaFileName("note.soap.txt"))
        XCTAssertFalse(Store.isNoteMetaFileName("note..meta.json"))
        XCTAssertFalse(Store.isNoteFileName("note.soap.meta.json"))
        XCTAssertEqual(store.note(for: patient, session: session, format: .soap), "soap text")
    }

    func testPersonalNotesAreUnaffectedByTranscriptEditsAndGeneration() throws {
        let commentStore = try XCTUnwrap(CommentStore(root: root))
        let store = Store(root: root, commentStore: commentStore)
        let (patient, session) = try makeSession(store)
        XCTAssertTrue(commentStore.saveNote(sessionID: session.id, text: "my private note"))

        try store.saveTranscript("v1", for: patient, session: session)
        try store.saveNote("generated", for: patient, session: session, format: .soap, generatedFromTranscript: "v1")
        try store.saveTranscript("v2", for: patient, session: session)

        XCTAssertEqual(commentStore.note(sessionID: session.id), "my private note")
        let dir = store.sessionDir(for: patient, session: session)
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(names.filter { $0.hasSuffix(".meta.json") }, ["note.soap.meta.json"],
                       "only generated notes get a sidecar")
    }

    // MARK: - Encryption

    func testSidecarIsSealedAndReadableWithTheKey() throws {
        let store = Store(root: root, protector: keyed)
        let (patient, session) = try makeSession(store)
        try store.saveNote("soap text", for: patient, session: session, format: .soap, generatedFromTranscript: "v1")

        let url = store.sessionDir(for: patient, session: session).appendingPathComponent("note.soap.meta.json")
        XCTAssertTrue(DataCipher.isEnvelope(try Data(contentsOf: url)))
        XCTAssertEqual(
            store.noteTranscriptFingerprint(for: patient, session: session, format: .soap),
            NoteFreshness.fingerprint(of: "v1")
        )
        // Without the key the sealed sidecar can't be read, so it reads as no record.
        XCTAssertNil(Store(root: root).noteTranscriptFingerprint(for: patient, session: session, format: .soap))
    }

    func testMigratorSealsAndUnsealsTheSidecar() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveNote("soap text", for: patient, session: session, format: .soap, generatedFromTranscript: "v1")
        let url = store.sessionDir(for: patient, session: session).appendingPathComponent("note.soap.meta.json")
        XCTAssertFalse(DataCipher.isEnvelope(try Data(contentsOf: url)))

        XCTAssertTrue(DataMigrator.migrate(root: root, from: .passthrough, to: keyed).isComplete)
        XCTAssertTrue(DataCipher.isEnvelope(try Data(contentsOf: url)), "sealed when encryption is turned on")
        XCTAssertEqual(
            Store(root: root, protector: keyed).noteTranscriptFingerprint(for: patient, session: session, format: .soap),
            NoteFreshness.fingerprint(of: "v1")
        )

        XCTAssertTrue(DataMigrator.migrate(root: root, from: keyed, to: .passthrough).isComplete)
        XCTAssertFalse(DataCipher.isEnvelope(try Data(contentsOf: url)), "plaintext again when it is turned off")
        XCTAssertEqual(
            Store(root: root).noteTranscriptFingerprint(for: patient, session: session, format: .soap),
            NoteFreshness.fingerprint(of: "v1")
        )
    }
}
