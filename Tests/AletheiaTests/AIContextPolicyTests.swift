import XCTest
@testable import Aletheia

final class AIContextPolicyTests: XCTestCase {
    func testNoUseIncludesThePsychotherapyNote() {
        for use in AIContextPolicy.Use.allCases {
            XCTAssertFalse(AIContextPolicy.includesPsychotherapyNote(for: use), "\(use)")
            XCTAssertEqual(AIContextPolicy.notes("private text", for: use), "", "\(use)")
        }
    }

    func testEmptyStaysEmpty() {
        XCTAssertEqual(AIContextPolicy.notes("", for: .patientChat), "")
    }

    func testBuiltPromptsLeaveThePsychotherapyNoteOut() async throws {
        let fake = CapturingAssistant()
        let service = AssistantService(assistant: fake, model: "m")
        _ = try await service.progressNote(format: .soap, transcript: "T", notes: "PRIVATE-PROCESS-NOTE")
        XCTAssertFalse(try XCTUnwrap(fake.lastPrompt).contains("PRIVATE-PROCESS-NOTE"))
        _ = try await service.answerAboutSession(transcript: "T", notes: "PRIVATE-PROCESS-NOTE", history: [], question: "Q")
        XCTAssertFalse(try XCTUnwrap(fake.lastPrompt).contains("PRIVATE-PROCESS-NOTE"))
    }
}

private final class CapturingAssistant: Assistant, @unchecked Sendable {
    var lastPrompt: String?
    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { [] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String { lastPrompt = prompt; return "ok" }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}
