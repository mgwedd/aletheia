import XCTest
@testable import Aletheia

/// `Store.deleteRecordings` is what enforces the transcript-only default in the
/// filesystem: once a transcript is saved, the raw audio must actually be gone,
/// while the transcript (the document of record) is left untouched. Deletion is
/// also best-effort, so removing recordings that were never written must not
/// throw.
final class StoreRecordingDeletionTests: XCTestCase {
    private var tempRoot: URL!
    private var store: Store!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = Store(root: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testDeleteRecordingsRemovesMicAndCallAudioButKeepsTranscript() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        try store.saveTranscript("the transcript is the document of record", for: patient, session: session)

        let micURL = store.micRecordingURL(for: patient, session: session)
        let callURL = store.callRecordingURL(for: patient, session: session)
        try FileManager.default.createDirectory(at: micURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("mic".utf8).write(to: micURL)
        try Data("call".utf8).write(to: callURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: callURL.path))

        try store.deleteRecordings(for: patient, session: session)

        XCTAssertFalse(FileManager.default.fileExists(atPath: micURL.path), "mic audio should be gone")
        XCTAssertFalse(FileManager.default.fileExists(atPath: callURL.path), "call audio should be gone")
        XCTAssertEqual(store.transcript(for: patient, session: session),
                       "the transcript is the document of record",
                       "the transcript must survive audio deletion")
    }

    func testDeleteRecordingsWhenNoAudioExistsIsANoOp() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        // No recordings were ever written; deleting must not throw or crash.
        try store.deleteRecordings(for: patient, session: session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.micRecordingURL(for: patient, session: session).path))
    }

    func testDeleteRecordingsReportsFailure() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        let micURL = store.micRecordingURL(for: patient, session: session)
        try Data("mic".utf8).write(to: micURL)
        let dir = micURL.deletingLastPathComponent()
        // A read-only folder: the file can't be unlinked.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        XCTAssertThrowsError(try store.deleteRecordings(for: patient, session: session)) { error in
            guard case StoreError.recordingNotDeleted = error else { return XCTFail("got \(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: micURL.path))
    }
}
