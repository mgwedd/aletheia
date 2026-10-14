import XCTest
@testable import Aletheia

final class ChatMemoryTests: XCTestCase {
    private let q1 = ChatMessage(role: .user, text: "First question")
    private let a1 = ChatMessage(role: .assistant, text: "First answer")
    private let summary = ChatMessage(role: .summary, text: "Earlier: asked about sleep.")
    private let q2 = ChatMessage(role: .user, text: "Second question")

    func testSummaryStandsInForEverythingBeforeIt() {
        let all = ChatMemory.remembered([q1, a1, summary, q2])
        XCTAssertEqual(all.summary, summary.text)
        XCTAssertEqual(all.recent, [q2])
        XCTAssertNil(ChatMemory.remembered([q1, a1]).summary)
    }

    func testCompactsOnlyPastTheBudget() {
        XCTAssertFalse(ChatMemory.needsCompaction([q1, a1]))
        let long = ChatMessage(role: .assistant, text: String(repeating: "x", count: ChatMemory.budget + 1))
        XCTAssertTrue(ChatMemory.needsCompaction([q1, long]))
        XCTAssertFalse(ChatMemory.needsCompaction([q1, long, summary]))
    }

    func testCompactCommand() {
        XCTAssertEqual(ChatMemory.compactCommand("/compact"), "")
        XCTAssertEqual(ChatMemory.compactCommand(" /compact  sleep and mood "), "sleep and mood")
        XCTAssertNil(ChatMemory.compactCommand("/compactly"))
        XCTAssertNil(ChatMemory.compactCommand("what about /compact"))
    }

    func testPromptsCarryTheSummaryAndEveryLaterMessageOnce() {
        let history = (1...10).map { ChatMessage(role: .user, text: "message \($0)") } + [summary, q2]
        let prompt = Prompts.sessionChat(transcript: "T.", history: history + [ChatMessage(role: .user, text: "Now?")], question: "Now?")
        XCTAssertTrue(prompt.contains("Summary of the earlier conversation:\n\(summary.text)"))
        XCTAssertTrue(prompt.contains("Therapist: Second question"))
        XCTAssertFalse(prompt.contains("message 1"))
        XCTAssertEqual(prompt.components(separatedBy: "Now?").count - 1, 1)
        // No silent cut: a long conversation without a summary goes in whole.
        let long = (1...10).map { ChatMessage(role: .user, text: "turn \($0)") }
        XCTAssertTrue(Prompts.patientChat(context: "C", history: long, question: "Q").contains("turn 1\n"))
    }

    func testCompactionPromptCarriesTheFocus() {
        let prompt = Prompts.compactChat(history: [q1, a1], focus: "sleep")
        XCTAssertTrue(prompt.contains("in full detail: sleep"))
        XCTAssertTrue(prompt.contains("Therapist: First question"))
        XCTAssertFalse(Prompts.compactChat(history: [q1], focus: "").contains("in full detail"))
    }
}
