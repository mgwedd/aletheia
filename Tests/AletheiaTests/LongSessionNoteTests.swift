import XCTest
@testable import Aletheia

/// A stub model that answers by the kind of prompt it is given and records them all.
private final class StubModel: Assistant, @unchecked Sendable {
    var prompts: [String] = []
    /// What the check call returns; `failCheck` makes it throw instead.
    var checkResponse = "CHECKED NOTE"
    var failCheck = false
    /// Waits this long on each digest call (nanoseconds).
    var digestDelay: UInt64 = 0

    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { [] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String {
        prompts.append(prompt)
        if prompt.contains("Transcript section") {
            if digestDelay > 0 { try await Task.sleep(nanoseconds: digestDelay) }
            return "section digest"
        }
        if prompt.contains("Below are digest notes") { return "merged digest [0:00–9:00]" }
        if prompt.contains("Below are a draft clinical note") {
            if failCheck { throw URLError(.cannotConnectToHost) }
            return checkResponse
        }
        return "DRAFT NOTE"
    }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}

/// Made-up session: a line every 20 seconds, with one risk statement and its denial late on.
private func syntheticTranscript(minutes: Int) -> String {
    (0..<(minutes * 3)).map { i in
        let stamp = String(format: "[%02d:%02d]", (i * 20) / 60, (i * 20) % 60)
        switch i {
        case minutes * 2: return "\(stamp) Client: Some nights I think about hurting myself, just briefly."
        case minutes * 2 + 1: return "\(stamp) You: Do you have a plan to act on that? Client: No, I would never do it."
        case _ where i % 10 == 0: return "\(stamp) Client: I felt anxious and could not sleep, so work stress piled up \(i)."
        default: return "\(stamp) You: Tell me more about topic number \(i) and how the week went with the family and work."
        }
    }.joined(separator: "\n")
}

private func storedDigest(for text: String, size: Int = 20, model: String = "m") -> SessionDigest {
    SessionDigest(
        model: model, promptVersion: Prompts.digestVersion, transcriptFingerprint: NoteFreshness.fingerprint(of: text),
        sections: [.init(start: 0, end: 540, digest: "s")], sessionDigest: String(repeating: "STORED DIGEST ", count: size),
        createdAt: Date())
}

@MainActor
final class LongSessionNoteTests: XCTestCase {
    private let budget = ContextBudget(tokens: 8192)

    /// The test host app owns the shared index and may have it closed behind its lock; use a private one.
    override func setUp() async throws { SessionSearch.index = SearchIndex() }

    private struct Run {
        var snapshots: [String]
        var coverage: [String]
        var prompts: [String]
    }

    private func run(
        transcript: String, effort: AnswerEffort = .normal, stored: SessionDigest? = nil, tokens: Int = 8192,
        format: ProgressNoteFormat = .soap, configure: (StubModel) -> Void = { _ in }
    ) async throws -> Run {
        let stub = StubModel()
        configure(stub)
        var service = AssistantService(assistant: stub, model: "m")
        service.budget = ContextBudget(tokens: tokens)
        var coverage: [String] = []
        let stream = LongSessionNote.stream(
            format: format, transcript: transcript, effort: effort, service: service,
            builder: DigestBuilder(queue: InferenceQueue()), sessionID: UUID(),
            loadDigest: { stored }, saveDigest: { _ in },
            live: { _, _ in }, coverage: { coverage.append($0) })
        var snapshots: [String] = []
        for try await snapshot in stream { snapshots.append(snapshot) }
        return Run(snapshots: snapshots, coverage: coverage, prompts: stub.prompts)
    }

    // MARK: - Paths

    func testWholeSessionWhenItFitsIsUnchanged() async throws {
        let text = syntheticTranscript(minutes: 5)
        let result = try await run(transcript: text, effort: .focus)
        XCTAssertEqual(result.prompts, [Prompts.progressNote(format: .soap, transcript: text)])
        XCTAssertEqual(result.snapshots, ["DRAFT NOTE"])
        XCTAssertTrue(result.coverage.isEmpty)
    }

