import XCTest
@testable import SessionNotes

private final class SystemCapturingAssistant: Assistant, @unchecked Sendable {
    var lastSystem: String?
    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { [] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String {
        lastSystem = system
        return "ok"
    }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}

final class SystemPromptTests: XCTestCase {
    func testDefaultSystemPromptIsSubstantial() {
        XCTAssertFalse(Prompts.defaultSystemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        // Sanity: it carries the app's core guardrail language.
        XCTAssertTrue(Prompts.defaultSystemPrompt.lowercased().contains("never invent"))
    }

    func testServiceForwardsSystemPromptOnEveryCall() async throws {
        let fake = SystemCapturingAssistant()
        let service = AssistantService(assistant: fake, model: "m", systemPrompt: "CUSTOM SYSTEM")

        _ = try await service.summarize(transcript: "T")
        XCTAssertEqual(fake.lastSystem, "CUSTOM SYSTEM")

        _ = try await service.answerAboutSession(transcript: "T", history: [], question: "Q")
        XCTAssertEqual(fake.lastSystem, "CUSTOM SYSTEM")

        _ = try await service.answerAboutPatient(context: "C", history: [], question: "Q")
        XCTAssertEqual(fake.lastSystem, "CUSTOM SYSTEM")
    }

    func testServiceDefaultsToDefaultSystemPrompt() async throws {
        let fake = SystemCapturingAssistant()
        let service = AssistantService(assistant: fake, model: "m")
        _ = try await service.summarize(transcript: "T")
        XCTAssertEqual(fake.lastSystem, Prompts.defaultSystemPrompt)
    }
}
