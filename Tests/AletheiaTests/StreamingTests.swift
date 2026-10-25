import XCTest
@testable import Aletheia

/// A fake Assistant with no `stream` override, so it exercises the protocol's
/// default batch-fallback streaming (one final emission). Records the prompt.
private final class FakeBatchAssistant: Assistant, @unchecked Sendable {
    var lastPrompt: String?
    var response = "final answer"

    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { ["fake"] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String {
        lastPrompt = prompt
        return response
    }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}

final class StreamSmootherTests: XCTestCase {
    func testSnapsForwardToWordBoundary() {
        // From nothing, the first tick should reveal up to a whitespace, not
        // stop mid-word — "hello " (6 chars), not "hell" (4).
        XCTAssertEqual(StreamSmoother.nextCount(displayed: 0, target: "hello world"), 6)
        XCTAssertEqual(StreamSmoother.prefix(of: "hello world", count: 6), "hello ")
    }

    func testAlwaysAdvancesUntilComplete() {
        let target = "The patient reported improved sleep and lower anxiety this week."
        var displayed = 0
        var ticks = 0
        while displayed < target.count {
            let next = StreamSmoother.nextCount(displayed: displayed, target: target)
            XCTAssertGreaterThan(next, displayed, "reveal must make progress each tick")
            displayed = next
            ticks += 1
            XCTAssertLessThan(ticks, 1000, "reveal must terminate")
        }
        XCTAssertEqual(displayed, target.count)
        XCTAssertEqual(StreamSmoother.prefix(of: target, count: displayed), target)
    }

    func testAdaptiveCatchUpTakesBiggerStepsWhenFarBehind() {
        // A large backlog should reveal more than the base chunk (backlog / 8).
        let long = String(repeating: "word ", count: 40) // 200 chars, spaced
        let step = StreamSmoother.nextCount(displayed: 0, target: long)
        XCTAssertGreaterThan(step, 4, "should reveal more than baseChunk when far behind")
    }

    func testClampsWhenAlreadyComplete() {
        XCTAssertEqual(StreamSmoother.nextCount(displayed: 5, target: "hello"), 5)
        XCTAssertEqual(StreamSmoother.nextCount(displayed: 9, target: "hello"), 5)
    }
}

final class AssistantServiceStreamingTests: XCTestCase {
    private func collect(_ stream: AsyncThrowingStream<String, Error>) async throws -> [String] {
        var out: [String] = []
        for try await value in stream { out.append(value) }
        return out
    }

    func testStreamSessionForwardsThroughDefaultStreaming() async throws {
        let fake = FakeBatchAssistant()
        fake.response = "the streamed answer"
        let service = AssistantService(assistant: fake, model: "m")

        let values = try await collect(
            service.streamAnswerAboutSession(transcript: "T", history: [], question: "Q?")
        )
        XCTAssertEqual(values.last, "the streamed answer")
        XCTAssertEqual(fake.lastPrompt, Prompts.sessionChat(transcript: "T", history: [], question: "Q?"))
    }

    func testStreamPatientForwardsPrompt() async throws {
        let fake = FakeBatchAssistant()
        let service = AssistantService(assistant: fake, model: "m")

        _ = try await collect(
            service.streamAnswerAboutPatient(context: "CTX", history: [], question: "When?")
        )
        XCTAssertEqual(fake.lastPrompt, Prompts.patientChat(context: "CTX", history: [], question: "When?"))
    }

    func testFormatCommentsRendersQuotedAndUnquoted() {
        let now = Date()
        let quoted = SessionComment(id: "1", quotedText: "sleep", body: "worse lately", createdAt: now, updatedAt: now)
        let plain = SessionComment(id: "2", quotedText: "  ", body: "general note", createdAt: now, updatedAt: now)
        let lines = AssistantService.formatComments([quoted, plain])
        XCTAssertEqual(lines[0], "- On “sleep”: worse lately")
        XCTAssertEqual(lines[1], "- general note")
    }

    func testFormatCommentsExcludesResolved() {
        let now = Date()
        let active = SessionComment(id: "1", quotedText: "sleep", body: "worse lately", createdAt: now, updatedAt: now)
        let resolved = SessionComment(id: "2", quotedText: "meds", body: "handled", createdAt: now, updatedAt: now, resolved: true)
        let lines = AssistantService.formatComments([active, resolved])
        XCTAssertEqual(lines, ["- On “sleep”: worse lately"], "a resolved comment stays out of the AI context")
    }

    func testFormatCommentsIncludesNoteFormatLabel() {
        let now = Date()
        let noteQuoted = SessionComment(id: "1", quotedText: "Plan: CBT", body: "switch to DBT", createdAt: now, updatedAt: now, format: .soap)
        let notePlain = SessionComment(id: "2", quotedText: "", body: "overall impression good", createdAt: now, updatedAt: now, format: .narrative)
        let transcript = SessionComment(id: "3", quotedText: "Therapist: hello", body: "greeted", createdAt: now, updatedAt: now)

        let lines = AssistantService.formatComments([noteQuoted, notePlain, transcript])
        XCTAssertEqual(lines, [
            "- [On SOAP note “Plan: CBT”]: switch to DBT",
            "- [On Summary note]: overall impression good",
            "- On “Therapist: hello”: greeted"
        ])
    }
}
