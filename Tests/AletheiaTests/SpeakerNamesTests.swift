import XCTest
@testable import Aletheia

final class SpeakerNamesTests: XCTestCase {
    // MARK: - First name

    func testFirstNameIsFirstWord() {
        XCTAssertEqual(Prompts.clientFirstName("Jane Doe"), "Jane")
        XCTAssertEqual(Prompts.clientFirstName("Mary Ann Smith"), "Mary")
        XCTAssertEqual(Prompts.clientFirstName("Jane"), "Jane")
    }

    func testFirstNameHandlesEmptyAndWhitespace() {
        XCTAssertEqual(Prompts.clientFirstName(""), "")
        XCTAssertEqual(Prompts.clientFirstName("   \n "), "")
        XCTAssertEqual(Prompts.clientFirstName("  Jane   Doe "), "Jane")
        XCTAssertEqual(Prompts.clientFirstName("Jane\tDoe"), "Jane")
    }

    // MARK: - Prompts

    func testLegendNamesBothSpeakers() {
        let legend = Prompts.legend(clientName: "Jane Doe")
        XCTAssertTrue(legend.contains("\"Jane\""))
        XCTAssertFalse(legend.contains("Doe"))
        XCTAssertTrue(legend.contains("Never write \"Y\""))
        XCTAssertTrue(legend.contains("\"You\""))
    }

    func testLegendFallsBackToTheClient() {
        XCTAssertTrue(Prompts.legend(clientName: "  ").contains("the client"))
        XCTAssertEqual(Prompts.legend(clientName: ""), Prompts.transcriptLegend)
    }

    func testEveryTranscriptPromptCarriesTheName() {
        let history: [ChatMessage] = []
        let prompts = [
            Prompts.summarize(transcript: "T.", clientName: "Jane Doe"),
            Prompts.progressNote(format: .soap, transcript: "T.", clientName: "Jane Doe"),
            Prompts.sessionChat(transcript: "T.", history: history, question: "Q?", clientName: "Jane Doe"),
            Prompts.patientChat(context: "T.", history: history, question: "Q?", clientName: "Jane Doe"),
            Prompts.noteCheck(draft: "D", material: "M", clientName: "Jane Doe"),
        ]
        for prompt in prompts {
            XCTAssertTrue(prompt.contains(Prompts.legend(clientName: "Jane Doe")))
            XCTAssertTrue(prompt.contains("Never write \"Y\""))
        }
    }

    func testServiceThreadsClientNameIntoPrompt() async throws {
        let fake = NameFake()
        var service = AssistantService(assistant: fake, model: "m")
        service.clientName = "Jane Doe"
        _ = try await service.progressNote(format: .narrative, transcript: "[00:01] You: Hi.")
        XCTAssertTrue(fake.lastPrompt?.contains("\"Jane\"") ?? false)
    }

    // MARK: - Scrub

    func testScrubReplacesLabels() {
        let out = SpeakerCodes.scrub("Y: How was the week?\nC~: Fine.\n- Y: ok\n**C**: yes\n[03:10] C: Hello", clientName: "Jane Doe")
        XCTAssertEqual(out, "You: How was the week?\nJane: Fine.\n- You: ok\n**Jane**: yes\n[03:10] Jane: Hello")
    }

    func testScrubReplacesSentenceOpeningCodeWithVerb() {
        XCTAssertEqual(SpeakerCodes.scrub("Y said hello. C reported poor sleep.", clientName: "Jane Doe"),
                       "You said hello. Jane reported poor sleep.")
        XCTAssertEqual(SpeakerCodes.scrub("C felt anxious.", clientName: ""), "the client felt anxious.")
    }

    func testScrubLeavesFalsePositivesAlone() {
        let samples = [
            "Plot the Y-axis against time.",
            "She started Plan C said the doctor.",
            "Vitamin C: 500 mg daily.",
            "Hepatitis C was ruled out.",
            "Dr. C said to rest.",
            "Initials J.C. said it.",
            "Option Y: wait and see.",
            "The Y chromosome.",
            "Their C grade improved.",
        ]
        for s in samples {
            XCTAssertEqual(SpeakerCodes.scrub(s, clientName: "Jane Doe"), s, s)
        }
    }

    func testScrubIsIdempotent() {
        let once = SpeakerCodes.scrub("Y: hi\nC: yo", clientName: "Jane")
        XCTAssertEqual(SpeakerCodes.scrub(once, clientName: "Jane"), once)
    }
}

private final class NameFake: Assistant, @unchecked Sendable {
    var lastPrompt: String?
    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { [] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String {
        lastPrompt = prompt
        return "ok"
    }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}