    func testOverflowUsesDigestAndPassagesWithinBudget() async throws {
        let text = syntheticTranscript(minutes: 120)
        var service = AssistantService(assistant: StubModel(), model: "m")
        service.budget = ContextBudget(tokens: 8192)
        XCTAssertFalse(service.fits(prompt: Prompts.progressNote(format: .soap, transcript: text)))

        let result = try await run(transcript: text)
        let final = try XCTUnwrap(result.prompts.last)
        XCTAssertEqual(result.snapshots.last, "DRAFT NOTE")
        XCTAssertTrue(service.fits(prompt: final))
        XCTAssertTrue(final.contains("merged digest"))
        XCTAssertTrue(final.contains("think about hurting myself"), "risk statement comes from the transcript")
        XCTAssertTrue(final.contains("I would never do it"), "the denial comes with it")
        XCTAssertFalse(final.contains(text))
        XCTAssertTrue(result.prompts.dropLast().allSatisfy { !$0.contains("Draft note:") && !$0.contains("Passages from the original") })
    }

    func testStoredDigestIsNotRebuilt() async throws {
        let text = syntheticTranscript(minutes: 120)
        let result = try await run(transcript: text, stored: storedDigest(for: text))
        XCTAssertEqual(result.prompts.count, 1)
        XCTAssertTrue(result.prompts[0].contains("STORED DIGEST"))
    }

    // MARK: - Coverage

    func testCoverageCountsExactlyTheLinesInThePrompt() async throws {
        let text = syntheticTranscript(minutes: 120)
        let result = try await run(transcript: text, stored: storedDigest(for: text))
        let notice = try XCTUnwrap(result.coverage.first)
        XCTAssertTrue(notice.hasPrefix("Read: a summary of the whole session"))
        XCTAssertTrue(notice.contains("of 360 transcript lines"))
        XCTAssertTrue(notice.contains("Normal"))
        XCTAssertTrue(notice.contains("may be missing"))
        let sent = try XCTUnwrap(result.prompts.last?.components(separatedBy: "Passages from the original transcript:\n").last)
        // The prompt carries the passages compacted (same-speaker lines merged), so count
        // the transcript lines whose text is in it.
        let lines = text.split(separator: "\n").filter { line in
            line.range(of: "] ").map { sent.contains(line[$0.upperBound...].drop { $0 != ":" }.dropFirst(2)) } ?? false
        }
        let reported = try XCTUnwrap(notice.components(separatedBy: " plus ").last?.split(separator: " ").first.flatMap { Int($0) })
        XCTAssertEqual(lines.count, reported)
        XCTAssertLessThanOrEqual(reported, 360)
    }

    func testBlankLinesAreNotCounted() {
        let text = "[00:00] You: hello\n[00:20] Client: I want to end my life\n[00:40] You: tell me more\n\n\n"
        let found = LongSessionNote.passages(in: text, format: .soap, limit: 5_000, riskLimit: 2_000)
        XCTAssertEqual(found.lineCount, 3)
        XCTAssertEqual(LongSessionNote.nonBlankLines(text).count, 3)
    }

    // MARK: - Risk

    func testRiskParaphrasesAreFoundAndSurviveATightRoom() {
        var lines = (0..<400).map { String(format: "[%02d:%02d] You: Tell me more about topic number %d, the safe route and a drink with friends.", $0 / 3, ($0 % 3) * 20, $0) }
        lines[300] = "[100:00] Client: Honestly I don't want to be here anymore."
        lines[350] = "[116:40] Client: I have been thinking about ending it."
        lines[200] = "[66:40] Client: I took too many pills last year."
        let found = LongSessionNote.passages(in: lines.joined(separator: "\n"), format: .soap, limit: 1_500, riskLimit: 900)
        XCTAssertTrue(found.text.contains("don't want to be here anymore"))
        XCTAssertTrue(found.text.contains("thinking about ending it"))
        XCTAssertTrue(found.text.contains("pills"))
        XCTAssertLessThanOrEqual(found.text.count, 1_500 + found.lineCount)
    }

    func testExplicitRiskOutranksGenericWords() {
        // Many generic "drinking"/"safe" lines come first; the one explicit line must still make a small risk room.
        var lines = (0..<200).map { "[\($0)] Client: I was drinking again and felt safe at home, drinking with Sam." + String(repeating: " x", count: 5) + " \($0)" }
        lines[190] = "[190] Client: I want to kill myself some days."
        let found = LongSessionNote.passages(in: lines.joined(separator: "\n"), format: .soap, limit: 800, riskLimit: 300)
        XCTAssertTrue(found.text.contains("kill myself"))
    }

