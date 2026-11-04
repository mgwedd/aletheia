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
        // It leads with the answer, without filler.
        XCTAssertTrue(Prompts.defaultSystemPrompt.contains("Lead with the answer"))
    }

    func testServiceForwardsSystemPromptOnEveryCall() async throws {
        let fake = SystemCapturingAssistant()
        let service = AssistantService(assistant: fake, model: "m", systemPrompt: "CUSTOM SYSTEM")

        _ = try await service.summarize(transcript: "T")
        XCTAssertEqual(fake.lastSystem, "CUSTOM SYSTEM")

        // Ask adds its depth's instructions after the standing prompt, then
        // the material the answer rests on.
        let depth = "CUSTOM SYSTEM\n\n" + AnswerDepth.natural.instructions(for: .answer)
        _ = try await service.answerAboutSession(transcript: "T", history: [], question: "Q")
        XCTAssertEqual(fake.lastSystem, depth + "\n\n" + Prompts.sessionChat(transcript: "T", history: []))

        _ = try await service.answerAboutPatient(context: "C", history: [], question: "Q")
        XCTAssertEqual(fake.lastSystem, depth + "\n\n" + Prompts.patientChat(context: "C", history: []))
    }

    func testServiceDefaultsToDefaultSystemPrompt() async throws {
        let fake = SystemCapturingAssistant()
        let service = AssistantService(assistant: fake, model: "m")
        _ = try await service.summarize(transcript: "T")
        XCTAssertEqual(fake.lastSystem, Prompts.defaultSystemPrompt)
    }

    func testDefaultSystemPromptWritesToYouOnceAndAddsNoUnaskedActionItems() {
        let prompt = Prompts.defaultSystemPrompt
        XCTAssertTrue(prompt.contains("Write to them as \"you\""))
        XCTAssertTrue(prompt.contains("Say each point once"))
        XCTAssertTrue(prompt.contains("Suggest action items or homework only if they were agreed or you are asked."))
        XCTAssertTrue(prompt.contains("A thin session gets a short answer."))
    }

    func testASavedEarlierDefaultPromptBecomesTheCurrentOne() {
        let suite = "system-prompt-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for retired in Prompts.retiredSystemPrompts {
            defaults.set(retired, forKey: "systemPrompt")
            XCTAssertEqual(AppSettings(defaults: defaults).systemPrompt, Prompts.defaultSystemPrompt)
        }
        defaults.set("My own prompt.", forKey: "systemPrompt")
        XCTAssertEqual(AppSettings(defaults: defaults).systemPrompt, "My own prompt.")
    }

    func testTheHeadphonesTipIsDueOnceAndRemembered() {
        let suite = "headphones-tip-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertTrue(HeadphonesTip.takeIfDue(settings))
        XCTAssertFalse(HeadphonesTip.takeIfDue(settings))
        XCTAssertFalse(HeadphonesTip.takeIfDue(AppSettings(defaults: defaults)))
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
        XCTAssertEqual(plain, "BASE\n\n" + AnswerDepth.natural.instructions(for: .answer))
        XCTAssertFalse(plain.contains(Prompts.diagramGuidance))

        let asked = Prompts.chatSystemPrompt("BASE", question: "Draw a diagram of her week")
        XCTAssertTrue(asked.hasPrefix("BASE"))
        XCTAssertTrue(asked.contains(Prompts.diagramGuidance))
    }

    func testChatCallsGateDiagramGuidanceOnTheQuestion() async throws {
        let fake = SystemCapturingAssistant()
        let service = AssistantService(assistant: fake, model: "m", systemPrompt: "BASE")

        _ = try await service.answerAboutSession(transcript: "T", history: [], question: "How was her mood?")
        XCTAssertEqual(fake.lastSystem?.contains(Prompts.diagramGuidance), false)

        _ = try await service.answerAboutSession(transcript: "T", history: [], question: "Draw a diagram of it")
        XCTAssertTrue(fake.lastSystem?.contains(Prompts.diagramGuidance) == true)

        _ = try await service.answerAboutPatient(context: "C", history: [], question: "How was her mood?")
        XCTAssertEqual(fake.lastSystem?.contains(Prompts.diagramGuidance), false)

        _ = try await service.answerAboutPatient(context: "C", history: [], question: "visualize her progress")
        XCTAssertTrue(fake.lastSystem?.contains(Prompts.diagramGuidance) == true)

        // Summaries and notes never get diagram guidance.
        _ = try await service.summarize(transcript: "T")
        XCTAssertEqual(fake.lastSystem, "BASE")
    }
}
