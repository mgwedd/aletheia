import AletheiaCore
import XCTest
@testable import Aletheia

/// `ChatRepository` against the in-memory core: session-chat singleton
/// upsert/clear, and chat-thread identity, per-patient scoping, recency
/// ordering, and delete. `StoreChatThreadTests`/`SessionChatContextTests`
/// cover the same behaviors end-to-end through `Store`/`CommentStore` on real
/// SQLite; these pin the repository's own contract in isolation.
final class ChatRepositoryTests: XCTestCase {
    private var core: InMemoryPersistenceCore!
    private var repository: ChatRepository!

    override func setUp() {
        super.setUp()
        core = InMemoryPersistenceCore()
        repository = ChatRepository(core: core, protector: .passthrough)
    }

    // MARK: - Session chat

    func testSessionChatIsASingletonUpsertKeyedBySession() {
        let session = UUID()
        let first = [ChatMessage(role: .user, text: "hello")]
        let second = [ChatMessage(role: .user, text: "hello"), ChatMessage(role: .assistant, text: "hi there")]

        XCTAssertTrue(repository.saveSessionChat(first, sessionID: session))
        XCTAssertTrue(repository.saveSessionChat(second, sessionID: session))

        XCTAssertEqual(repository.sessionChat(sessionID: session).map(\.text), second.map(\.text))
        XCTAssertEqual(core.records(kind: "sessionChat", itemID: session).count, 1, "upsert, not a second row")
    }

    func testSessionChatIsIsolatedBySession() {
        let a = UUID(), b = UUID()
        repository.saveSessionChat([ChatMessage(role: .user, text: "A")], sessionID: a)
        repository.saveSessionChat([ChatMessage(role: .user, text: "B")], sessionID: b)

        XCTAssertEqual(repository.sessionChat(sessionID: a).map(\.text), ["A"])
        XCTAssertEqual(repository.sessionChat(sessionID: b).map(\.text), ["B"])
    }

    func testSavingEmptySessionChatClearsIt() {
        let session = UUID()
        repository.saveSessionChat([ChatMessage(role: .user, text: "hi")], sessionID: session)
        XCTAssertFalse(repository.sessionChat(sessionID: session).isEmpty)

        XCTAssertTrue(repository.saveSessionChat([], sessionID: session))
        XCTAssertTrue(repository.sessionChat(sessionID: session).isEmpty)
        XCTAssertNil(core.record(kind: "sessionChat", id: session.uuidString), "an empty chat leaves no row behind")
    }

    func testMissingSessionChatIsEmpty() {
        XCTAssertTrue(repository.sessionChat(sessionID: UUID()).isEmpty)
    }

    // MARK: - Chat threads

    func testChatThreadsOrderedMostRecentlyUpdatedFirst() {
        let patient = UUID()
        let older = ChatThread(title: "First", updatedAt: Date(timeIntervalSince1970: 1_000))
        let newer = ChatThread(title: "Second", updatedAt: Date(timeIntervalSince1970: 2_000))

        XCTAssertTrue(repository.saveChatThread(older, patientID: patient))
        XCTAssertTrue(repository.saveChatThread(newer, patientID: patient))

        XCTAssertEqual(repository.chatThreads(patientID: patient).map(\.title), ["Second", "First"])
    }

    func testChatThreadsAreIsolatedByPatient() {
        let a = UUID(), b = UUID()
        repository.saveChatThread(ChatThread(title: "A-thread"), patientID: a)
        repository.saveChatThread(ChatThread(title: "B-thread"), patientID: b)

        XCTAssertEqual(repository.chatThreads(patientID: a).map(\.title), ["A-thread"])
        XCTAssertEqual(repository.chatThreads(patientID: b).map(\.title), ["B-thread"])
    }

    func testSavingSameThreadIdUpdatesInPlaceAndKeepsCreatedAt() {
        let patient = UUID()
        let createdAt = Date(timeIntervalSince1970: 1_000)
        var thread = ChatThread(title: "Draft", createdAt: createdAt, updatedAt: createdAt,
                                messages: [ChatMessage(role: .user, text: "first")])
        XCTAssertTrue(repository.saveChatThread(thread, patientID: patient))

        thread.title = "Renamed"
        thread.messages.append(ChatMessage(role: .assistant, text: "second"))
        thread.updatedAt = Date(timeIntervalSince1970: 2_000)
        XCTAssertTrue(repository.saveChatThread(thread, patientID: patient))

        let threads = repository.chatThreads(patientID: patient)
        XCTAssertEqual(threads.count, 1, "same id updates rather than duplicating")
        XCTAssertEqual(threads.first?.title, "Renamed")
        XCTAssertEqual(threads.first?.messages.map(\.text), ["first", "second"])
        XCTAssertEqual(core.record(kind: "chatThread", id: thread.id.uuidString)?.createdAt, createdAt,
                       "createdAt is fixed at first insert")
    }

    func testDeleteChatThread() {
        let patient = UUID()
        let thread = ChatThread(title: "Gone")
        repository.saveChatThread(thread, patientID: patient)

        XCTAssertTrue(repository.deleteChatThread(id: thread.id, patientID: patient))
        XCTAssertTrue(repository.chatThreads(patientID: patient).isEmpty)
        XCTAssertTrue(repository.deleteChatThread(id: thread.id, patientID: patient), "deleting an absent thread is not an error")
    }

    func testDeleteChatThreadIgnoresWrongPatient() {
        let owner = UUID(), other = UUID()
        let thread = ChatThread(title: "Owner's")
        repository.saveChatThread(thread, patientID: owner)

        XCTAssertTrue(repository.deleteChatThread(id: thread.id, patientID: other),
                      "matches the original DELETE ... WHERE id AND patient_id semantics: no-op, not an error")
        XCTAssertEqual(repository.chatThreads(patientID: owner).map(\.title), ["Owner's"],
                       "a thread cannot be deleted by the wrong patient")
    }
}
