import CryptoKit
import XCTest
@testable import SessionNotes

/// Store-level behavior of the multi-thread patient chat: CRUD, recent-first
/// ordering, one-time import of the legacy single-thread file, and that thread
/// files seal at rest / migrate like any other PHI.
final class StoreChatThreadTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("StoreChatThreadTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testSaveListDeleteRoundTripOrderedByRecency() throws {
        let store = Store(root: tempRoot)
        let patient = try store.createPatient(name: "Jordan Rivera")
        _ = store.loadChatThreads(for: patient) // establishes the folder (no legacy)

        let older = ChatThread(title: "First",
                               updatedAt: Date(timeIntervalSince1970: 1_000),
                               messages: [ChatMessage(role: .user, text: "a")])
        let newer = ChatThread(title: "Second",
                               updatedAt: Date(timeIntervalSince1970: 2_000),
                               messages: [ChatMessage(role: .user, text: "b")])
        try store.saveChatThread(older, for: patient)
        try store.saveChatThread(newer, for: patient)

        let threads = store.loadChatThreads(for: patient)
        XCTAssertEqual(threads.map(\.title), ["Second", "First"], "most-recently-active first")

        try store.deleteChatThread(id: older.id, for: patient)
        XCTAssertEqual(store.loadChatThreads(for: patient).map(\.title), ["Second"])
    }

    func testLegacyPatientChatIsImportedOnce() throws {
        let store = Store(root: tempRoot)
        let patient = try store.createPatient(name: "Alex Doe")
        let legacy = [
            ChatMessage(role: .user, text: "How has sleep been?"),
            ChatMessage(role: .assistant, text: "Improving over three weeks."),
        ]
        try store.savePatientChat(legacy, for: patient)

        let threads = store.loadChatThreads(for: patient)
        XCTAssertEqual(threads.count, 1)
        XCTAssertEqual(threads[0].messages.map(\.text), legacy.map(\.text))
        XCTAssertEqual(threads[0].displayTitle, "How has sleep been?")

        // Deleting the imported thread must not trigger a re-import next load.
        try store.deleteChatThread(id: threads[0].id, for: patient)
        XCTAssertEqual(store.loadChatThreads(for: patient).count, 0)
    }

    func testThreadFileIsSealedAtRestButRoundTrips() throws {
        let key = SymmetricKey(size: .bits256)
        let store = Store(root: tempRoot, protector: FileProtector(key: key))
        let patient = try store.createPatient(name: "Sensitive")
        let thread = ChatThread(title: "Risk review",
                                messages: [ChatMessage(role: .user, text: "self harm ideation history")])
        try store.saveChatThread(thread, for: patient)

        let file = store.chatThreadsDir(for: patient).appendingPathComponent("\(thread.id.uuidString).json")
        let onDisk = try Data(contentsOf: file)
        XCTAssertTrue(DataCipher.isEnvelope(onDisk))
        XCTAssertNil(onDisk.range(of: Data("self harm".utf8)), "PHI must not appear in plaintext on disk")

        XCTAssertEqual(store.loadChatThreads(for: patient).first?.messages.first?.text,
                       "self harm ideation history")
    }

    func testMigratorSealsAndUnsealsThreadFiles() throws {
        let store = Store(root: tempRoot) // passthrough
        let patient = try store.createPatient(name: "Mira")
        let thread = ChatThread(title: "Grief",
                                messages: [ChatMessage(role: .user, text: "processing loss")])
        try store.saveChatThread(thread, for: patient)
        let file = store.chatThreadsDir(for: patient).appendingPathComponent("\(thread.id.uuidString).json")
        XCTAssertFalse(DataCipher.isEnvelope(try Data(contentsOf: file)))

        let keyed = FileProtector(key: SymmetricKey(size: .bits256))
        _ = DataMigrator.migrate(root: tempRoot, from: .passthrough, to: keyed)
        XCTAssertTrue(DataCipher.isEnvelope(try Data(contentsOf: file)), "enable seals the thread file")

        _ = DataMigrator.migrate(root: tempRoot, from: keyed, to: .passthrough)
        let back = try Data(contentsOf: file)
        XCTAssertFalse(DataCipher.isEnvelope(back), "disable restores plaintext")
        let decoded = try JSONDecoder.sessionNotes.decode(ChatThread.self, from: back)
        XCTAssertEqual(decoded.messages.first?.text, "processing loss")
    }
}
