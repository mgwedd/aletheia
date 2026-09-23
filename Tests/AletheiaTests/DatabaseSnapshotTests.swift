import AletheiaCore
import CryptoKit
import XCTest
@testable import Aletheia

/// Point-in-time snapshots of the SQLite store: that a snapshot is a consistent
/// reopenable copy, that retention prunes to the newest N, and that a restore
/// brings the live database back to the snapshotted state.
final class DatabaseSnapshotTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseSnapshotTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func makeStore() throws -> CommentStore {
        try XCTUnwrap(CommentStore(root: tempRoot))
    }

    func testSnapshotIsConsistentAndReopenable() throws {
        let store = try makeStore()
        let session = UUID()
        let patient = UUID()
        store.addComment(sessionID: session, quotedText: "q", body: "b")
        _ = store.saveNote(sessionID: session, text: "note body")
        store.saveChatThread(ChatThread(title: "Thread"), patientID: patient)

        let snapshot = try XCTUnwrap(
            DatabaseSnapshotManager(root: tempRoot).makeSnapshot(of: store, reason: "test")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))

        // Open the snapshot as its own database and confirm the rows are there.
        let otherRoot = tempRoot.appendingPathComponent("reopened", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: snapshot, to: CommentStore.databaseURL(root: otherRoot))
        let reopened = try XCTUnwrap(CommentStore(root: otherRoot))

        XCTAssertEqual(reopened.comments(sessionID: session).map(\.body), ["b"])
        XCTAssertEqual(reopened.note(sessionID: session), "note body")
        XCTAssertEqual(reopened.chatThreads(patientID: patient).map(\.title), ["Thread"])
    }

    func testRetentionKeepsNewestN() throws {
        let store = try makeStore()
        var manager = DatabaseSnapshotManager(root: tempRoot)
        manager.keep = 2

        // Distinct timestamps (one minute apart) so the names — and the sort —
        // are unambiguous.
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<4 {
            _ = manager.makeSnapshot(of: store, reason: "r\(i)", at: base.addingTimeInterval(Double(i) * 60))
        }

        let remaining = manager.snapshots().map(\.lastPathComponent)
        XCTAssertEqual(remaining.count, 2, "retention keeps only `keep` snapshots")
        XCTAssertTrue(remaining.allSatisfy { $0.contains("-r2") || $0.contains("-r3") },
                      "the two newest survive: \(remaining)")
    }

    func testRestoreReturnsLiveDatabaseToSnapshotState() throws {
        let manager = DatabaseSnapshotManager(root: tempRoot)
        let liveURL = CommentStore.databaseURL(root: tempRoot)
        let session = UUID()
        var snapshot: URL!

        // Scope the store so ARC closes its connection before we restore.
        do {
            let store = try makeStore()
            _ = store.saveNote(sessionID: session, text: "original")
            snapshot = try XCTUnwrap(manager.makeSnapshot(of: store, reason: "before-edit"))
            _ = store.saveNote(sessionID: session, text: "edited-after-snapshot")
        }

        XCTAssertTrue(manager.restore(snapshot, to: liveURL))

        let reopened = try XCTUnwrap(CommentStore(root: tempRoot))
        XCTAssertEqual(reopened.note(sessionID: session), "original",
                       "restore rolls the live DB back to the snapshot")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path),
                      "the snapshot file survives a restore")
    }

    func testSnapshotOfSealedDatabaseStaysSealed() throws {
        let keyed = FileProtector(key: SymmetricKey(size: .bits256))
        let store = try XCTUnwrap(CommentStore(root: tempRoot, protector: keyed))
        _ = store.saveNote(sessionID: UUID(), text: "confidential detail")

        let snapshot = try XCTUnwrap(
            DatabaseSnapshotManager(root: tempRoot).makeSnapshot(of: store, reason: "sealed")
        )
        let bytes = try Data(contentsOf: snapshot)
        XCTAssertNil(bytes.range(of: Data("confidential detail".utf8)),
                     "a snapshot of a sealed DB must not contain plaintext PHI")
    }
}
