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
    // MARK: Stats parsing

    private let finalLine = """
    {"model":"llama3.1:8b","created_at":"2026-10-13T10:00:00Z","response":"","done":true,"done_reason":"stop","total_duration":9000000000,"load_duration":50000000,"prompt_eval_count":2400,"prompt_eval_duration":3000000000,"eval_count":300,"eval_duration":6000000000}
    """

    func testFinalChunkCarriesRunStats() throws {
        let chunk = try XCTUnwrap(OllamaClient.streamChunk(fromLine: finalLine, expectedPromptTokens: 2500))
        XCTAssertTrue(chunk.done)
        let stats = try XCTUnwrap(chunk.stats)
        XCTAssertEqual(stats.promptTokens, 2400)
        XCTAssertEqual(stats.promptNanos, 3_000_000_000)
        XCTAssertEqual(stats.outputTokens, 300)
        XCTAssertEqual(stats.outputNanos, 6_000_000_000)
        XCTAssertEqual(try XCTUnwrap(stats.readTokensPerSecond), 800, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(stats.writeTokensPerSecond), 50, accuracy: 0.001)
    }

    func testMidStreamChunkHasNoStats() throws {
        let chunk = try XCTUnwrap(OllamaClient.streamChunk(fromLine: #"{"response":"Hi","done":false}"#))
        XCTAssertNil(chunk.stats)
    }

    func testFinalChunkWithoutCountsStillParses() throws {
        let chunk = try XCTUnwrap(OllamaClient.streamChunk(fromLine: #"{"response":"","done":true}"#))
        XCTAssertNil(chunk.stats?.promptTokens)
        XCTAssertFalse(try XCTUnwrap(chunk.stats).possiblyTruncated)
    }

    // MARK: Tripwire

    func testTripwireFlagsAPromptOllamaReadLittleOf() {
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
        // 40,000 characters sent, the first 30,000 already held by Ollama: only the
        // 10,000-character tail is read, and that is what the tripwire expects.
        let memory = PromptPrefixMemory()
        let first = String(repeating: "a", count: 40_000)
        XCTAssertEqual(memory.sharedPrefixCharacters(model: "m", text: first), 0)
        let second = String(first.prefix(30_000)) + String(repeating: "b", count: 10_000)
        let cached = memory.sharedPrefixCharacters(model: "m", text: second)
        XCTAssertEqual(cached, 30_000)
        let expected = ContextBudget.estimatedTokens(forCharacters: second.count - cached)
        XCTAssertFalse(AIRunStats(promptTokens: 2500, expectedPromptTokens: expected).possiblyTruncated)
        // The same small count against the uncached estimate would have fired.
        XCTAssertTrue(AIRunStats(promptTokens: 2500, expectedPromptTokens: ContextBudget.estimatedTokens(forCharacters: second.count)).possiblyTruncated)
    }

    func testPrefixMemoryIsPerModel() {
        let memory = PromptPrefixMemory()
        let text = String(repeating: "x", count: 6000)
        _ = memory.sharedPrefixCharacters(model: "a", text: text)
        XCTAssertEqual(memory.sharedPrefixCharacters(model: "b", text: text), 0)
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

    func testSpeedRoundTripsThroughDefaultsForm() {
        let speed = ModelSpeed(read: 120, write: 30)
        XCTAssertEqual(ModelSpeed(stored: speed.stored), speed)
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
        XCTAssertEqual(AIProgressFormat.tokens(412), "412 tokens")
        XCTAssertEqual(AIProgressFormat.tokens(1), "1 token")
    }

    func testEstimateWording() {
        XCTAssertNil(AIProgressFormat.readingRemaining(estimatedTokens: 31_000, tokensPerSecond: nil, elapsed: 5))
        XCTAssertEqual(AIProgressFormat.readingRemaining(estimatedTokens: 6_000, tokensPerSecond: 100, elapsed: 20), 40)
        XCTAssertEqual(AIProgressFormat.readingRemaining(estimatedTokens: 6_000, tokensPerSecond: 100, elapsed: 90), 0)
        XCTAssertEqual(AIProgressFormat.remaining(60), "about 1 min left")
        XCTAssertEqual(AIProgressFormat.remaining(200), "about 3 min left")
        XCTAssertEqual(AIProgressFormat.remaining(20), "less than a minute left")
        XCTAssertEqual(AIProgressFormat.remaining(0), "taking longer than estimated")
        XCTAssertEqual(try XCTUnwrap(AIProgressFormat.readingFraction(estimatedTokens: 6_000, tokensPerSecond: 100, elapsed: 30)), 0.5, accuracy: 0.001)
        XCTAssertEqual(AIProgressFormat.readingFraction(estimatedTokens: 6_000, tokensPerSecond: 100, elapsed: 500), 0.95)
        XCTAssertNil(AIProgressFormat.readingFraction(estimatedTokens: nil, tokensPerSecond: 100, elapsed: 1))
    }

    func testLinesWhileReadingAndWriting() {
        let start = Date(timeIntervalSince1970: 1_000)
        var progress = AIRunProgress(readTitle: "Reading the session", writeTitle: "Writing the note", startedAt: start)
        progress.estimatedPromptTokens = 31_000

        let reading = AIProgressFormat.lines(progress, now: start.addingTimeInterval(42), readTokensPerSecond: 31_000.0 / 100)
        XCTAssertEqual(reading, [
            AIProgressLine(state: .current, text: "Reading the session · ~31K tokens · 0:42 · about 1 min left"),
            AIProgressLine(state: .pending, text: "Writing the note"),
        ])

        let unknownSpeed = AIProgressFormat.lines(progress, now: start.addingTimeInterval(3), readTokensPerSecond: nil)
        XCTAssertEqual(unknownSpeed[0].text, "Reading the session · ~31K tokens · 0:03")

        progress.firstTokenAt = start.addingTimeInterval(65)
        progress.tokensWritten = 412
        let writing = AIProgressFormat.lines(progress, now: start.addingTimeInterval(77), readTokensPerSecond: nil)
        XCTAssertEqual(writing, [
            AIProgressLine(state: .done, text: "Reading the session · ~31K tokens · 1:05"),
            AIProgressLine(state: .current, text: "Writing the note · 412 tokens · 0:12"),
        ])
    }

    // MARK: Effort

    func testEffortDefaultsToNormal() {
        XCTAssertEqual(AnswerEffort.default, .normal)
        XCTAssertEqual(AnswerEffort.allCases.map(\.displayName), ["Fast", "Normal", "Focus"])
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
