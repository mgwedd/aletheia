import XCTest
@testable import Aletheia

/// A fake Assistant that records the prompts it's asked to generate from and
/// returns a canned response. Proves the adapter seam: AssistantService and
/// the app's use cases work against any Assistant, not just LlamaAssistant.
private final class FakeAssistant: Assistant, @unchecked Sendable {
    var lastModel: String?
    var lastSystem: String?
    var lastPrompt: String?
    var response = "canned response"

    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { ["fake-model"] }
    func hasModel(_ name: String) async -> Bool { true }

    func generate(model: String, system: String, prompt: String) async throws -> String {
        lastModel = model
        lastSystem = system
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

/// A fake that records the task each request was tagged with.
private final class TaskRecordingAssistant: Assistant, @unchecked Sendable {
    var tasks: [AITask] = []
    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { ["m"] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String { "" }
    func generate(model: String, system: String, prompt: String, task: AITask) async throws -> String {
        tasks.append(task)
        return ""
    }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}

final class AssistantServiceTaskTagTests: XCTestCase {
    func testServiceTagsRequestsWithTheirTask() async throws {
        let fake = TaskRecordingAssistant()
        let service = AssistantService(assistant: fake, model: "m")
        _ = try await service.summarize(transcript: "t")
        _ = try await service.answerAboutPatient(context: "c", history: [], question: "q")
        XCTAssertEqual(fake.tasks, [.note, .chat])
    }
}
