import XCTest
@testable import Aletheia

final class PromptTurnTests: XCTestCase {
    func testRecentDropsTheQuestionBeingSentAndEverythingBeforeTheSummary() {
        let history = [
            ChatMessage(role: .user, text: "old"),
            ChatMessage(role: .summary, text: "S"),
            ChatMessage(role: .user, text: "Bullets please."),
            ChatMessage(role: .assistant, text: "- ok"),
            ChatMessage(role: .user, text: "Now?"),
        ]
        XCTAssertEqual(PromptTurn.recent(history, question: "Now?"), [
            PromptTurn(role: .user, text: "Bullets please."),
            PromptTurn(role: .assistant, text: "- ok"),
        ])
        XCTAssertEqual(PromptTurn.recent(history).count, 3)
    }

    /// A reply read from My Notes never goes back to the model.
    func testRecentLeavesOutRepliesFromMyNotes() {
        let history = [
            ChatMessage(role: .user, text: "What have I noted about sleep?"),
            ChatMessage(role: .assistant, text: "> private note", fromMyNotes: true),
            ChatMessage(role: .user, text: "Summarize."),
        ]
        XCTAssertEqual(PromptTurn.recent(history, question: "Summarize."), [
            PromptTurn(role: .user, text: "What have I noted about sleep?"),
        ])
    }

    func testConversationAlternatesAndEndsWithThePrompt() {
        let turns = [
            PromptTurn(role: .assistant, text: "Hello."),
            PromptTurn(role: .user, text: "A"),
            PromptTurn(role: .user, text: "B"),
            PromptTurn(role: .assistant, text: "  "),
        ]
        XCTAssertEqual(PromptTurn.conversation(turns, then: "P"), [
            PromptTurn(role: .user, text: ""),
            PromptTurn(role: .assistant, text: "Hello."),
            PromptTurn(role: .user, text: "A\n\nB\n\nP"),
        ])
    }

    func testFlattenedWritesTurnsBeforeThePrompt() {
        XCTAssertEqual(PromptTurn.flattened([], then: "P"), "P")
        XCTAssertEqual(
            PromptTurn.flattened([PromptTurn(role: .user, text: "Q"), PromptTurn(role: .assistant, text: "A")], then: "P"),
            "Conversation so far:\nTherapist: Q\nAssistant: A\n\nP")
    }

    /// The service hands the chat turns to the backend separately; a backend
    /// without turns gets them written out, so nothing is lost.
    func testServiceSendsTurnsToTheBackend() async throws {
        let spy = TurnSpy()
        let service = AssistantService(assistant: spy, model: "m")
        let history = [
            ChatMessage(role: .user, text: "Answer in bullets from now on."),
            ChatMessage(role: .assistant, text: "- ok"),
            ChatMessage(role: .user, text: "How was sleep?"),
        ]
        _ = try await service.answerAboutPatient(context: "C", history: history, question: "How was sleep?")
        XCTAssertEqual(spy.turns, [
            PromptTurn(role: .user, text: "Answer in bullets from now on."),
            PromptTurn(role: .assistant, text: "- ok"),
        ])
        XCTAssertTrue(spy.prompt.hasSuffix("Therapist's question: How was sleep?"))
        XCTAssertFalse(spy.prompt.contains("Answer in bullets"))
    }
}

private final class TurnSpy: Assistant, @unchecked Sendable {
    var turns: [PromptTurn] = []
    var prompt = ""
    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { ["m"] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String { "" }
    func stream(model: String, system: String, prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func stream(
        model: String, system: String, prompt: String, onStats: (@Sendable (AIRunStats) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { $0.finish() }
    }
    func generate(
        model: String, system: String, turns: [PromptTurn], prompt: String, task: AITask, grammar: LocalLLMGrammar?
    ) async throws -> String {
        self.turns = turns
        self.prompt = prompt
        return "answer"
    }
    func warmUp(model: String) {}
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}
