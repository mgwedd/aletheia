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

private final class Recorded<Value> {
    var values: [Value] = []
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
        // The new build reuses the sections the first one finished (only the merge
        // is left), so that call is slowed enough to still be running below.
        fake.delay = 200_000_000
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

    func testMergedAnchorsStayOneFlatRangeAcrossMergeRounds() async throws {
        let fake = ScriptedAssistant()
        fake.replyLength = 2_000
        var service = AssistantService(assistant: fake, model: "m")
        // Room for the merge instructions plus two section digests, not three.
        let overhead = service.systemPrompt.count + Prompts.sessionDigest(sections: []).count
        let capacity = overhead + 2 * 2_040
        service.budget = ContextBudget(tokens: ContextBudget.replyHeadroomTokens + capacity / ContextBudget.charactersPerToken)
        let builder = DigestBuilder(queue: InferenceQueue())
        let text = minutesOfTalk(45)
        let sections = TranscriptSections.split(text)
        XCTAssertEqual(sections.count, 5)

        _ = try await builder.build(transcript: text, service: service)

        // 5 sections, two group merges, a second round merging those two, the final merge.
        XCTAssertEqual(fake.prompts.count, 9)
        let wholeRange = "[\(TranscriptTimeline.format(sections[0].start ?? 0))–\(TranscriptTimeline.format(sections[3].end ?? 0))]"
        let last = try XCTUnwrap(fake.prompts.last)
        XCTAssertTrue(last.contains(wholeRange + "\n"), "the second round's result is labelled by its whole range")
        XCTAssertFalse(fake.prompts.contains { $0.contains(" … ") }, "no merged anchor lists its pieces")
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

    // MARK: - Progress

    func testStepsAdvanceThroughEachSectionThenTheMerge() async throws {
        let fake = ScriptedAssistant()
        let service = AssistantService(assistant: fake, model: "m")
        let builder = DigestBuilder(queue: InferenceQueue())
        let seen = Recorded<AIRunSteps>()
        let live: DigestBuilder.Live = { _, change in
            var progress = AIRunProgress()
            change(&progress)
            if let steps = progress.steps { seen.values.append(steps) }
        }

        let digest = try await builder.build(transcript: minutesOfTalk(25), service: service, live: live)

        let sections = digest.sections.count
        XCTAssertGreaterThan(sections, 1)
        // One step per section, then the final merge.
        XCTAssertEqual(seen.values, (0...sections).map { AIRunSteps(done: $0, total: sections + 1) })
    }

    func testStepsCountEveryMergeRoundNotJustTheFinalMerge() async throws {
        let fake = ScriptedAssistant()
        fake.replyLength = 2_000
        var service = AssistantService(assistant: fake, model: "m")
        // Room for the merge instructions plus two section digests, not three.
        let overhead = service.systemPrompt.count + Prompts.sessionDigest(sections: []).count
        let capacity = overhead + 2 * 2_040
        service.budget = ContextBudget(tokens: ContextBudget.replyHeadroomTokens + capacity / ContextBudget.charactersPerToken)
        let builder = DigestBuilder(queue: InferenceQueue())
        let seen = Recorded<AIRunSteps>()
        let live: DigestBuilder.Live = { _, change in
            var progress = AIRunProgress()
            change(&progress)
            if let steps = progress.steps { seen.values.append(steps) }
        }

        let digest = try await builder.build(transcript: minutesOfTalk(25), service: service, live: live)

        // 3 sections, one group merge, the final merge: 5 calls in all.
        XCTAssertEqual(digest.sections.count, 3)
        XCTAssertEqual(fake.prompts.count, 5)
        XCTAssertEqual(seen.values, [
            AIRunSteps(done: 0, total: 4),
            AIRunSteps(done: 1, total: 4),
            AIRunSteps(done: 2, total: 4),
            AIRunSteps(done: 3, total: 5),
            AIRunSteps(done: 4, total: 5),
        ])
        XCTAssertEqual(seen.values.last?.total, fake.prompts.count)
    }

    func testStageTitlesAreNotWrittenInTermsOfDigests() async throws {
        let fake = ScriptedAssistant()
        let service = AssistantService(assistant: fake, model: "m")
        let builder = DigestBuilder(queue: InferenceQueue())
        let recorded = Recorded<String>()
        let live: DigestBuilder.Live = { _, change in
            var progress = AIRunProgress()
            change(&progress)
            if progress.readTitle != "Reading" { recorded.values += [progress.readTitle, progress.writeTitle] }
        }

        _ = try await builder.build(transcript: minutesOfTalk(25), service: service, live: live)
        let titles = recorded.values

        XCTAssertTrue(titles.contains(DigestBuilder.mergeTitle))
        XCTAssertTrue(titles.contains(DigestBuilder.writeTitle))
        for title in titles + [DigestBuilder.activityTitle] {
            XCTAssertFalse(title.lowercased().contains("digest"), title)
        }
    }

    func testStepsSurviveTheNextStage() {
        var progress = AIRunProgress()
        progress.steps = AIRunSteps(done: 2, total: 5)
        progress.beginStage(readTitle: "Reading section 3 of 4", writeTitle: "Writing summary", startedAt: Date())
        XCTAssertEqual(progress.steps, AIRunSteps(done: 2, total: 5))
    }
}

final class AIRunStepsTests: XCTestCase {
    func testTheCallInFlightCountsAsHalfDone() {
        XCTAssertEqual(AIRunSteps(done: 0, total: 4).fraction, 0.125, accuracy: 0.0001)
        XCTAssertEqual(AIRunSteps(done: 3, total: 4).fraction, 0.875, accuracy: 0.0001)
    }

    func testNeverEmptyOnceStartedNorFullBeforeTheEnd() {
        XCTAssertGreaterThan(AIRunSteps(done: 0, total: 10).fraction, 0)
        XCTAssertLessThan(AIRunSteps(done: 9, total: 10).fraction, 1)
    }

    func testClampsAndHandlesNoSteps() {
        XCTAssertEqual(AIRunSteps(done: 0, total: 0).fraction, 0)
        XCTAssertEqual(AIRunSteps(done: 50, total: 4).fraction, 1)
    }
}
