import XCTest
@testable import Aletheia

private final class CountingAssistant: Assistant, @unchecked Sendable {
    var sent = 0
    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { [] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String { sent += 1; return "ok" }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}

final class AIProgressTests: XCTestCase {
    // MARK: Stats

    func testRunStatsGiveReadAndWriteSpeeds() throws {
        let stats = AIRunStats(
            promptTokens: 2400, promptNanos: 3_000_000_000,
            outputTokens: 300, outputNanos: 6_000_000_000, expectedPromptTokens: 2500)
        XCTAssertEqual(try XCTUnwrap(stats.readTokensPerSecond), 800, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(stats.writeTokensPerSecond), 50, accuracy: 0.001)
    }

    func testStatsWithoutCountsAreNotTruncated() {
        let stats = AIRunStats()
        XCTAssertNil(stats.promptTokens)
        XCTAssertFalse(stats.possiblyTruncated)
    }

    // MARK: Tripwire

    func testTripwireFlagsAPromptTheEngineReadLittleOf() {
        XCTAssertTrue(AIRunStats(promptTokens: 4096, expectedPromptTokens: 20_000).possiblyTruncated)
        XCTAssertFalse(AIRunStats(promptTokens: 19_000, expectedPromptTokens: 20_000).possiblyTruncated)
        // Exactly 60% is not flagged; below it is.
        XCTAssertFalse(AIRunStats(promptTokens: 12_000, expectedPromptTokens: 20_000).possiblyTruncated)
        XCTAssertTrue(AIRunStats(promptTokens: 11_999, expectedPromptTokens: 20_000).possiblyTruncated)
        // A complete read of ordinary English (about 4 characters a token) is not flagged.
        let text = 60_000
        XCTAssertFalse(AIRunStats(promptTokens: text / 4, expectedPromptTokens: ContextBudget.estimatedTokens(forCharacters: text)).possiblyTruncated)
    }

    func testTripwireIgnoresSmallPromptsAndMissingCounts() {
        XCTAssertFalse(AIRunStats(promptTokens: 10, expectedPromptTokens: 400).possiblyTruncated)
        XCTAssertFalse(AIRunStats(promptTokens: nil, expectedPromptTokens: 20_000).possiblyTruncated)
    }

    func testCachedPrefixIsNotMistakenForTruncation() {
        // The tripwire expects only the uncached tail: 2,500 tokens read of an
        // expected 2,500 is complete, while the same count against the whole
        // prompt's estimate would have fired.
        let whole = ContextBudget.estimatedTokens(forCharacters: 40_000)
        let tail = ContextBudget.estimatedTokens(forCharacters: 10_000)
        XCTAssertFalse(AIRunStats(promptTokens: 2500, expectedPromptTokens: tail).possiblyTruncated)
        XCTAssertTrue(AIRunStats(promptTokens: 2500, expectedPromptTokens: whole).possiblyTruncated)
    }

    // MARK: Speeds

    func testSpeedIsAMovingAverage() {
        var speed = ModelSpeed()
        speed = speed.folding(AIRunStats(promptTokens: 1000, promptNanos: 10_000_000_000))  // 100 tok/s
        XCTAssertEqual(speed.read, 100)
        speed = speed.folding(AIRunStats(promptTokens: 2000, promptNanos: 10_000_000_000))  // 200 tok/s
        XCTAssertEqual(try XCTUnwrap(speed.read), 130, accuracy: 0.001)
        XCTAssertNil(speed.write)
    }

    func testTooSmallARunDoesNotMoveTheSpeed() {
        let speed = ModelSpeed(read: 100).folding(AIRunStats(promptTokens: 50, promptNanos: 1_000_000_000))
        XCTAssertEqual(speed.read, 100)
    }

    func testCacheHitRunsDoNotCountAsReadSpeed() {
        // Read far less than we sent: a cached prefix.
        XCTAssertNil(AIRunStats(promptTokens: 300, promptNanos: 1_000_000_000, expectedPromptTokens: 5000).readTokensPerSecond)
        // Implausibly fast.
        XCTAssertNil(AIRunStats(promptTokens: 4000, promptNanos: 40_000_000, expectedPromptTokens: 4000).readTokensPerSecond)
        XCTAssertNotNil(AIRunStats(promptTokens: 4000, promptNanos: 4_000_000_000, expectedPromptTokens: 4500).readTokensPerSecond)
        let speed = ModelSpeed(read: 100).folding(AIRunStats(promptTokens: 300, promptNanos: 1_000_000_000, expectedPromptTokens: 5000))
        XCTAssertEqual(speed.read, 100)
    }

