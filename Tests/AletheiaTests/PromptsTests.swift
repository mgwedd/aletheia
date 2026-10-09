import XCTest
@testable import Aletheia

final class PromptsTests: XCTestCase {
    func testSummarizeIncludesTranscript() {
        let prompt = Prompts.summarize(transcript: "Patient discussed work stress.")
        XCTAssertTrue(prompt.contains("Patient discussed work stress."))
    }

    func testSessionChatOmitsHistorySectionWhenEmpty() {
        let prompt = Prompts.sessionChat(transcript: "Some transcript.", history: [], question: "How did they seem?")
        XCTAssertTrue(prompt.contains("Some transcript."))
        XCTAssertTrue(prompt.contains("How did they seem?"))
        XCTAssertFalse(prompt.contains("Recent conversation:"))
    }

    func testSessionChatIncludesRecentHistory() {
        let history = [
            ChatMessage(role: .user, text: "Earlier question"),
            ChatMessage(role: .assistant, text: "Earlier answer"),
        ]
        let prompt = Prompts.sessionChat(transcript: "T.", history: history, question: "Follow-up?")
        XCTAssertTrue(prompt.contains("Recent conversation:"))
        XCTAssertTrue(prompt.contains("Earlier question"))
        XCTAssertTrue(prompt.contains("Earlier answer"))
    }

    func testPatientChatIncludesContextAndCitationInstruction() {
        let prompt = Prompts.patientChat(context: "===== Session January 1, 2026 =====\nHello.", history: [], question: "When did we last meet?")
        XCTAssertTrue(prompt.contains("Session January 1, 2026"))
        XCTAssertTrue(prompt.localizedCaseInsensitiveContains("cite"))
    }

    // MARK: - Transcript legend

    func testLegendExplainsLabelsOverlapAndOrdering() {
        let legend = Prompts.transcriptLegend
        XCTAssertTrue(legend.contains("not from voice analysis"))
        XCTAssertTrue(legend.contains("\"Call audio\" is normally the client"))
        XCTAssertTrue(legend.contains("both people may appear as \"Therapist\""))
        XCTAssertTrue(legend.contains("(overlapping)"))
        XCTAssertTrue(legend.contains("approximate"))
    }

    func testEveryTranscriptPromptContainsTheLegend() {
        let history: [ChatMessage] = []
        let prompts = [
            Prompts.summarize(transcript: "T."),
            Prompts.progressNote(format: .soap, transcript: "T."),
            Prompts.progressNote(format: .narrative, transcript: "T."),
            Prompts.sessionChat(transcript: "T.", history: history, question: "Q?"),
            Prompts.patientChat(context: "===== Session [S1] January 1, 2026 =====\nT.", history: history, question: "Q?"),
        ]
        for prompt in prompts {
            XCTAssertTrue(prompt.contains(Prompts.transcriptLegend))
        }
    }
}
