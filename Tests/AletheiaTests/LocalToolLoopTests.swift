import XCTest
@testable import Aletheia

private final class ToolLoopStubAssistant: Assistant, @unchecked Sendable {
    var prompts: [String] = []
    var recordedCalls: [(task: AITask, grammar: LocalLLMGrammar?)] = []
    var planReplies: [String] = []
    var answerReply = "FINAL ANSWER"
    private var planIndex = 0

    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { [] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String {
        prompts.append(prompt)
        if prompt.contains("Transcript section") {
            return "section digest"
        }
        if prompt.contains("Below are digest notes") {
            return "merged digest [0:00–9:00]"
        }
        if prompt.contains("Available read-only tools:") {
            let reply = planIndex < planReplies.count ? planReplies[planIndex] : #"{"calls":[]}"#
            planIndex += 1
            return reply
        }
        return answerReply
    }
    func stream(
        model: String,
        system: String,
        prompt: String,
        task: AITask,
        grammar: LocalLLMGrammar?,
        onStats: (@Sendable (AIRunStats) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        recordedCalls.append((task, grammar))
        return stream(model: model, system: system, prompt: prompt, task: task, onStats: onStats)
    }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}

@MainActor
final class LocalToolLoopTests: XCTestCase {
    override func setUp() async throws {
        SessionSearch.index = SearchIndex()
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func sampleSessions() -> [LocalToolSession] {
        let digest1 = SessionDigest(
            model: "m",
            promptVersion: Prompts.digestVersion,
            transcriptFingerprint: "fp1",
            sections: [
                .init(start: 0, end: 599, digest: "Opening check-in on sleep."),
                .init(start: 600, end: 1200, digest: "Discussed sister Dana and work boundary."),
            ],
            sessionDigest: "[00:00–10:00] Sleep check-in.\n[10:00–20:00] Sister Dana visit.",
            createdAt: Date()
        )
        let s1Transcript = """
        [00:10] You: How did sleep go this week?
        [00:35] Client: Better after the magnesium.
        [12:15] Client: My sister Dana called on Tuesday night and asked to borrow money.
        [12:45] You: How did you respond to Dana?
        [13:10] Client: I told her I needed to think about it first.
        """
        let s2Transcript = """
        [01:00] Client: Work deadlines were intense all week.
        [05:20] Client: I practiced the breathing exercise before the meeting.
        """
        return [
            LocalToolSession(
                id: UUID(),
                tag: "S1",
                date: date(2026, 3, 15),
                folderName: "2026-03-15_10-00",
                transcript: s1Transcript,
                digest: digest1,
                notes: "Therapist note for S1.",
                comments: ["- On “Dana”: boundary progress"]
            ),
            LocalToolSession(
                id: UUID(),
                tag: "S2",
                date: date(2026, 1, 10),
                folderName: "2026-01-10_10-00",
                transcript: s2Transcript,
                digest: nil,
                notes: "January session note on breathing.",
                comments: []
            ),
        ]
    }

    // MARK: - PatientDigestMerger

    func testPatientDigestMergerSplitsRecentAndMonthMergedWithinBudget() {
        let items: [PatientDigestMerger.DatedDigest] = [
            .init(tag: "S1", date: date(2026, 3, 20), folderName: "f1", digest: "Digest 1"),
            .init(tag: "S2", date: date(2026, 3, 10), folderName: "f2", digest: "Digest 2"),
            .init(tag: "S3", date: date(2026, 2, 20), folderName: "f3", digest: "Digest 3"),
            .init(tag: "S4", date: date(2026, 1, 25), folderName: "f4", digest: "Digest 4"),
            .init(tag: "S5", date: date(2026, 1, 5), folderName: "f5", digest: "Digest 5"),
        ]
        let plan = PatientDigestMerger.plan(digests: items, recentIndividualLimit: 2, characterBudget: 4_000)

        XCTAssertEqual(plan.individualByDate.count, 2)
        XCTAssertEqual(plan.digestSessionCount, 5)
        XCTAssertEqual(plan.monthMergedSessionCount, 3)
        XCTAssertEqual(plan.monthBlocks.map(\.monthTitle), ["February 2026", "January 2026"])
        XCTAssertEqual(plan.monthBlocks[0].tags, ["S3"])
        XCTAssertEqual(plan.monthBlocks[1].tags, ["S4", "S5"])
        XCTAssertTrue(plan.monthBlocks[1].text.contains("===== Earlier Sessions: January 2026 [S4, S5] ====="))
    }

    // MARK: - LocalToolScope execution & validation

    func testSearchToolFindsMatchesAndHonorsDateBounds() {
        let scope = LocalToolScope(sessions: sampleSessions())

        let hit = scope.execute(LocalToolCall(tool: "search", query: "Dana"))
        XCTAssertFalse(hit.isError)
        XCTAssertEqual(hit.readTranscriptTags, ["S1"])
        XCTAssertTrue(hit.output.contains("[S1]"))
        XCTAssertTrue(hit.output.contains("sister Dana"))
        XCTAssertNotNil(hit.stageTitle)

        let filteredOut = scope.execute(LocalToolCall(tool: "search", query: "Dana", from: "2026-01-01", to: "2026-02-01"))
        XCTAssertFalse(filteredOut.isError)
        XCTAssertTrue(filteredOut.output.contains("0 matches"))
        XCTAssertTrue(filteredOut.readTranscriptTags.isEmpty)
    }

    func testReadSectionExtractsRequestedTimeWindow() {
        let scope = LocalToolScope(sessions: sampleSessions())

        let section = scope.execute(LocalToolCall(tool: "read_section", session: "S1", start: "10:00", end: "15:00"))
        XCTAssertFalse(section.isError)
        XCTAssertEqual(section.readTranscriptTags, ["S1"])
        XCTAssertEqual(section.stageTitle, "Read S1 [10:00–15:00]")
        XCTAssertTrue(section.output.contains("sister Dana"))
        XCTAssertFalse(section.output.contains("magnesium"))
    }

    func testGetDigestReturnsStoredDigestOrNotesFallback() {
        let scope = LocalToolScope(sessions: sampleSessions())

        let d1 = scope.execute(LocalToolCall(tool: "get_digest", session: "[S1]"))
        XCTAssertFalse(d1.isError)
        XCTAssertEqual(d1.readDigestTags, ["S1"])
        XCTAssertTrue(d1.output.contains("Sister Dana visit"))
        XCTAssertTrue(d1.output.contains("Section details:"))

        let d2 = scope.execute(LocalToolCall(tool: "get_digest", session: "2"))
        XCTAssertFalse(d2.isError)
        XCTAssertTrue(d2.readDigestTags.isEmpty)
        XCTAssertTrue(d2.output.contains("January session note on breathing."))
    }

    func testListSessionsListsMetadataAndFiltersByDate() {
        let scope = LocalToolScope(sessions: sampleSessions())

        let all = scope.execute(LocalToolCall(tool: "list_sessions"))
        XCTAssertFalse(all.isError)
        XCTAssertEqual(all.stageTitle, "Listed 2 sessions")
        XCTAssertTrue(all.output.contains("[S1]"))
        XCTAssertTrue(all.output.contains("[S2]"))

        let janOnly = scope.execute(LocalToolCall(tool: "list_sessions", from: "2026-01-01", to: "2026-01-31"))
        XCTAssertFalse(janOnly.isError)
        XCTAssertEqual(janOnly.stageTitle, "Listed 1 session")
        XCTAssertTrue(janOnly.output.contains("[S2]"))
        XCTAssertFalse(janOnly.output.contains("[S1]"))
    }

    func testInvalidToolCallsAndBadArgumentsReturnErrorsWithoutCrashing() {
        let scope = LocalToolScope(sessions: sampleSessions())

        let unknown = scope.execute(LocalToolCall(tool: "delete_session", session: "S1"))
        XCTAssertTrue(unknown.isError)
        XCTAssertNil(unknown.stageTitle)
        XCTAssertTrue(unknown.output.contains("unknown tool"))

        let emptyQuery = scope.execute(LocalToolCall(tool: "search", query: "   "))
        XCTAssertTrue(emptyQuery.isError)
        XCTAssertTrue(emptyQuery.output.contains("non-empty \"query\""))

        let badSession = scope.execute(LocalToolCall(tool: "read_section", session: "S99"))
        XCTAssertTrue(badSession.isError)
        XCTAssertTrue(badSession.output.contains("valid \"session\""))

        let badTime = scope.execute(LocalToolCall(tool: "read_section", session: "S1", start: "15:00", end: "10:00"))
        XCTAssertTrue(badTime.isError)
        XCTAssertTrue(badTime.output.contains("must be >= start"))

        let badDate = scope.execute(LocalToolCall(tool: "search", query: "Dana", from: "not-a-date"))
        XCTAssertTrue(badDate.isError)
        XCTAssertTrue(badDate.output.contains("invalid \"from\" date"))

        let invertedDates = scope.execute(LocalToolCall(tool: "list_sessions", from: "2026-03-01", to: "2026-01-01"))
        XCTAssertTrue(invertedDates.isError)
        XCTAssertTrue(invertedDates.output.contains("must not be after"))
    }

    // MARK: - Parsing & Refinement Loop

    func testParseCallsHandlesValidJSONFencesAndMalformedReplies() {
        XCTAssertEqual(LocalToolLoop.parseCalls(""), [])
        XCTAssertEqual(LocalToolLoop.parseCalls("none"), [])
        XCTAssertEqual(LocalToolLoop.parseCalls(#"{"calls":[]}"#), [])

        let fenced = """
        ```json
        {"calls":[{"tool":"search","query":"Dana"},{"tool":"read_section","session":"S1","start":"10:00","end":"20:00"}]}
        ```
        """
        let parsed = LocalToolLoop.parseCalls(fenced)
        XCTAssertEqual(parsed, [
            LocalToolCall(tool: "search", query: "Dana"),
            LocalToolCall(tool: "read_section", session: "S1", start: "10:00", end: "20:00"),
        ])

        let broken = LocalToolLoop.parseCalls("{not valid json")
        XCTAssertEqual(broken, [LocalToolCall(tool: "invalid_json")])
    }

    func testRefineRespectsEffortCallLimitsAndPassesGrammar() async throws {
        let scope = LocalToolScope(sessions: sampleSessions())
        let stub = ToolLoopStubAssistant()
        // Request 6 calls in round 1; Normal must cap at 4 calls in 1 round.
        stub.planReplies = [
            #"{"calls":[{"tool":"search","query":"Dana"},{"tool":"read_section","session":"S1","start":"00:00","end":"05:00"},{"tool":"read_section","session":"S1","start":"10:00","end":"15:00"},{"tool":"get_digest","session":"S1"},{"tool":"list_sessions"},{"tool":"search","query":"breathing"}]}"#,
            #"{"calls":[{"tool":"search","query":"breathing"}]}"#,
        ]
        let service = AssistantService(assistant: stub, model: "m")
        let builder = DigestBuilder(queue: InferenceQueue())
        var progress = AIRunProgress()

        let fastResult = try await LocalToolLoop.refine(
            question: "What happened with Dana?",
            initialContext: "Initial",
            scope: scope,
            effort: .fast,
            characterBudget: 6_000,
            service: service,
            builder: builder,
            live: { _, change in change(&progress) }
        )
        XCTAssertTrue(fastResult.outcomes.isEmpty)
        XCTAssertTrue(stub.recordedCalls.isEmpty)

        let normalResult = try await LocalToolLoop.refine(
            question: "What happened with Dana?",
            initialContext: "Initial",
            scope: scope,
            effort: .normal,
            characterBudget: 6_000,
            service: service,
            builder: builder,
            live: { _, change in change(&progress) }
        )
        XCTAssertEqual(normalResult.outcomes.count, 4, "Normal caps at 4 tool calls")
        XCTAssertEqual(stub.recordedCalls.count, 1, "Normal runs at most 1 planning round")
        XCTAssertEqual(stub.recordedCalls.first?.grammar, LocalToolLoop.grammar)
        XCTAssertTrue(normalResult.additionalContext.contains("sister Dana"))
        XCTAssertTrue(progress.completedStages.contains("Read S1 [10:00–15:00]"))
    }

    func testFocusRefineAllowsTwoRoundsUpToTenCalls() async throws {
        let scope = LocalToolScope(sessions: sampleSessions())
        let stub = ToolLoopStubAssistant()
        stub.planReplies = [
            #"{"calls":[{"tool":"list_sessions"},{"tool":"get_digest","session":"S1"}]}"#,
            #"{"calls":[{"tool":"read_section","session":"S1","start":"10:00","end":"15:00"}]}"#,
        ]
        let service = AssistantService(assistant: stub, model: "m")
        let builder = DigestBuilder(queue: InferenceQueue())
        var progress = AIRunProgress()

        let focusResult = try await LocalToolLoop.refine(
            question: "What did Dana ask for?",
            initialContext: "Initial",
            scope: scope,
            effort: .focus,
            characterBudget: 6_000,
            service: service,
            builder: builder,
            live: { _, change in change(&progress) }
        )
        XCTAssertEqual(stub.recordedCalls.count, 2, "Focus runs a second round when calls remain")
        XCTAssertEqual(focusResult.outcomes.count, 3)
        XCTAssertEqual(focusResult.readTranscriptTags, ["S1"])
        XCTAssertEqual(focusResult.readDigestTags, ["S1"])
    }

    // MARK: - LongSessionChat & PatientChatAnswer

    func testLongSessionChatUsesDigestSearchAndToolsWhenOverBudget() async throws {
        let lines = (0..<360).map { i -> String in
            let stamp = String(format: "[%02d:%02d]", (i * 20) / 60, (i * 20) % 60)
            if i == 240 {
                return "\(stamp) Client: My sister Dana asked to borrow five hundred dollars."
            }
            return "\(stamp) You: Tell me more about topic \(i) and how the week went with work and family."
        }.joined(separator: "\n")

        let stub = ToolLoopStubAssistant()
        stub.planReplies = [
            #"{"calls":[{"tool":"read_section","session":"S1","start":"79:00","end":"81:00"}]}"#
        ]
        var service = AssistantService(assistant: stub, model: "m")
        service.budget = ContextBudget(tokens: 8_192)
        let stored = SessionDigest(
            model: "m",
            promptVersion: Prompts.digestVersion,
            transcriptFingerprint: NoteFreshness.fingerprint(of: lines),
            sections: [.init(start: 0, end: 7200, digest: "part 1")],
            sessionDigest: "[00:00–120:00] Mentioned sister Dana around minute 80.",
            createdAt: Date()
        )

        var reportedCoverage: String?
        var progress = AIRunProgress()
        let stream = LongSessionChat.stream(
            transcript: lines,
            history: [],
            question: "How much money did Dana ask to borrow?",
            effort: .normal,
            sessionID: UUID(),
            service: service,
            builder: DigestBuilder(queue: InferenceQueue()),
            loadDigest: { stored },
            saveDigest: { _ in },
            live: { _, change in change(&progress) },
            coverage: { reportedCoverage = $0 }
        )
        var snapshots: [String] = []
        for try await snap in stream { snapshots.append(snap) }

        XCTAssertEqual(snapshots.last, "FINAL ANSWER")
        let coverage = try XCTUnwrap(reportedCoverage)
        XCTAssertTrue(coverage.contains("1 follow-up lookup"))
        XCTAssertTrue(coverage.contains("· Normal."))
        XCTAssertTrue(progress.completedStages.contains(where: { $0.hasPrefix("Searched session") }))
        XCTAssertTrue(progress.completedStages.contains("Read S1 [1:19:00–1:21:00]"))
    }

    func testPatientChatAnswerRefinesPartialContextAndUpdatesCoverage() async throws {
        let stub = ToolLoopStubAssistant()
        stub.planReplies = [
            #"{"calls":[{"tool":"read_section","session":"S1","start":"10:00","end":"15:00"},{"tool":"get_digest","session":"S1"}]}"#
        ]
        var service = AssistantService(assistant: stub, model: "m")
        service.budget = ContextBudget(tokens: 16_384)

        let initialCoverage = TranscriptCoverage(
            transcriptSessions: 2,
            sessionsWithPassages: 0,
            notesSessions: 1,
            searched: true,
            wholeTranscripts: false
        )
        let context = PatientContext(
            text: "===== Session [S1] March 15, 2026 =====\nTherapist note for S1.",
            sources: [CitationSource(tag: "S1", date: date(2026, 3, 15), folderName: "f1")],
            coverage: initialCoverage
        )

        var reportedCoverages: [TranscriptCoverage] = []
        var progress = AIRunProgress()
        let stream = PatientChatAnswer.stream(
            context: context,
            history: [],
            question: "What happened when Dana called?",
            effort: .normal,
            totalBudget: 12_000,
            scope: { self.LocalToolScopeForSample() },
            service: service,
            builder: DigestBuilder(queue: InferenceQueue()),
            live: { _, change in change(&progress) },
            onCoverage: { reportedCoverages.append($0) }
        )
        var snapshots: [String] = []
        for try await snap in stream { snapshots.append(snap) }

        XCTAssertEqual(snapshots.last, "FINAL ANSWER")
        let finalCoverage = try XCTUnwrap(reportedCoverages.last)
        XCTAssertEqual(finalCoverage.effort, .normal)
        XCTAssertEqual(finalCoverage.sessionsWithPassages, 1)
        XCTAssertEqual(finalCoverage.digestSessions, 1)
        XCTAssertTrue(try XCTUnwrap(finalCoverage.label).hasSuffix("· Normal"))
        XCTAssertTrue(progress.completedStages.contains("Searched 2 sessions · 0 sessions with passages"))
        XCTAssertTrue(progress.completedStages.contains("Read S1 [10:00–15:00]"))
        XCTAssertTrue(progress.completedStages.contains("Read digest for S1"))
    }

    func testStoreLocalToolScopeIncludesPatientSessionsAndDigests() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ToolScope-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Dana Cole")
        let s = try store.createSession(for: patient, on: date(2026, 3, 15))
        let transcript = "[00:10] Client: We talked about the boundary with my sister."
        try store.saveTranscript(transcript, for: patient, session: s)
        let digest = SessionDigest(
            model: "m",
            promptVersion: Prompts.digestVersion,
            transcriptFingerprint: NoteFreshness.fingerprint(of: transcript),
            sections: [.init(start: 0, end: 60, digest: "Sister boundary")],
            sessionDigest: "Discussed sister boundary.",
            createdAt: Date()
        )
        try store.saveDigest(digest, for: patient, session: s)

        let scope = store.localToolScope(for: patient)
        XCTAssertEqual(scope.sessions.count, 1)
        XCTAssertEqual(scope.sessions.first?.tag, "S1")
        XCTAssertEqual(scope.sessions.first?.digest?.sessionDigest, "Discussed sister boundary.")
    }

    private func LocalToolScopeForSample() -> LocalToolScope {
        LocalToolScope(sessions: sampleSessions())
    }
}