    func testPartialPrefixHitIsNotRecordedAsReadSpeed() {
        // 8K prompt, 6K cached: the engine counts all 8K but spent time on 2K only.
        var stats = AIRunStats(promptTokens: 8000, promptNanos: 4_000_000_000, expectedPromptTokens: 2200)
        XCTAssertNotNil(stats.readTokensPerSecond)
        stats.reusedPrefix = true
        XCTAssertNil(stats.readTokensPerSecond)
        XCTAssertEqual(ModelSpeed(read: 100).folding(stats).read, 100)
    }

    func testCacheFilterBoundaries() {
        // Exactly half of what was expected still counts; just under does not.
        XCTAssertNotNil(AIRunStats(promptTokens: 2500, promptNanos: 25_000_000_000, expectedPromptTokens: 5000).readTokensPerSecond)
        XCTAssertNil(AIRunStats(promptTokens: 2499, promptNanos: 25_000_000_000, expectedPromptTokens: 5000).readTokensPerSecond)
        // No expectation (0) never filters on size.
        XCTAssertNotNil(AIRunStats(promptTokens: 300, promptNanos: 3_000_000_000, expectedPromptTokens: 0).readTokensPerSecond)
    }

    /// Stage and elapsed time only: no token counts or time-left guesses.
    func testWritingLineIsTheStageAndElapsedTime() {
        var progress = AIRunProgress(startedAt: Date(timeIntervalSince1970: 0))
        progress.firstTokenAt = Date(timeIntervalSince1970: 10)
        progress.tokensWritten = 50
        progress.estimatedPromptTokens = 24_000
        XCTAssertEqual(AIProgressFormat.statusLine(progress, now: Date(timeIntervalSince1970: 20)), "Writing… · 0:20")
    }

    func testOutputLengthIsAveragedPerTask() throws {
        func run(_ task: AITask, tokens: Int) -> AIRunStats {
            AIRunStats(outputTokens: tokens, outputNanos: 5_000_000_000, task: task)
        }
        var speed = ModelSpeed()
        speed = speed.folding(run(.note, tokens: 1000)).folding(run(.chat, tokens: 100))
        XCTAssertEqual(speed.expectedOutput(for: .note), 1000)
        XCTAssertEqual(speed.expectedOutput(for: .chat), 100)
        XCTAssertNil(speed.expectedOutput(for: .digest))
        speed = speed.folding(run(.chat, tokens: 200))
        XCTAssertEqual(try XCTUnwrap(speed.expectedOutput(for: .chat)), 130)
        XCTAssertEqual(speed.expectedOutput(for: .note), 1000)
        // A run without a task, or too short to time, leaves outputs alone.
        XCTAssertEqual(speed.folding(AIRunStats(outputTokens: 900, outputNanos: 5_000_000_000)).outputs, speed.outputs)
        XCTAssertEqual(speed.folding(run(.note, tokens: 10)).outputs, speed.outputs)
    }

    func testStoredFormRoundTripsAndToleratesLegacyOrJunk() {
        let speed = ModelSpeed(read: 120, write: 30, outputs: ["note": 800, "chat": 150])
        XCTAssertEqual(ModelSpeed(stored: speed.stored), speed)
        // What main stored before per-task outputs: read and write only.
        XCTAssertEqual(ModelSpeed(stored: ["read": 120, "write": 30]), ModelSpeed(read: 120, write: 30))
        XCTAssertEqual(ModelSpeed(stored: ["bogus": 1, "output.": 2]).read, nil)
        XCTAssertEqual(ModelSpeed(stored: [:]), ModelSpeed())
    }

    @MainActor
    func testSettingsRecordSpeedsOverLegacyStoredHistory() throws {
        let settings = AppSettings.shared
        let original = settings.modelSpeeds
        defer { settings.modelSpeeds = original }
        // The shape main stored: read and write only.
        settings.modelSpeeds = ["m": ["read": 90, "write": 12]]
        XCTAssertEqual(settings.speed(for: "m"), ModelSpeed(read: 90, write: 12))
        XCTAssertEqual(settings.speed(for: "other"), ModelSpeed())
        settings.recordSpeeds(model: "m", from: AIRunStats(
            promptTokens: 1000, promptNanos: 10_000_000_000, outputTokens: 100, outputNanos: 5_000_000_000, task: .note))
        XCTAssertEqual(settings.speed(for: "m").outputs, ["note": 100])
        XCTAssertEqual(try XCTUnwrap(settings.speed(for: "m").read), 93, accuracy: 0.001)
    }

