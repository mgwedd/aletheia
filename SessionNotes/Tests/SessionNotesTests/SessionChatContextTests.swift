import XCTest
@testable import SessionNotes

private final class CapturingAssistant: Assistant, @unchecked Sendable {
    var lastPrompt: String?
    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { [] }
    func hasModel(_ name: String) async -> Bool { true }
    var lastSystem: String?
    func generate(model: String, system: String, prompt: String) async throws -> String { lastSystem = system; lastPrompt = prompt; return "ok" }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}

final class SessionChatContextTests: XCTestCase {
    func testPromptIncludesTherapistNotesAndComments() {
        let prompt = Prompts.sessionChat(
            transcript: "Patient discussed sleep.",
            notes: "She seemed brighter today.",
            comments: ["- On “sleep”: worse since the move"],
            history: [],
            question: "How was her mood?"
        )
        XCTAssertTrue(prompt.contains("Therapist's session notes:"))
        XCTAssertTrue(prompt.contains("She seemed brighter today."))
        // The section header (not the instruction text) is what's conditional.
        XCTAssertTrue(prompt.contains("Therapist's margin comments on the transcript:"))
        XCTAssertTrue(prompt.contains("worse since the move"))
    }

    func testPromptOmitsSectionsWhenNoAnnotations() {
        let prompt = Prompts.sessionChat(transcript: "T", history: [], question: "Q")
        // Assert on the section headers, which only appear when annotations
        // exist — the prompt's static instructions mention "margin comments".
        XCTAssertFalse(prompt.contains("Therapist's session notes:"))
        XCTAssertFalse(prompt.contains("Therapist's margin comments on the transcript:"))
    }

    func testAnswerAboutSessionForwardsNotesAndComments() async throws {
        let fake = CapturingAssistant()
        let service = AssistantService(assistant: fake, model: "m")
        let comments = [SessionComment(id: "1", quotedText: "meds", body: "titrate up", createdAt: .init(), updatedAt: .init())]

        _ = try await service.answerAboutSession(
            transcript: "T",
            notes: "note text",
            comments: comments,
            history: [],
            question: "Q"
        )

        let prompt = try XCTUnwrap(fake.lastPrompt)
        XCTAssertTrue(prompt.contains("note text"))
        XCTAssertTrue(prompt.contains("titrate up"))
        XCTAssertTrue(prompt.contains("meds"))
    }
}
