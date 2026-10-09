import CryptoKit
import XCTest
@testable import Aletheia

/// Each progress-note format keeps its own note per session (`note.<format>.txt`),
/// while `summary.txt` stays the "latest note of any format" that export, search
/// and chat context read.
final class ProgressNotePerFormatTests: XCTestCase {
    private var root: URL!
    private let key = SymmetricKey(size: .bits256)
    private var keyed: FileProtector { FileProtector(key: key) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgressNotePerFormatTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeSession(_ store: Store) throws -> (Patient, SessionRecord) {
        let patient = try store.createPatient(name: "Dana Cole")
        let session = try store.createSession(for: patient)
        return (patient, session)
    }

    func testFormatsAreStoredIndependently() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)

        try store.saveNote("soap text", for: patient, session: session, format: .soap)
        try store.saveNote("birp text", for: patient, session: session, format: .birp)

        XCTAssertEqual(store.note(for: patient, session: session, format: .soap), "soap text")
        XCTAssertEqual(store.note(for: patient, session: session, format: .birp), "birp text")

        // Regenerating one format leaves the other alone.
        try store.saveNote("soap v2", for: patient, session: session, format: .soap)
        XCTAssertEqual(store.note(for: patient, session: session, format: .soap), "soap v2")
        XCTAssertEqual(store.note(for: patient, session: session, format: .birp), "birp text")
    }

    func testUnsavedFormatReadsAsNil() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        XCTAssertNil(store.note(for: patient, session: session, format: .soap))

        try store.saveNote("soap text", for: patient, session: session, format: .soap)
        XCTAssertNil(store.note(for: patient, session: session, format: .dap),
                     "a format with no note is empty, not a copy of another format's")
    }

    func testSaveNoteAlsoUpdatesSummaryToTheLatest() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)

        try store.saveNote("soap text", for: patient, session: session, format: .soap)
        XCTAssertEqual(store.summary(for: patient, session: session), "soap text")

        try store.saveNote("birp text", for: patient, session: session, format: .birp)
        XCTAssertEqual(store.summary(for: patient, session: session), "birp text")

        let reloaded = try store.listSessions(for: patient).first { $0.id == session.id }
        XCTAssertEqual(reloaded?.hasSummary, true)
    }

    /// Every file and folder under `dir` with its modification date, so a test
    /// can prove a read left the session folder exactly as it found it.
    private func snapshot(_ dir: URL) throws -> [String: Date] {
        let fm = FileManager.default
        var result: [String: Date] = [dir.lastPathComponent: try XCTUnwrap(fm.attributesOfItem(atPath: dir.path)[.modificationDate] as? Date)]
        for name in try fm.subpathsOfDirectory(atPath: dir.path) {
            let path = dir.appendingPathComponent(name).path
            result[name] = try XCTUnwrap(fm.attributesOfItem(atPath: path)[.modificationDate] as? Date)
        }
        return result
    }

    func testLegacySummaryIsShownForAnyFormatWithoutBeingRewritten() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveSummary("legacy note", for: patient, session: session)
        let dir = store.sessionDir(for: patient, session: session)
        let before = try snapshot(dir)

        XCTAssertEqual(store.note(for: patient, session: session, format: .dap), "legacy note")
        XCTAssertEqual(store.note(for: patient, session: session, format: .soap), "legacy note",
                       "with no per-format note yet, the legacy text is the fallback for every format")

        for format in ProgressNoteFormat.allCases {
            XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(Store.noteFileName(for: format)).path),
                           "reading must not adopt the legacy note as note.\(format.rawValue).txt")
        }
        XCTAssertEqual(try snapshot(dir), before, "listing and modification dates are unchanged")
        XCTAssertEqual(store.summary(for: patient, session: session), "legacy note", "summary.txt is untouched")
    }

    func testLegacySummaryReadIsNonDestructiveWhenSealed() throws {
        let store = Store(root: root, protector: keyed)
        let (patient, session) = try makeSession(store)
        try store.saveSummary("sealed legacy", for: patient, session: session)
        let dir = store.sessionDir(for: patient, session: session)
        let before = try snapshot(dir)

        XCTAssertEqual(store.note(for: patient, session: session, format: .birp), "sealed legacy")
        XCTAssertEqual(try snapshot(dir), before)
    }

    func testRegeneratingAfterLegacyFallbackPersistsThatFormatOnly() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveSummary("legacy note", for: patient, session: session)
        XCTAssertEqual(store.note(for: patient, session: session, format: .dap), "legacy note")

        try store.saveNote("new dap", for: patient, session: session, format: .dap)

        XCTAssertEqual(store.note(for: patient, session: session, format: .dap), "new dap")
        XCTAssertNil(store.note(for: patient, session: session, format: .soap),
                     "once a format has a note, the legacy fallback no longer applies to the others")
    }

    func testOpeningASessionReadsWithoutWriting() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveTranscript("transcript", for: patient, session: session)
        try store.saveSummary("legacy note", for: patient, session: session)
        let dir = store.sessionDir(for: patient, session: session)
        let before = try snapshot(dir)

        // The reads `SessionDetailView.load()` performs against the Store.
        _ = store.transcript(for: patient, session: session)
        _ = store.note(for: patient, session: session, format: .soap)
        _ = store.loadSessionChat(for: patient, session: session)

        XCTAssertEqual(try snapshot(dir), before)
    }

    func testLegacySummaryIsNotAdoptedOnceAnyFormatHasANote() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveSummary("legacy note", for: patient, session: session)
        try store.saveNote("birp text", for: patient, session: session, format: .birp)

        // summary.txt now mirrors the BIRP note; SOAP must not inherit it.
        XCTAssertNil(store.note(for: patient, session: session, format: .soap))
    }

    func testNoNotesAtAllReadsAsNil() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        XCTAssertNil(store.note(for: patient, session: session, format: .narrative))
    }

    func testNoteFileNaming() {
        XCTAssertEqual(Store.noteFileName(for: .soap), "note.soap.txt")
        for format in ProgressNoteFormat.allCases {
            XCTAssertTrue(Store.isNoteFileName(Store.noteFileName(for: format)))
        }
        XCTAssertTrue(Store.isNoteFileName("note.retired.txt"), "matches by shape, not the current format list")
        XCTAssertFalse(Store.isNoteFileName("summary.txt"))
        XCTAssertFalse(Store.isNoteFileName("transcript.txt"))
        XCTAssertFalse(Store.isNoteFileName("note..txt"))
        XCTAssertFalse(Store.isNoteFileName("note.soap.json"))
    }

    // MARK: - Encryption

    func testPerFormatNotesAreSealedAndRestoredByMigrator() throws {
        let store = Store(root: root)
        let (patient, session) = try makeSession(store)
        try store.saveNote("soap text", for: patient, session: session, format: .soap)
        try store.saveNote("birp text", for: patient, session: session, format: .birp)
        let dir = store.sessionDir(for: patient, session: session)
        let soapURL = dir.appendingPathComponent("note.soap.txt")
        let birpURL = dir.appendingPathComponent("note.birp.txt")
        // A note for a format that no longer exists is still converted.
        let retiredURL = dir.appendingPathComponent("note.retired.txt")
        try Data("retired text".utf8).write(to: retiredURL)

        let enable = DataMigrator.migrate(root: root, from: .passthrough, to: keyed)
        XCTAssertTrue(enable.isComplete)
        for url in [soapURL, birpURL, retiredURL] {
            XCTAssertTrue(DataCipher.isEnvelope(try Data(contentsOf: url)), "\(url.lastPathComponent) is sealed on enable")
        }
        let keyedStore = Store(root: root, protector: keyed)
        XCTAssertEqual(keyedStore.note(for: patient, session: session, format: .soap), "soap text")
        XCTAssertEqual(keyedStore.note(for: patient, session: session, format: .birp), "birp text")

        let disable = DataMigrator.migrate(root: root, from: keyed, to: .passthrough)
        XCTAssertTrue(disable.isComplete)
        for url in [soapURL, birpURL, retiredURL] {
            XCTAssertFalse(DataCipher.isEnvelope(try Data(contentsOf: url)), "\(url.lastPathComponent) is plaintext after disable")
        }
        XCTAssertEqual(Store(root: root).note(for: patient, session: session, format: .birp), "birp text")
        XCTAssertEqual(try String(contentsOf: retiredURL, encoding: .utf8), "retired text")
    }

    func testKeyedStoreSealsPerFormatNoteOnDisk() throws {
        let store = Store(root: root, protector: keyed)
        let (patient, session) = try makeSession(store)
        try store.saveNote("a confidential note", for: patient, session: session, format: .soap)

        let url = store.sessionDir(for: patient, session: session).appendingPathComponent("note.soap.txt")
        let onDisk = try Data(contentsOf: url)
        XCTAssertTrue(DataCipher.isEnvelope(onDisk))
        XCTAssertNil(onDisk.range(of: Data("confidential".utf8)))
        XCTAssertEqual(store.note(for: patient, session: session, format: .soap), "a confidential note")
    }
}
