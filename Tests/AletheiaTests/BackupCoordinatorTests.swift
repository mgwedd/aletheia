import CryptoKit
import XCTest
@testable import Aletheia

/// The consistent-backup path: "Back up now" snapshots the live database and
/// seals the snapshot (not the live file), and the sealed archive restores to a
/// working store with its records intact.
final class BackupCoordinatorTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeStore(_ name: String) throws -> (store: CommentStore, root: URL) {
        let root = tempRoot.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (try XCTUnwrap(CommentStore(root: root)), root)
    }

    func testBackUpNowSealsAConsistentSnapshotThatRestores() async throws {
        let (store, _) = try makeStore("live")
        let session = UUID()
        store.addComment(sessionID: session, quotedText: "q", body: "hello world")
        store.saveNote(sessionID: session, text: "a private note")

        let key = SymmetricKey(size: .bits256)
        let service = LocalEncryptedBackupService(root: tempRoot.appendingPathComponent("backups"), key: key)
        let coordinator = BackupCoordinator(store: store, destination: service)

        guard case let .success(archive) = await coordinator.backUpNow(reason: "manual") else {
            return XCTFail("backup should succeed")
        }
        XCTAssertTrue(EncryptedBackupArchive.isArchive(archive))
        // The sealed archive must not carry the note's plaintext.
        let bytes = try Data(contentsOf: archive)
        XCTAssertNil(bytes.range(of: Data("a private note".utf8)), "archive must be opaque at rest")

        // Restore into a fresh data folder, reopen, and the annotations survive.
        let restoreRoot = tempRoot.appendingPathComponent("restore", isDirectory: true)
        try FileManager.default.createDirectory(at: restoreRoot, withIntermediateDirectories: true)
        guard case .success = await coordinator.restoreLatest(to: CommentStore.databaseURL(root: restoreRoot)) else {
            return XCTFail("restore should succeed")
        }
        let reopened = try XCTUnwrap(CommentStore(root: restoreRoot))
        XCTAssertEqual(reopened.comments(sessionID: session).map(\.body), ["hello world"])
        XCTAssertEqual(reopened.note(sessionID: session), "a private note")
    }

    func testBackUpLeavesNoTemporarySnapshotBehind() async throws {
        let (store, _) = try makeStore("live2")
        store.addComment(sessionID: UUID(), quotedText: "q", body: "x")
        let service = LocalEncryptedBackupService(root: tempRoot.appendingPathComponent("b2"), key: SymmetricKey(size: .bits256))

        guard case .success = await BackupCoordinator(store: store, destination: service).backUpNow(reason: "manual") else {
            return XCTFail("backup should succeed")
        }
        let strays = (try? FileManager.default.contentsOfDirectory(
            at: FileManager.default.temporaryDirectory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasPrefix("aletheia-backup-") } ?? []
        XCTAssertTrue(strays.isEmpty, "the temp snapshot must be cleaned up: \(strays)")
    }

    func testUnconfiguredDestinationReportsNotConfiguredWithoutSnapshotting() async throws {
        let (store, _) = try makeStore("live3")
        let service = ICloudEncryptedBackupService(key: SymmetricKey(size: .bits256))
        let outcome = await BackupCoordinator(store: store, destination: service).backUpNow(reason: "manual")
        XCTAssertEqual(outcome, .notConfigured)
    }
}
