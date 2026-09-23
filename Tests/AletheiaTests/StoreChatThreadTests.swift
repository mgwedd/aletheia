import AletheiaCore
import CryptoKit
import XCTest
@testable import Aletheia

/// Behavior of the multi-thread patient chat now that threads live in the
/// SQLite store rather than one JSON file each: CRUD, recent-first ordering,
/// per-patient isolation, one-time import of the legacy on-disk formats, and
/// that the message payload is sealed at rest / migrates like any other PHI.
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

    private var dbURL: URL { tempRoot.appendingPathComponent("Aletheia.sqlite") }

    /// Whether the raw database file contains the given plaintext anywhere —
    /// used to prove PHI is (or isn't) sealed in the file.
    private func dbContainsPlaintext(_ text: String) throws -> Bool {
        try Data(contentsOf: dbURL).range(of: Data(text.utf8)) != nil
    }

    func testSaveListDeleteRoundTripOrderedByRecency() throws {
        let store = Store(root: tempRoot)
        let patient = try store.createPatient(name: "Jordan Rivera")

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
        XCTAssertEqual(threads.first?.messages.map(\.text), ["b"], "messages round-trip")

        try store.deleteChatThread(id: older.id, for: patient)
        XCTAssertEqual(store.loadChatThreads(for: patient).map(\.title), ["Second"])
    }

    func testSavingSameIdUpdatesInPlace() throws {
        let store = Store(root: tempRoot)
        let patient = try store.createPatient(name: "Sam")
        var thread = ChatThread(title: "Draft", messages: [ChatMessage(role: .user, text: "first")])
        try store.saveChatThread(thread, for: patient)

        thread.title = "Renamed"
        thread.messages.append(ChatMessage(role: .assistant, text: "second"))
        thread.updatedAt = Date()
        try store.saveChatThread(thread, for: patient)

        let threads = store.loadChatThreads(for: patient)
        XCTAssertEqual(threads.count, 1, "same id updates rather than duplicating")
        XCTAssertEqual(threads.first?.title, "Renamed")
        XCTAssertEqual(threads.first?.messages.map(\.text), ["first", "second"])
    }

    func testThreadsAreIsolatedPerPatient() throws {
        let store = Store(root: tempRoot)
        let a = try store.createPatient(name: "Patient A")
        let b = try store.createPatient(name: "Patient B")
        try store.saveChatThread(ChatThread(title: "A-thread"), for: a)
        try store.saveChatThread(ChatThread(title: "B-thread"), for: b)

        XCTAssertEqual(store.loadChatThreads(for: a).map(\.title), ["A-thread"])
        XCTAssertEqual(store.loadChatThreads(for: b).map(\.title), ["B-thread"])
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

        // The legacy file is retired once imported…
        let legacyFile = store.patientDir(for: patient).appendingPathComponent("patient_chat.json")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))

        // …so deleting the imported thread must not trigger a re-import.
        try store.deleteChatThread(id: threads[0].id, for: patient)
        XCTAssertEqual(store.loadChatThreads(for: patient).count, 0)
    }

    func testLegacyThreadFilesAreImportedAndRemoved() throws {
        let store = Store(root: tempRoot)
        let patient = try store.createPatient(name: "Casey")

        // Synthesize the pre-offload on-disk format: one JSON file per thread.
        let dir = store.chatThreadsDir(for: patient)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let onDisk = ChatThread(title: "Risk history",
                                updatedAt: Date(timeIntervalSince1970: 5_000),
                                messages: [ChatMessage(role: .user, text: "prior hospitalizations")])
        let data = try JSONEncoder.aletheia.encode(onDisk)
        try data.write(to: dir.appendingPathComponent("\(onDisk.id.uuidString).json"))

        let threads = store.loadChatThreads(for: patient)
        XCTAssertEqual(threads.map(\.title), ["Risk history"])
        XCTAssertEqual(threads.first?.messages.first?.text, "prior hospitalizations")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path),
                       "the ChatThreads folder is removed after import")
    }

    func testThreadIsSealedAtRestButRoundTrips() throws {
        let key = SymmetricKey(size: .bits256)
        let store = Store(root: tempRoot, protector: FileProtector(key: key))
        let patient = try store.createPatient(name: "Sensitive")
        let thread = ChatThread(title: "Risk review",
                                messages: [ChatMessage(role: .user, text: "self harm ideation history")])
        try store.saveChatThread(thread, for: patient)

        XCTAssertFalse(try dbContainsPlaintext("self harm"),
                       "PHI must not appear in plaintext in the database file")
        XCTAssertFalse(try dbContainsPlaintext("Risk review"),
                       "the title is PHI too and must be sealed")
        XCTAssertEqual(store.loadChatThreads(for: patient).first?.messages.first?.text,
                       "self harm ideation history")
    }

    func testMigratorReencryptsChatThreadColumn() throws {
        let store = Store(root: tempRoot) // passthrough
        let patient = try store.createPatient(name: "Mira")
        let thread = ChatThread(title: "Grief",
                                messages: [ChatMessage(role: .user, text: "processing loss")])
        try store.saveChatThread(thread, for: patient)
        XCTAssertTrue(try dbContainsPlaintext("processing loss"), "passthrough stores plaintext")

        let keyed = FileProtector(key: SymmetricKey(size: .bits256))
        _ = DataMigrator.migrate(root: tempRoot, from: .passthrough, to: keyed)
        XCTAssertFalse(try dbContainsPlaintext("processing loss"),
                       "enabling encryption seals the chat-thread column (no plaintext left behind)")

        _ = DataMigrator.migrate(root: tempRoot, from: keyed, to: .passthrough)
        XCTAssertTrue(try dbContainsPlaintext("processing loss"), "disabling restores plaintext")

        // And it still reads back through a freshly opened store.
        let reopened = Store(root: tempRoot)
        XCTAssertEqual(reopened.loadChatThreads(for: patient).first?.messages.first?.text,
                       "processing loss")
    }
}
