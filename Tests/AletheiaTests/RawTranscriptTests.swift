import CryptoKit
import XCTest
@testable import Aletheia

/// The transcriber's own output is kept: written once, never overwritten by
/// edits or a later transcription.
final class RawTranscriptTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RawTranscriptTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func make(_ protector: FileProtector = .passthrough) throws -> (Store, Patient, SessionRecord) {
        let store = Store(root: root, protector: protector)
        let patient = try store.createPatient(name: "Dana Cole")
        return (store, patient, try store.createSession(for: patient))
    }

    func testFirstTranscriptionWritesTheRawFileAndTheWorkingTranscript() throws {
        let (store, patient, session) = try make()
        try store.saveTranscribedText("[00:00] raw words", for: patient, session: session)
        XCTAssertEqual(store.transcript(for: patient, session: session), "[00:00] raw words")
        let raw = store.rawTranscripts(for: patient, session: session)
        XCTAssertEqual(raw.map(\.name), ["transcript.raw.txt"])
        XCTAssertEqual(raw.first?.text, "[00:00] raw words")
    }

    func testEditsNeverTouchTheRawFile() throws {
        let (store, patient, session) = try make()
        try store.saveTranscribedText("original", for: patient, session: session)
        let rawURL = store.sessionDir(for: patient, session: session).appendingPathComponent("transcript.raw.txt")
        let before = try Data(contentsOf: rawURL)
        try store.saveTranscript("edited by the clinician", for: patient, session: session)
        XCTAssertEqual(try Data(contentsOf: rawURL), before)
        XCTAssertEqual(store.transcript(for: patient, session: session), "edited by the clinician")
    }

    func testRetranscribingKeepsTheOriginalAndNumbersTheNewFile() throws {
        let (store, patient, session) = try make()
        try store.saveTranscribedText("first", for: patient, session: session)
        try store.saveTranscript("first, corrected", for: patient, session: session)
        try store.saveTranscribedText("second", for: patient, session: session)
        try store.saveTranscribedText("third", for: patient, session: session)
        let raw = store.rawTranscripts(for: patient, session: session)
        XCTAssertEqual(raw.map(\.name), ["transcript.raw.txt", "transcript.raw.2.txt", "transcript.raw.3.txt"])
        XCTAssertEqual(raw.map(\.text), ["first", "second", "third"])
        XCTAssertEqual(store.transcript(for: patient, session: session), "third")
    }

    func testTenOrMoreRunsStayInNumericOrder() throws {
        let (store, patient, session) = try make()
        for n in 1...11 { try store.saveTranscribedText("run \(n)", for: patient, session: session) }
        XCTAssertEqual(store.rawTranscripts(for: patient, session: session).map(\.text), (1...11).map { "run \($0)" })
    }

    func testRawFilesAreSealedWithTheSameProtector() throws {
        let (store, patient, session) = try make(FileProtector(key: SymmetricKey(size: .bits256)))
        try store.saveTranscribedText("sensitive words", for: patient, session: session)
        let url = store.sessionDir(for: patient, session: session).appendingPathComponent("transcript.raw.txt")
        let onDisk = try Data(contentsOf: url)
        XCTAssertTrue(DataCipher.isEnvelope(onDisk))
        XCTAssertNil(onDisk.range(of: Data("sensitive".utf8)))
        XCTAssertEqual(store.rawTranscripts(for: patient, session: session).first?.text, "sensitive words")
    }

    func testSessionsWithoutRawFilesStillLoad() throws {
        let (store, patient, session) = try make()
        try store.saveTranscript("older session", for: patient, session: session)
        XCTAssertEqual(store.transcript(for: patient, session: session), "older session")
        XCTAssertTrue(store.rawTranscripts(for: patient, session: session).isEmpty)
    }

    func testTheCoordinatorSavesThroughTheRawKeepingPath() throws {
        let source = try String(
            contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/App/Services/TranscriptionCoordinator.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("store.saveTranscribedText("))
        XCTAssertFalse(source.contains("store.saveTranscript("))
    }
}