    // MARK: Budget

    private func mac(_ gb: Int, appleSilicon: Bool = true) -> HardwareCapabilities {
        HardwareCapabilities(isAppleSilicon: appleSilicon, physicalMemoryGB: gb, coreCount: 8, chipDescription: "Test")
    }

    func testBudgetTiersPerHardware() {
        XCTAssertEqual(ModelAdvisor.contextBudgetTokens(for: mac(8)), 16_384)
        XCTAssertEqual(ModelAdvisor.contextBudgetTokens(for: mac(16)), 32_768)
        XCTAssertEqual(ModelAdvisor.contextBudgetTokens(for: mac(24)), 32_768)
        XCTAssertEqual(ModelAdvisor.contextBudgetTokens(for: mac(32)), 65_536)
        XCTAssertEqual(ModelAdvisor.contextBudgetTokens(for: mac(128)), 65_536)
        XCTAssertEqual(ModelAdvisor.contextBudgetTokens(for: mac(4)), 8_192)
    }

    func testIntelIsOneTierLowerWithAFloor() {
        XCTAssertEqual(ModelAdvisor.contextBudgetTokens(for: mac(8, appleSilicon: false)), 8_192)
        XCTAssertEqual(ModelAdvisor.contextBudgetTokens(for: mac(16, appleSilicon: false)), 16_384)
        XCTAssertEqual(ModelAdvisor.contextBudgetTokens(for: mac(32, appleSilicon: false)), 32_768)
        XCTAssertEqual(ModelAdvisor.contextBudgetTokens(for: mac(4, appleSilicon: false)), 8_192)
    }


    func testFits() {
        let budget = ContextBudget(tokens: 16_384)
        XCTAssertTrue(budget.fits(promptCharacters: 40_000))
        XCTAssertFalse(budget.fits(promptCharacters: 50_000))
        XCTAssertEqual(budget.approximateMinutes, 39)
    }

