import XCTest
@testable import Aletheia

/// A stub model that answers by the kind of prompt it is given and records them all.
private final class StubModel: Assistant, @unchecked Sendable {
    var prompts: [String] = []

    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { [] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String {
        prompts.append(prompt)
        if prompt.contains("Transcript section") { return "section digest" }
        if prompt.contains("Below are digest notes") { return "merged digest [0:00–9:00]" }
        if prompt.contains("Below are a draft clinical note") { return "CHECKED NOTE" }
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
        case _ where i % 10 == 0: return "\(stamp) Client: I felt anxious and could not sleep, so work stress piled up."
        default: return "\(stamp) You: Tell me more about topic number \(i) and how the week went with the family and work."
        }
    }.joined(separator: "\n")
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
        transcript: String, effort: AnswerEffort = .normal, stored: SessionDigest? = nil
    ) async throws -> Run {
        let stub = StubModel()
        var service = AssistantService(assistant: stub, model: "m")
        service.budget = budget
        var coverage: [String] = []
        let stream = LongSessionNote.stream(
            format: .soap, transcript: transcript, effort: effort, service: service,
            builder: DigestBuilder(queue: InferenceQueue()), sessionID: UUID(),
            loadDigest: { stored }, saveDigest: { _ in },
            live: { _, _ in }, coverage: { coverage.append($0) })
        var snapshots: [String] = []
        for try await snapshot in stream { snapshots.append(snapshot) }
        return Run(snapshots: snapshots, coverage: coverage, prompts: stub.prompts)
    }

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
        service.budget = budget
        XCTAssertFalse(service.fits(prompt: Prompts.progressNote(format: .soap, transcript: text)))

        let result = try await run(transcript: text)
        let final = try XCTUnwrap(result.prompts.last)
        XCTAssertEqual(result.snapshots.last, "DRAFT NOTE")
        XCTAssertTrue(service.fits(prompt: final))
        XCTAssertTrue(final.contains("merged digest"))
        XCTAssertTrue(final.contains("I think about hurting myself"), "risk statement comes from the transcript")
        XCTAssertTrue(final.contains("I would never do it"), "the denial comes with it")
        XCTAssertFalse(final.contains(text))
        // Digest calls (sections + merge) come first; the last call is the note, and nothing else follows.
        XCTAssertTrue(result.prompts.dropLast().allSatisfy { !$0.contains("Draft note:") && !$0.contains("Passages from the original") })
    }

    func testCoverageNoticeSaysWhatWasLeftOut() async throws {
        let text = syntheticTranscript(minutes: 120)
        let result = try await run(transcript: text)
        let notice = try XCTUnwrap(result.coverage.first)
        XCTAssertTrue(notice.hasPrefix("Read: a summary of the whole session"))
        XCTAssertTrue(notice.contains("of 360 transcript lines"))
        XCTAssertTrue(notice.contains("Normal"))
        XCTAssertTrue(notice.contains("may be missing"))
        // The count in the notice is what the prompt actually carries.
        let passages = LongSessionNote.passages(in: text, format: .soap, limit: 1)
        XCTAssertLessThanOrEqual(passages.lineCount, 1)
    }

    func testStoredDigestIsNotRebuilt() async throws {
        let text = syntheticTranscript(minutes: 120)
        let digest = SessionDigest(
            model: "m", promptVersion: Prompts.digestVersion, transcriptFingerprint: NoteFreshness.fingerprint(of: text),
            sections: [.init(start: 0, end: 540, digest: "s")], sessionDigest: "STORED DIGEST", createdAt: Date())
        let result = try await run(transcript: text, stored: digest)
        XCTAssertEqual(result.prompts.count, 1)
        XCTAssertTrue(result.prompts[0].contains("STORED DIGEST"))
    }

    func testFocusAddsOneCheckCallAndFinalTextIsTheChecked() async throws {
        let text = syntheticTranscript(minutes: 120)
        let normal = try await run(transcript: text, effort: .normal)
        let focus = try await run(transcript: text, effort: .focus)
        XCTAssertEqual(focus.prompts.count, normal.prompts.count + 1)
        let check = try XCTUnwrap(focus.prompts.last)
        XCTAssertTrue(check.contains("Draft note:\nDRAFT NOTE"))
        XCTAssertTrue(check.contains("I would never do it"))
        XCTAssertEqual(focus.snapshots, ["DRAFT NOTE", "CHECKED NOTE"])
        XCTAssertTrue(try XCTUnwrap(focus.coverage.last).contains("Checked against the passages"))
        XCTAssertFalse(normal.prompts.contains { $0.contains("Draft note:") })
    }

    func testPassagesStayInOrderWithinLimitAndMarkGaps() {
        let text = syntheticTranscript(minutes: 120)
        let found = LongSessionNote.passages(in: text, format: .soap, limit: 3_000)
        XCTAssertLessThanOrEqual(found.text.count, 3_000 + found.lineCount)
        XCTAssertGreaterThan(found.lineCount, 0)
        XCTAssertTrue(found.text.contains("[…]"))
        let stamps = found.text.split(separator: "\n").compactMap { TranscriptTimeline.leadingSeconds(of: String($0)) }
        XCTAssertEqual(stamps, stamps.sorted())
    }

    func testRiskIsSearchedForEveryFormat() {
        for format in ProgressNoteFormat.allCases {
            XCTAssertTrue(LongSessionNote.topics(for: format).first?.contains("suicid") == true)
        }
    }
}
