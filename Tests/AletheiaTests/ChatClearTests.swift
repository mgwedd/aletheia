import XCTest
@testable import Aletheia

/// Clearing a session's Ask chat, clearing one patient chat, and deleting all of them.
final class ChatClearTests: XCTestCase {
    private var root: URL!
    private var store: Store!
    private var patient: Patient!
    private var audits: [(AuditAction, String?)] = []

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChatClearTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        store = Store(root: root, protector: .passthrough)
        store.onAudit = { [unowned self] action, _, detail in audits.append((action, detail?.text)) }
        patient = try store.createPatient(name: "Dana Cole")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testClearingASessionChatEmptiesItAndLogsIt() throws {
        let session = try store.createSession(for: patient)
        let other = try store.createSession(for: patient)
        try store.saveSessionChat([ChatMessage(role: .user, text: "Sleep?")], for: patient, session: session)
        try store.saveSessionChat([ChatMessage(role: .user, text: "Work?")], for: patient, session: other)
        audits.removeAll()

        try store.clearSessionChat(for: patient, session: session)

        XCTAssertTrue(store.loadSessionChat(for: patient, session: session).isEmpty)
        XCTAssertEqual(store.loadSessionChat(for: patient, session: other).map(\.text), ["Work?"], "only that session's chat is cleared")
        XCTAssertEqual(audits.filter { $0.0 == .phiDeleted }.count, 1)
        XCTAssertEqual(audits.first?.1, AuditDetail.sessionChat.text)
    }

    func testClearingAnEmptySessionChatLogsNothing() throws {
        let session = try store.createSession(for: patient)
        audits.removeAll()

        try store.clearSessionChat(for: patient, session: session)

        XCTAssertTrue(audits.isEmpty)
    }

    func testClearingAThreadKeepsItInTheList() throws {
        let thread = ChatThread(title: "Sleep", messages: [ChatMessage(role: .user, text: "Sleep?")])
        try store.saveChatThread(thread, for: patient)

        try store.clearChatThread(thread, for: patient)

        let threads = store.loadChatThreads(for: patient)
        XCTAssertEqual(threads.map(\.id), [thread.id])
        XCTAssertEqual(threads.first?.messages, [])
    }

    func testDeletingAllThreadsRemovesOnlyThatPatientsChats() throws {
        let other = try store.createPatient(name: "Lee Park")
        try store.saveChatThread(ChatThread(title: "A", messages: []), for: patient)
        try store.saveChatThread(ChatThread(title: "B", messages: []), for: patient)
        try store.saveChatThread(ChatThread(title: "C", messages: []), for: other)

        try store.deleteChatThreads(for: patient)

        XCTAssertTrue(store.loadChatThreads(for: patient).isEmpty)
        XCTAssertEqual(store.loadChatThreads(for: other).map(\.title), ["C"])
    }
}