    func testOverBudgetPromptIsRefusedNotSent() async {
        let fake = CountingAssistant()
        var service = AssistantService(assistant: fake, model: "m")
        service.budget = ContextBudget(tokens: 16_384)
        let huge = String(repeating: "word ", count: 20_000)  // 100,000 characters

        do {
            _ = try await service.progressNote(format: .narrative, transcript: huge)
            XCTFail("expected the budget error")
        } catch let error as ContextBudgetError {
            XCTAssertEqual(error.minutes, 39)
            XCTAssertTrue(error.localizedDescription.contains("~39 min"))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(fake.sent, 0)

        var thrown: Error?
        do {
            for try await _ in service.streamProgressNote(format: .narrative, transcript: huge) {}
        } catch { thrown = error }
        XCTAssertTrue(thrown is ContextBudgetError)
        XCTAssertEqual(fake.sent, 0)
    }

    func testLongJapaneseNoteIsRefusedNotSent() async {
        let fake = CountingAssistant()
        var service = AssistantService(assistant: fake, model: "m")
        service.budget = ContextBudget(tokens: 32_768)
        let japanese = String(repeating: "今日はとても疲れました。", count: 2_500)   // 30,000 characters
        XCTAssertFalse(service.fits(prompt: Prompts.progressNote(format: .narrative, transcript: japanese)))
        var thrown: Error?
        do {
            for try await _ in service.streamProgressNote(format: .narrative, transcript: japanese) {}
        } catch { thrown = error }
        XCTAssertTrue(thrown is ContextBudgetError)
        XCTAssertEqual(fake.sent, 0)
    }

    func testJapaneseConversationLeavesLessRoomForPatientMaterial() {
        var service = AssistantService(assistant: CountingAssistant(), model: "m")
        service.budget = ContextBudget(tokens: 32_768)
        let english = service.patientContextCharacters(
            history: [ChatMessage(role: .user, text: String(repeating: "a", count: 3_000))], question: "q")
        let japanese = service.patientContextCharacters(
            history: [ChatMessage(role: .user, text: String(repeating: "疲", count: 3_000))], question: "q")
        XCTAssertGreaterThan(english, 0)
        XCTAssertLessThan(japanese, english)
    }

    func testReadingEstimateCountsByScript() async throws {
        let fake = CountingAssistant()
        var service = AssistantService(assistant: fake, model: "m")
        service.budget = ContextBudget(tokens: 16_384)
        let events = EventLog()
        service.report = { events.add($0) }
        let transcript = "今日はとても疲れました。"
        for try await _ in service.streamProgressNote(format: .narrative, transcript: transcript) {}
        let prompt = Prompts.progressNote(
            format: .narrative, transcript: transcript, notes: "", comments: [], verbosity: .default, instructions: nil)
        XCTAssertEqual(events.readingEstimates.first,
                       ContextBudget.estimatedTokens(system: service.systemPrompt, prompt: prompt))
        XCTAssertGreaterThan(try XCTUnwrap(events.readingEstimates.first),
                             ContextBudget.estimatedTokens(forCharacters: service.systemPrompt.count + prompt.count))
    }

    func testWithinBudgetPromptIsSentAndReported() async throws {
        let fake = CountingAssistant()
        var service = AssistantService(assistant: fake, model: "m")
        service.budget = ContextBudget(tokens: 16_384)
        let events = EventLog()
        service.report = { events.add($0) }
        for try await _ in service.streamProgressNote(format: .narrative, transcript: "short") {}
        XCTAssertEqual(fake.sent, 1)
        XCTAssertEqual(events.readingEstimates.count, 1)
        // The shared estimate is what the progress display shows.
        let prompt = Prompts.progressNote(
            format: .narrative, transcript: "short", notes: "", comments: [], verbosity: .default, instructions: nil)
        XCTAssertEqual(events.readingEstimates.first,
                       ContextBudget.estimatedTokens(forCharacters: service.systemPrompt.count + prompt.count))
        XCTAssertEqual(ContextBudget.estimatedTokens(forCharacters: 3_000), 1_000)
    }

    @MainActor
    func testStaleRunEventIsIgnored() async throws {
        let runner = ChatStreamRunner()
        let previous = runner.reporter
        let current = runner.reporter
        previous(.reading(estimatedTokens: 111))
        previous(.finished(AIRunStats(outputTokens: 5)))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(runner.progress.estimatedPromptTokens)
        XCTAssertNil(runner.progress.stats)
        current(.reading(estimatedTokens: 222))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(runner.progress.estimatedPromptTokens, 222)
    }

    // MARK: Progress wording

    func testElapsedAndTokenFormatting() {
        XCTAssertEqual(AIProgressFormat.elapsed(0), "0:00")
        XCTAssertEqual(AIProgressFormat.elapsed(42.9), "0:42")
        XCTAssertEqual(AIProgressFormat.elapsed(605), "10:05")
        XCTAssertEqual(AIProgressFormat.elapsed(-3), "0:00")
        XCTAssertEqual(AIProgressFormat.estimatedTokens(800), "~800 tokens")
        XCTAssertEqual(AIProgressFormat.estimatedTokens(31_200), "~31K tokens")
    }

    func testEstimateWording() {
        XCTAssertEqual(try XCTUnwrap(AIProgressFormat.readingFraction(estimatedTokens: 6_000, tokensPerSecond: 100, elapsed: 30)), 0.5, accuracy: 0.001)
        XCTAssertEqual(AIProgressFormat.readingFraction(estimatedTokens: 6_000, tokensPerSecond: 100, elapsed: 500), 0.95)
        XCTAssertNil(AIProgressFormat.readingFraction(estimatedTokens: nil, tokensPerSecond: 100, elapsed: 1))
    }

    func testStatusLineWhileReadingAndWriting() {
        let start = Date(timeIntervalSince1970: 1_000)
        var progress = AIRunProgress(readTitle: "Reading the session", writeTitle: "Writing the note", startedAt: start)
        progress.estimatedPromptTokens = 31_000

        let reading = AIProgressFormat.statusLine(progress, now: start.addingTimeInterval(42))
        XCTAssertEqual(reading, "Reading the session… · 0:42")

        let unknownSpeed = AIProgressFormat.statusLine(progress, now: start.addingTimeInterval(3))
        XCTAssertEqual(unknownSpeed, "Reading the session… · 0:03")

        // The line replaces itself: once text arrives it says only what is being written.
        progress.firstTokenAt = start.addingTimeInterval(65)
        progress.tokensWritten = 412
        let writing = AIProgressFormat.statusLine(progress, now: start.addingTimeInterval(77))
        XCTAssertEqual(writing, "Writing the note… · 1:17")
    }

    func testStatusLinePutsWhatSearchFoundBeforeTheReading() {
        let start = Date(timeIntervalSince1970: 1_000)
        var progress = AIRunProgress(readTitle: "Reading what was gathered", writeTitle: "Writing the answer", startedAt: start)
        progress.lead = "1 mention, in the Oct 13 session"
        progress.estimatedPromptTokens = 3_000
        XCTAssertEqual(
            AIProgressFormat.statusLine(progress, now: start.addingTimeInterval(4)),
            "1 mention, in the Oct 13 session. Reading what was gathered… · 0:04")
        progress.firstTokenAt = start.addingTimeInterval(9)
        progress.tokensWritten = 20
        XCTAssertEqual(
            AIProgressFormat.statusLine(progress, now: start.addingTimeInterval(12)),
            "Writing the answer… · 0:12")
    }

    // MARK: Effort & Multi-Stage Progress

    func testEffortDefaultsToNormal() {
        XCTAssertEqual(AnswerEffort.default, .normal)
        XCTAssertEqual(AnswerEffort.allCases.map(\.displayName), ["Fast", "Normal", "Focus"])
        XCTAssertEqual(AnswerEffort.fast.maxToolCalls, 0)
        XCTAssertEqual(AnswerEffort.normal.maxToolCalls, 4)
        XCTAssertEqual(AnswerEffort.focus.maxToolCalls, 10)
        XCTAssertEqual(AnswerEffort.fast.maxRefinementRounds, 0)
        XCTAssertEqual(AnswerEffort.normal.maxRefinementRounds, 1)
        XCTAssertEqual(AnswerEffort.focus.maxRefinementRounds, 2)
    }

    func testTheElapsedCounterRunsFromTheFirstStageAcrossStages() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var progress = AIRunProgress(readTitle: "Reading part 1 of 2", writeTitle: "Summarizing part 1 of 2", startedAt: t0)
        progress.estimatedPromptTokens = 2_000
        progress.tokensWritten = 120
        progress.lead = "4 mentions, across 2 sessions"
        progress.recordCompletedStage("Searched 12 sessions · 4 matching passages")
        progress.beginStage(readTitle: "Checking what to look up", writeTitle: "Selecting passages", startedAt: t0.addingTimeInterval(5))
        progress.tokensWritten = 30
        progress.beginStage(readTitle: "Reading the sessions", writeTitle: "Writing the answer", startedAt: t0.addingTimeInterval(12))
        progress.estimatedPromptTokens = 4_000

        XCTAssertEqual(progress.runStartedAt, t0)
        XCTAssertEqual(progress.completedStages, [
            "Searched 12 sessions · 4 matching passages",
            "Reading part 1 of 2 · ~2K tokens · 0:05",
            "Checking what to look up · 0:07",
        ])
        XCTAssertEqual(
            AIProgressFormat.statusLine(progress, now: t0.addingTimeInterval(15)),
            "4 mentions, across 2 sessions. Reading the sessions… · 0:15")
    }

