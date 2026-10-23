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

    /// The final prompt carries the summary (tagged, model-written) and the
    /// therapist's messages from before it (untagged, still in force); the
    /// messages since the summary are chat turns, not prompt text.
    func testPromptsCarryTheSummaryAndTheTherapistsEarlierRequests() {
        let bullets = ChatMessage(role: .user, text: "Answer in bullets from now on.")
        let history = [bullets, a1, summary, q2, ChatMessage(role: .assistant, text: "Second answer")]
        let prompt = Prompts.sessionChat(transcript: "T.", history: history + [ChatMessage(role: .user, text: "Now?")], question: "Now?")
        XCTAssertTrue(prompt.contains("Summary of the earlier conversation:\n<summary>\n\(summary.text)\n</summary>"))
        XCTAssertTrue(prompt.contains("still applies:\n- Answer in bullets from now on."))
        XCTAssertFalse(prompt.contains("<summary>\n- Answer in bullets"), "her request is not inside the summary's tags")
        XCTAssertFalse(prompt.contains("Second question"), "later messages go in as turns")
        XCTAssertFalse(prompt.contains("First answer"), "the model's earlier answers are not instructions")
        XCTAssertEqual(prompt.components(separatedBy: "Now?").count - 1, 1)
        XCTAssertTrue(prompt.hasSuffix("Therapist's question: Now?"))

        let turns = PromptTurn.recent(history + [ChatMessage(role: .user, text: "Now?")], question: "Now?")
        XCTAssertEqual(turns, [
            PromptTurn(role: .user, text: "Second question"),
            PromptTurn(role: .assistant, text: "Second answer"),
        ])
    }

    func testNoSummaryMeansNoEarlierBlock() {
        let long = (1...10).map { ChatMessage(role: .user, text: "turn \($0)") }
        let prompt = Prompts.patientChat(context: "C", history: long, question: "Q")
        XCTAssertFalse(prompt.contains("turn 1"))
        XCTAssertFalse(prompt.contains("Summary of the earlier conversation"))
        // Every turn is kept, none cut.
        XCTAssertEqual(PromptTurn.recent(long).count, 10)
        XCTAssertEqual(PromptTurn.conversation(PromptTurn.recent(long), then: "Q").count, 1, "consecutive user turns merge into one")
        XCTAssertTrue(PromptTurn.conversation(PromptTurn.recent(long), then: "Q").first!.text.contains("turn 1\n\nturn 2"))
    }

    func testCompactionPromptCarriesTheFocusAndEarlierRequests() {
        let prompt = Prompts.compactChat(history: [q1, a1], focus: "sleep")
        XCTAssertTrue(prompt.contains("in full detail: sleep"))
        XCTAssertFalse(prompt.contains("First question"), "the conversation goes in as turns")
        XCTAssertFalse(Prompts.compactChat(history: [q1], focus: "").contains("in full detail"))
        let again = Prompts.compactChat(history: [ChatMessage(role: .user, text: "Be brief."), summary, q2], focus: "")
        XCTAssertTrue(again.contains("- Be brief."))
        XCTAssertTrue(again.contains("<summary>\n\(summary.text)\n</summary>"))
        XCTAssertTrue(again.contains(Prompts.materialRule))
        XCTAssertEqual(PromptTurn.recent([ChatMessage(role: .user, text: "Be brief."), summary, q2]), [PromptTurn(role: .user, text: "Second question")])
    }

    func testHasHistoryOnceThereIsAMessageOrASummary() {
        XCTAssertFalse(ChatMemory.hasHistory([]))
        XCTAssertTrue(ChatMemory.hasHistory([q1]))
        XCTAssertTrue(ChatMemory.hasHistory([summary]))
    }

    /// The pane no longer narrates what the next answer will remember.
    func testChatPaneHasNoRemembersLine() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["Sources/App/Services/ChatMemory.swift", "Sources/App/Views/ChatPaneView.swift"] {
            let source = try String(contentsOf: file.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(source.contains("Remembers the whole conversation"), path)
            XCTAssertFalse(source.contains("Remembers a summary"), path)
        }
    }
}
