import XCTest
@testable import Aletheia

@MainActor
final class TranscriptionCoordinatorTests: XCTestCase {
    private var tempRoot: URL!
    private var stagingRoot: URL!
    private var store: Store!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        stagingRoot = tempRoot.appendingPathComponent("Staging", isDirectory: true)
        let storeRoot = tempRoot.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        store = Store(root: storeRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testRetentionDiscardFailureSurfacesNotice() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        let mic = store.micRecordingURL(for: patient, session: session)
        try Data("mic".utf8).write(to: mic)
        let dir = mic.deletingLastPathComponent()
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }

        let notice = TranscriptionCoordinator.discardAudio(
            store: store, patient: patient, session: session, stagingRoot: stagingRoot)

        XCTAssertNotNil(notice)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mic.path))
        XCTAssertTrue(OrphanAudioSweep.isDiscardPending(for: session.id, stagingRoot: stagingRoot))
    }

    func testSuccessfulDiscardReturnsNoNoticeAndClearsTheMarker() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        let mic = store.micRecordingURL(for: patient, session: session)
        try Data("mic".utf8).write(to: mic)
        OrphanAudioSweep.markDiscardPending(for: session.id, stagingRoot: stagingRoot)

        XCTAssertNil(TranscriptionCoordinator.discardAudio(
            store: store, patient: patient, session: session, stagingRoot: stagingRoot))
        XCTAssertFalse(FileManager.default.fileExists(atPath: mic.path))
        XCTAssertFalse(OrphanAudioSweep.isDiscardPending(for: session.id, stagingRoot: stagingRoot))
    }
}