    func testRiskLinesReachThePromptOnATightBudget() async throws {
        var lines = (0..<600).map { String(format: "[%02d:%02d] You: Tell me more about topic number %d and how the week went.", $0 / 3, ($0 % 3) * 20, $0) }
        lines[500] = "[166:40] Client: I don't want to be here anymore."
        lines[510] = "[170:00] Client: I have been thinking about ending it."
        let text = lines.joined(separator: "\n")
        for effort in [AnswerEffort.normal, .focus] {
            let result = try await run(transcript: text, effort: effort, stored: storedDigest(for: text), tokens: 4600)
            let final = try XCTUnwrap(result.prompts.first)
            XCTAssertTrue(final.contains("don't want to be here anymore"), "\(effort)")
            XCTAssertTrue(final.contains("thinking about ending it"), "\(effort)")
            var service = AssistantService(assistant: StubModel(), model: "m")
            service.budget = ContextBudget(tokens: 4600)
            XCTAssertTrue(service.fits(prompt: final), "\(effort)")
        }
    }

    // MARK: - Budget

    func testFocusSkipsItsCheckRatherThanStarvePassages() async throws {
        var lines = (0..<600).map { String(format: "[%02d:%02d] You: Tell me more about topic number %d and how the week went.", $0 / 3, ($0 % 3) * 20, $0) }
        lines[500] = "[166:40] Client: I felt anxious and could not sleep."
        let text = lines.joined(separator: "\n")
        let result = try await run(transcript: text, effort: .focus, stored: storedDigest(for: text), tokens: 4600)
        XCTAssertEqual(result.prompts.count, 1, "no check call")
        XCTAssertTrue(try XCTUnwrap(result.coverage.last).contains("Not checked: not enough room"))
        XCTAssertGreaterThan(try XCTUnwrap(result.prompts.first).count, 3_000)
    }

    func testOversizedDigestIsShortenedNotRefused() async throws {
        let text = syntheticTranscript(minutes: 120)
        let result = try await run(transcript: text, stored: storedDigest(for: text, size: 600), tokens: 5000)
        let final = try XCTUnwrap(result.prompts.last)
        var service = AssistantService(assistant: StubModel(), model: "m")
        service.budget = ContextBudget(tokens: 5000)
        XCTAssertTrue(service.fits(prompt: final))
        XCTAssertTrue(final.contains("[digest shortened]"))
        XCTAssertTrue(try XCTUnwrap(result.coverage.first).contains("shortened to fit"))
        XCTAssertFalse(ContextBudgetError(minutes: 5).localizedDescription.contains("coming"))
    }

    // MARK: - Focus check

    func testFocusAddsOneCheckCallAndFinalTextIsTheChecked() async throws {
        let text = syntheticTranscript(minutes: 120)
        let normal = try await run(transcript: text, effort: .normal)
        let focus = try await run(transcript: text, effort: .focus) { $0.checkResponse = String(repeating: "CHECKED NOTE ", count: 3) }
        XCTAssertEqual(focus.prompts.count, normal.prompts.count + 1)
        let check = try XCTUnwrap(focus.prompts.last)
        XCTAssertTrue(check.contains("Draft note:\nDRAFT NOTE"))
        XCTAssertTrue(check.contains("I would never do it"))
        XCTAssertEqual(focus.snapshots.count, 2)
        XCTAssertTrue(try XCTUnwrap(focus.snapshots.last).hasPrefix("CHECKED NOTE"))
        XCTAssertTrue(try XCTUnwrap(focus.coverage.last).contains("Checked against the passages"))
        XCTAssertFalse(normal.prompts.contains { $0.contains("Draft note:") })
    }

    func testAFailedCheckKeepsTheDraftAndSaysSo() async throws {
        let text = syntheticTranscript(minutes: 120)
        let result = try await run(transcript: text, effort: .focus) { $0.failCheck = true }
        XCTAssertEqual(result.snapshots, ["DRAFT NOTE"])
        XCTAssertTrue(try XCTUnwrap(result.coverage.last).contains("check didn't run"))
    }

    func testAnIncompleteCheckResultIsNotAccepted() async throws {
        let text = syntheticTranscript(minutes: 120)
        let result = try await run(transcript: text, effort: .focus) { $0.checkResponse = "ok" }
        XCTAssertEqual(result.snapshots, ["DRAFT NOTE"])
        XCTAssertTrue(try XCTUnwrap(result.coverage.last).contains("looked incomplete"))
    }

