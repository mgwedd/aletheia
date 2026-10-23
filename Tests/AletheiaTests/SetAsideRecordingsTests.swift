import AppKit
import CryptoKit
import XCTest
@testable import Aletheia

/// The set-aside recordings warning: it shows while any recording is set aside
/// and clears once none is, however that came about.
@MainActor
final class SetAsideRecordingsTests: XCTestCase {
    private var tempDir: URL!
    private var stagingRoot: URL!
    private var protector: FileProtector!
    private var store: Store!
    private var center: NotificationCenter!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("SetAsideTests-\(UUID().uuidString)", isDirectory: true)
        stagingRoot = tempDir.appendingPathComponent("Staging", isDirectory: true)
        let storeRoot = tempDir.appendingPathComponent("Store", isDirectory: true)
        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        protector = FileProtector(key: SymmetricKey(size: .bits256))
        store = Store(root: storeRoot, protector: protector)
        center = NotificationCenter()
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    @discardableResult
    private func setAside(_ name: String = UUID().uuidString, file: String = "mic.caf") throws -> URL {
        let dir = OrphanAudioSweep.quarantineDirectory(stagingRoot: stagingRoot).appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: dir.appendingPathComponent(file))
        return dir
    }

    // MARK: - Appears

    func testNothingSetAsideShowsNoWarning() {
        let model = SetAsideRecordings(stagingRoot: stagingRoot, center: center)
        XCTAssertTrue(model.items.isEmpty)
    }

    func testWarningAppearsWhenARecordingIsSetAside() throws {
        let id = UUID()
        try setAside(id.uuidString)
        let model = SetAsideRecordings(stagingRoot: stagingRoot, center: center)
        XCTAssertEqual(model.items.count, 1)
        XCTAssertEqual(model.items.first?.sessionID, id)
        XCTAssertEqual(model.items.first?.byteCount, 5)
    }

    func testWarningAppearsWhenTheSweepSetsOneAsideLater() throws {
        let model = SetAsideRecordings(stagingRoot: stagingRoot, center: .default)
        XCTAssertTrue(model.items.isEmpty)
        // A staged recording whose session isn't in this data folder.
        let staged = Store.stagingDir(for: UUID(), in: stagingRoot)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: staged.appendingPathComponent("mic.caf"))

        OrphanAudioSweep.sweep(store: store, protector: protector, stagingRoot: stagingRoot, temporaryDirectory: tempDir)

        XCTAssertEqual(model.items.count, 1)
    }

    func testAFolderWithNoRecordingDoesNotCount() throws {
        let dir = OrphanAudioSweep.quarantineDirectory(stagingRoot: stagingRoot).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let model = SetAsideRecordings(stagingRoot: stagingRoot, center: center)
        XCTAssertTrue(model.items.isEmpty)
    }

    func testWarningTextIsCountsOnly() {
        XCTAssertEqual(
            SetAsideRecordings.warningText(count: 1),
            "1 recording couldn't be matched to a session and is set aside on this Mac, unencrypted, until you recover or delete it."
        )
        XCTAssertTrue(SetAsideRecordings.warningText(count: 3).hasPrefix("3 recordings couldn't be matched to a session and are set aside"))
        XCTAssertTrue(SetAsideRecordings.warningText(count: 3).hasSuffix("delete them."))
    }

    // MARK: - Disappears

    func testWarningClearsWhenRemovedOutsideTheAppOnceItIsActiveAgain() throws {
        let dir = try setAside()
        let model = SetAsideRecordings(stagingRoot: stagingRoot, center: center)
        XCTAssertEqual(model.items.count, 1)

        try FileManager.default.removeItem(at: dir) // e.g. in Finder
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)

        XCTAssertTrue(model.items.isEmpty)
    }

    func testWarningClearsWhenTheLaunchSweepRecoversIt() throws {
        let patient = try store.createPatient(name: "Test Patient")
        let session = try store.createSession(for: patient)
        try setAside(session.id.uuidString)
        let model = SetAsideRecordings(stagingRoot: stagingRoot, center: .default)
        XCTAssertEqual(model.items.count, 1)

        let result = OrphanAudioSweep.sweep(store: store, protector: protector, stagingRoot: stagingRoot, temporaryDirectory: tempDir)

        XCTAssertEqual(result.stagedSessionsRecovered, 1)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.micRecordingURL(for: patient, session: session).path))
    }

    func testTryAgainRecoversOnceTheSessionCanBeFoundAndClears() throws {
        let patient = try store.createPatient(name: "Test Patient")
        let session = try store.createSession(for: patient)
        try setAside(session.id.uuidString)
        try setAside(UUID().uuidString) // still unknown
        let model = SetAsideRecordings(stagingRoot: stagingRoot, center: .default)
        XCTAssertEqual(model.items.count, 2)

        XCTAssertEqual(OrphanAudioSweep.retrySetAside(store: store, protector: protector, stagingRoot: stagingRoot), 1)

        XCTAssertEqual(model.items.count, 1, "the one whose session is still missing stays")
        let sealed = store.micRecordingURL(for: patient, session: session)
        XCTAssertTrue(ChunkedCipher.isEnvelope(fileAt: sealed))
    }

    func testTryAgainLeavesASessionBeingRecordedAlone() throws {
        let patient = try store.createPatient(name: "Test Patient")
        let session = try store.createSession(for: patient)
        let dir = try setAside(session.id.uuidString)
        try FileManager.default.createDirectory(at: Store.stagingDir(for: session.id, in: stagingRoot), withIntermediateDirectories: true)

        XCTAssertEqual(OrphanAudioSweep.retrySetAside(store: store, protector: protector, stagingRoot: stagingRoot), 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
    }

    func testASetAsideTakeNeverReplacesTheSessionsOwnRecording() throws {
        let patient = try store.createPatient(name: "Test Patient")
        let session = try store.createSession(for: patient)
        let existing = store.micRecordingURL(for: patient, session: session)
        let plain = tempDir.appendingPathComponent("newer.caf")
        try Data("newer take".utf8).write(to: plain)
        try protector.sealLargeFile(from: plain, to: existing)
        let before = try Data(contentsOf: existing)
        let dir = try setAside(session.id.uuidString)

        OrphanAudioSweep.sweep(store: store, protector: protector, stagingRoot: stagingRoot, temporaryDirectory: tempDir)

        XCTAssertEqual(try Data(contentsOf: existing), before)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path), "kept set aside")
    }

    func testRecoverIntoAChosenSessionSealsItAndClears() throws {
        let patient = try store.createPatient(name: "Test Patient")
        let session = try store.createSession(for: patient)
        let dir = try setAside(UUID().uuidString) // recorded for a session that's gone
        let model = SetAsideRecordings(stagingRoot: stagingRoot, center: .default)
        XCTAssertEqual(model.items.count, 1)

        try OrphanAudioSweep.recoverSetAside(dir, into: patient, session: session, store: store, protector: protector, stagingRoot: stagingRoot)

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertTrue(ChunkedCipher.isEnvelope(fileAt: store.micRecordingURL(for: patient, session: session)))
    }

    func testRecoverIntoASessionThatHasARecordingIsRefused() throws {
        let patient = try store.createPatient(name: "Test Patient")
        let session = try store.createSession(for: patient)
        try Data("existing".utf8).write(to: store.callRecordingURL(for: patient, session: session))
        let dir = try setAside()

        XCTAssertThrowsError(try OrphanAudioSweep.recoverSetAside(dir, into: patient, session: session, store: store, protector: protector, stagingRoot: stagingRoot))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("mic.caf").path))
    }

    func testDeleteRemovesItAndClears() throws {
        try setAside()
        let model = SetAsideRecordings(stagingRoot: stagingRoot, center: center)
        let item = try XCTUnwrap(model.items.first)

        try model.delete(item, audit: nil)

        XCTAssertTrue(model.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: item.folder.path))
    }

    // MARK: - Settings

    func testTheWarningOpensTheSetAsidePane() {
        XCTAssertEqual(SettingsRequest.setAsideRecordings.pane, .setAsideRecordings)
    }

    func testThePaneShowsOnlyWhileSomethingIsSetAside() {
        XCTAssertFalse(SettingsPane.available(encryptionOffered: true).contains(.setAsideRecordings))
        let shown = SettingsPane.available(encryptionOffered: true, hasSetAsideRecordings: true)
        XCTAssertTrue(shown.contains(.setAsideRecordings))
        // Once resolved, a remembered pane falls back rather than showing an empty one.
        XCTAssertEqual(SettingsPane.restored(rawValue: "setAsideRecordings", in: SettingsPane.available(encryptionOffered: true)), .default)
    }
}
