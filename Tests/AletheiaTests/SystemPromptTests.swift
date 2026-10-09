import XCTest
@testable import Aletheia

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

    // MARK: - Diagrams only on request

    func testDefaultSystemPromptDoesNotOfferDiagrams() {
        XCTAssertFalse(Prompts.defaultSystemPrompt.lowercased().contains("mermaid"))
        XCTAssertFalse(Prompts.defaultSystemPrompt.lowercased().contains("diagram"))
    }

    func testAsksForDiagramMatchesExplicitRequests() {
        for question in [
            "Can you draw a diagram of how these sessions connect?",
            "Make a flowchart of the treatment path",
            "show me a flow chart",
            "Please visualize the themes over time",
            "give me a mermaid diagram",
            "Diagrams of each session?",
        ] {
            XCTAssertTrue(Prompts.asksForDiagram(question), question)
        }
    }

    func testAsksForDiagramIgnoresOrdinaryQuestions() {
        for question in [
            "What did she say about her sleep?",
            "Summarize the last session",
            "Draft a progress note for today",
            "Any paragraph about withdrawal symptoms?",
            "Chart notes: what changed since March?",
        ] {
            XCTAssertFalse(Prompts.asksForDiagram(question), question)
        }
    }

    func testChatSystemPromptAddsGuidanceOnlyWhenAsked() {
        let plain = Prompts.chatSystemPrompt("BASE", question: "What did she say about work?")
        XCTAssertEqual(plain, "BASE")

        let asked = Prompts.chatSystemPrompt("BASE", question: "Draw a diagram of her week")
        XCTAssertTrue(asked.hasPrefix("BASE"))
        XCTAssertTrue(asked.contains(Prompts.diagramGuidance))
    }

    func testChatCallsGateDiagramGuidanceOnTheQuestion() async throws {
        let fake = SystemCapturingAssistant()
        let service = AssistantService(assistant: fake, model: "m", systemPrompt: "BASE")

        _ = try await service.answerAboutSession(transcript: "T", history: [], question: "How was her mood?")
        XCTAssertEqual(fake.lastSystem, "BASE")

        _ = try await service.answerAboutSession(transcript: "T", history: [], question: "Draw a diagram of it")
        XCTAssertTrue(fake.lastSystem?.contains(Prompts.diagramGuidance) == true)

        _ = try await service.answerAboutPatient(context: "C", history: [], question: "How was her mood?")
        XCTAssertEqual(fake.lastSystem, "BASE")

        _ = try await service.answerAboutPatient(context: "C", history: [], question: "visualize her progress")
        XCTAssertTrue(fake.lastSystem?.contains(Prompts.diagramGuidance) == true)

        // Summaries and notes never get diagram guidance.
        _ = try await service.summarize(transcript: "T")
        XCTAssertEqual(fake.lastSystem, "BASE")
    }
}