    func testPlausiblyCompleteNeedsLengthAndHeadings() {
        let draft = "Subjective\nShe slept badly all week and worried a lot.\nPlan\nTry the sleep diary next week."
        XCTAssertTrue(LongSessionNote.plausiblyComplete(draft.replacingOccurrences(of: "badly", with: "poorly"), draft: draft, format: .soap))
        XCTAssertFalse(LongSessionNote.plausiblyComplete("Subjective\nSlept.", draft: draft, format: .soap))
        XCTAssertFalse(LongSessionNote.plausiblyComplete(draft.replacingOccurrences(of: "Plan", with: "Next"), draft: draft, format: .soap))
    }

    // MARK: - Passages

    func testPassagesStayInOrderWithinLimitAndMarkGaps() {
        let text = syntheticTranscript(minutes: 120)
        let found = LongSessionNote.passages(in: text, format: .soap, limit: 3_000, riskLimit: 800)
        XCTAssertLessThanOrEqual(found.text.count, 3_000 + found.lineCount)
        XCTAssertGreaterThan(found.lineCount, 0)
        XCTAssertTrue(found.text.contains("[…]"))
        let stamps = found.text.split(separator: "\n").compactMap { TranscriptTimeline.leadingSeconds(of: String($0)) }
        XCTAssertEqual(stamps, stamps.sorted())
    }

    // MARK: - Concurrency and stages

    func testInferenceQueueReportsAJobByLabel() async throws {
        let queue = InferenceQueue()
        XCTAssertFalse(queue.hasJob(labelled: "progress note A"))
        queue.enqueue(kind: .note, label: "progress note A") { try? await Task.sleep(nanoseconds: 200_000_000) }
        XCTAssertTrue(queue.hasJob(labelled: "progress note A"))
        XCTAssertFalse(queue.hasJob(labelled: "progress note B"))
    }

    func testNoBackgroundDigestStartsWhileANoteBuildsInline() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LongNote-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Dana Cole")
        let session = try store.createSession(for: patient)
        let text = syntheticTranscript(minutes: 40)
        try store.saveTranscript(text, for: patient, session: session)
        let stub = StubModel()
        stub.digestDelay = 60_000_000
        let service = AssistantService(assistant: stub, model: "m")
        let builder = DigestBuilder(queue: InferenceQueue())

        let inline = Task { try await builder.buildInline(sessionID: session.id, transcript: text, service: service, live: { _, _ in }) }
        for _ in 0..<200 where stub.prompts.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        builder.ensureDigest(for: patient, session: session, transcript: text, store: store, service: service)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNil(builder.progress[session.id], "no second build started")
        _ = try await inline.value
    }

    func testStageProgressIsNotClobberedAndLateEventsAreDropped() {
        let runner = ChatStreamRunner()
        let first = Date(timeIntervalSince1970: 1)
        let second = Date(timeIntervalSince1970: 2)
        runner.update(started: nil) { $0 = AIRunProgress(readTitle: "Checking", writeTitle: "w", startedAt: second) }
        runner.update(started: first) { $0.readTitle = "late" }
        XCTAssertEqual(runner.progress.readTitle, "Checking")
        // A stats event from the runner's own reporter is ignored once stages are reported.
        runner.apply(.finished(AIRunStats(promptTokens: 1, expectedPromptTokens: 5_000)), run: runner.currentRun)
        XCTAssertNil(runner.progress.stats)
    }

    // MARK: - Saved coverage

    func testCoverageIsSavedWithTheNoteAndClearedByAWholeSessionNote() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LongNoteSave-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Dana Cole")
        let session = try store.createSession(for: patient)
        try store.saveGeneratedNote("S: a", for: patient, session: session, format: .soap, coverage: "Read: partly")
        XCTAssertEqual(store.noteCoverage(for: patient, session: session, format: .soap), "Read: partly")
        XCTAssertNil(store.noteCoverage(for: patient, session: session, format: .dap))
        XCTAssertFalse(Store.isNoteFileName("note.soap.coverage.txt"))
        XCTAssertTrue(Store.isNoteSidecarFileName("note.soap.coverage.txt"))
        try store.saveGeneratedNote("S: b", for: patient, session: session, format: .soap)
        XCTAssertNil(store.noteCoverage(for: patient, session: session, format: .soap))
    }
}
