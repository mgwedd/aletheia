import CryptoKit
import XCTest
@testable import SessionNotes

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
        store.addComment(patientSlug: "p", sessionFolder: "s", quotedText: "q", body: "b")
        _ = store.saveNote(patientSlug: "p", sessionFolder: "s", text: "note body")
        store.saveChatThread(ChatThread(title: "Thread"), patientSlug: "p")

        let snapshot = try XCTUnwrap(
            DatabaseSnapshotManager(root: tempRoot).makeSnapshot(of: store, reason: "test")
        )
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))

        // Open the snapshot as its own database and confirm the rows are there.
        let otherRoot = tempRoot.appendingPathComponent("reopened", isDirectory: true)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: snapshot, to: CommentStore.databaseURL(root: otherRoot))
        let reopened = try XCTUnwrap(CommentStore(root: otherRoot))

        XCTAssertEqual(reopened.comments(patientSlug: "p", sessionFolder: "s").map(\.body), ["b"])
        XCTAssertEqual(reopened.note(patientSlug: "p", sessionFolder: "s"), "note body")
        XCTAssertEqual(reopened.chatThreads(patientSlug: "p").map(\.title), ["Thread"])
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
        var snapshot: URL!

        // Scope the store so ARC closes its connection before we restore.
        do {
            let store = try makeStore()
            _ = store.saveNote(patientSlug: "p", sessionFolder: "s", text: "original")
            snapshot = try XCTUnwrap(manager.makeSnapshot(of: store, reason: "before-edit"))
            _ = store.saveNote(patientSlug: "p", sessionFolder: "s", text: "edited-after-snapshot")
        }

        XCTAssertTrue(manager.restore(snapshot, to: liveURL))

        let reopened = try XCTUnwrap(CommentStore(root: tempRoot))
        XCTAssertEqual(reopened.note(patientSlug: "p", sessionFolder: "s"), "original",
                       "restore rolls the live DB back to the snapshot")
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path),
                      "the snapshot file survives a restore")
    }

    func testSnapshotOfSealedDatabaseStaysSealed() throws {
        let keyed = FileProtector(key: SymmetricKey(size: .bits256))
        let store = try XCTUnwrap(CommentStore(root: tempRoot, protector: keyed))
        _ = store.saveNote(patientSlug: "p", sessionFolder: "s", text: "confidential detail")

        let snapshot = try XCTUnwrap(
            DatabaseSnapshotManager(root: tempRoot).makeSnapshot(of: store, reason: "sealed")
        )
        let bytes = try Data(contentsOf: snapshot)
        XCTAssertNil(bytes.range(of: Data("confidential detail".utf8)),
                     "a snapshot of a sealed DB must not contain plaintext PHI")
    }
}
