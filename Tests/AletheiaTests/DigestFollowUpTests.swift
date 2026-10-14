import XCTest
@testable import Aletheia

/// Each reply is `replyLength` characters; a prompt containing `stallMarker` waits
/// (cancellably) and other calls take `delay` nanoseconds.
private final class ScriptedAssistant: Assistant, @unchecked Sendable {
    var prompts: [String] = []
    var replyLength = 20
    var stallMarker: String?
    var delay: UInt64 = 0

    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { [] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String {
        prompts.append(prompt)
        if let stallMarker, prompt.contains(stallMarker) { try await Task.sleep(nanoseconds: 10_000_000_000) }
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        return String(repeating: "d", count: replyLength)
    }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}

/// A made-up transcript with a line a minute.
private func minutesOfTalk(_ minutes: Int) -> String {
    (0..<minutes).map { String(format: "[%02d:%02d] You: line %d", $0, 0, $0) }.joined(separator: "\n")
}

@MainActor
final class DigestFollowUpTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DigestFollowUpTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func wait(_ condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() { try await Task.sleep(nanoseconds: 5_000_000) }
    }

    private func makeSession(_ store: Store, transcript text: String) throws -> (Patient, SessionRecord) {
        let patient = try store.createPatient(name: "Dana Cole")
        let session = try store.createSession(for: patient)
        try store.saveTranscript(text, for: patient, session: session)
        return (patient, session)
    }

    func testReplacingABuildKeepsTheNewBuildsState() async throws {
        let store = Store(root: root)
        let first = minutesOfTalk(25) + "\n[30:00] You: STALL"
        let second = minutesOfTalk(25)
        let (patient, session) = try makeSession(store, transcript: first)
        let fake = ScriptedAssistant()
        fake.stallMarker = "STALL"
        let service = AssistantService(assistant: fake, model: "m")
        let builder = DigestBuilder(queue: InferenceQueue())

        builder.ensureDigest(for: patient, session: session, transcript: first, store: store, service: service)
        try await wait { fake.prompts.contains { $0.contains("STALL") } }
        fake.delay = 40_000_000
        try store.saveTranscript(second, for: patient, session: session)
        builder.ensureDigest(for: patient, session: session, transcript: second, store: store, service: service)

        // The cancelled first build has unwound by now; the new one must still be tracked.
        try await Task.sleep(nanoseconds: 80_000_000)
        XCTAssertNotNil(builder.progress[session.id])

        try await wait { store.digest(for: patient, session: session, model: "m") != nil }
        let saved = try XCTUnwrap(store.digest(for: patient, session: session, model: "m"))
        XCTAssertEqual(saved.transcriptFingerprint, NoteFreshness.fingerprint(of: second))
        try await wait { builder.progress[session.id] == nil }
        XCTAssertNil(builder.progress[session.id])
        XCTAssertNil(builder.failures[session.id])
    }

    func testRebuildsWhenTheModelChangesButNotWhenCurrent() async throws {
        let store = Store(root: root)
        let text = minutesOfTalk(5)
        let (patient, session) = try makeSession(store, transcript: text)
        let fake = ScriptedAssistant()
        let builder = DigestBuilder(queue: InferenceQueue())

        builder.ensureDigest(for: patient, session: session, transcript: text, store: store,
                             service: AssistantService(assistant: fake, model: "old"))
        try await wait { store.digest(for: patient, session: session, model: "old") != nil }
        try await wait { builder.progress[session.id] == nil }
        let calls = fake.prompts.count
        XCTAssertGreaterThan(calls, 0)

        builder.ensureDigest(for: patient, session: session, transcript: text, store: store,
                             service: AssistantService(assistant: fake, model: "old"))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(fake.prompts.count, calls, "a current digest is not rebuilt")

        builder.ensureDigest(for: patient, session: session, transcript: text, store: store,
                             service: AssistantService(assistant: fake, model: "new"))
        try await wait { store.digest(for: patient, session: session, model: "new") != nil }
        XCTAssertNotNil(store.digest(for: patient, session: session, model: "new"))
        XCTAssertGreaterThan(fake.prompts.count, calls)
    }

    func testMergeOverBudgetSplitsIntoGroupsThatFit() async throws {
        let fake = ScriptedAssistant()
        fake.replyLength = 2_000
        var service = AssistantService(assistant: fake, model: "m")
        // Room for the merge instructions plus two section digests, not three.
        let overhead = service.systemPrompt.count + Prompts.sessionDigest(sections: []).count
        let capacity = overhead + 2 * 2_040
        service.budget = ContextBudget(tokens: ContextBudget.replyHeadroomTokens + capacity / ContextBudget.charactersPerToken)
        let builder = DigestBuilder(queue: InferenceQueue())

        let digest = try await builder.build(transcript: minutesOfTalk(25), service: service)

        // 3 sections, one merge of the first two, the third carried over, one final merge.
        XCTAssertEqual(fake.prompts.count, 5)
        XCTAssertTrue(fake.prompts.allSatisfy { service.fits(prompt: $0) })
        XCTAssertEqual(digest.sections.count, 3)
        XCTAssertEqual(digest.sessionDigest.count, 2_000)
    }

    func testDigestCallsAreBudgetChecked() async throws {
        let fake = ScriptedAssistant()
        var service = AssistantService(assistant: fake, model: "m")
        service.budget = ContextBudget(tokens: ContextBudget.replyHeadroomTokens + 10)
        let builder = DigestBuilder(queue: InferenceQueue())
        do {
            _ = try await builder.build(transcript: minutesOfTalk(5), service: service)
            XCTFail("expected the budget error")
        } catch is ContextBudgetError {}
        XCTAssertTrue(fake.prompts.isEmpty)
    }

    func testFailureIsShownAndCancellationIsNot() async throws {
        let store = Store(root: root)
        let text = minutesOfTalk(5)
        let (patient, session) = try makeSession(store, transcript: text)
        var service = AssistantService(assistant: ScriptedAssistant(), model: "m")
        service.budget = ContextBudget(tokens: ContextBudget.replyHeadroomTokens + 10)
        let builder = DigestBuilder(queue: InferenceQueue())

        builder.ensureDigest(for: patient, session: session, transcript: text, store: store, service: service)
        try await wait { builder.failures[session.id] != nil }
        XCTAssertNotNil(builder.failures[session.id])
        XCTAssertNil(builder.progress[session.id])

        builder.cancel(session.id)
        XCTAssertNil(builder.failures[session.id])
    }
}
