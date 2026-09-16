import XCTest
@testable import SessionNotes

/// A fake Assistant that records the prompts it's asked to generate from and
/// returns a canned response. Proves the adapter seam: AssistantService and
/// the app's use cases work against any Assistant, not just OllamaClient.
private final class FakeAssistant: Assistant, @unchecked Sendable {
    var lastModel: String?
    var lastPrompt: String?
    var response = "canned response"

    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { ["fake-model"] }
    func hasModel(_ name: String) async -> Bool { true }

    func generate(model: String, prompt: String) async throws -> String {
        lastModel = model
        lastPrompt = prompt
        return response
    }

    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {
        onProgress(1.0, "complete")
    }
}

final class AssistantServiceTests: XCTestCase {
    func testSummarizeUsesModelAndSummaryPrompt() async throws {
        let fake = FakeAssistant()
        fake.response = "the summary"
        let service = AssistantService(assistant: fake, model: "fake-model")

        let result = try await service.summarize(transcript: "Patient discussed sleep.")
        XCTAssertEqual(result, "the summary")
        XCTAssertEqual(fake.lastModel, "fake-model")
        XCTAssertEqual(fake.lastPrompt, Prompts.summarize(transcript: "Patient discussed sleep."))
    }

    func testAnswerAboutSessionBuildsSessionPrompt() async throws {
        let fake = FakeAssistant()
        let service = AssistantService(assistant: fake, model: "m")
        let history = [ChatMessage(role: .user, text: "earlier")]

        _ = try await service.answerAboutSession(transcript: "T", history: history, question: "Q?")
        XCTAssertEqual(fake.lastPrompt, Prompts.sessionChat(transcript: "T", history: history, question: "Q?"))
    }

    func testAnswerAboutPatientBuildsPatientPrompt() async throws {
        let fake = FakeAssistant()
        let service = AssistantService(assistant: fake, model: "m")

        _ = try await service.answerAboutPatient(context: "CTX", history: [], question: "When?")
        XCTAssertEqual(fake.lastPrompt, Prompts.patientChat(context: "CTX", history: [], question: "When?"))
    }
}