    // MARK: Status line per surface

    func testEachSurfaceSaysWhatItIsDoing() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        // Ask, single session (SessionDetailView.sendChat's titles).
        let sessionAsk = AIRunProgress(readTitle: "Reading the session", writeTitle: "Writing the answer", startedAt: t0)
        XCTAssertEqual(AIProgressFormat.statusLine(sessionAsk, now: t0.addingTimeInterval(2)),
                       "Reading the session… · 0:02")
        // Background digest: DigestBuilder's stage titles.
        var digest = AIRunProgress(readTitle: "Reading", startedAt: t0)
        digest.beginStage(readTitle: "Reading part 2 of 5", writeTitle: DigestBuilder.writeTitle, startedAt: t0.addingTimeInterval(30))
        digest.firstTokenAt = t0.addingTimeInterval(40)
        digest.tokensWritten = 90
        XCTAssertEqual(AIProgressFormat.statusLine(digest, now: t0.addingTimeInterval(61)),
                       "\(DigestBuilder.writeTitle)… · 1:01")
        // Compaction.
        let compact = AIRunProgress(readTitle: "Reading the conversation", writeTitle: "Summarizing the conversation", startedAt: t0)
        XCTAssertEqual(AIProgressFormat.statusLine(compact, now: t0),
                       "Reading the conversation… · 0:00")
    }
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AIRunEvent] = []
    func add(_ event: AIRunEvent) { lock.lock(); events.append(event); lock.unlock() }
    var readingEstimates: [Int] {
        lock.lock(); defer { lock.unlock() }
        return events.compactMap { if case .reading(let tokens) = $0 { return tokens } else { return nil } }
    }
}
