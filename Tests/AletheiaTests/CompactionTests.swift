import XCTest
@testable import Aletheia

/// What a fake backend was sent, and the numbers it reports when a run ends.
private final class CompactionBackend: Assistant, @unchecked Sendable {
    var system = ""
    var prompt = ""
    var turns: [PromptTurn] = []
    var task: AITask?
    /// Output tokens to report at the end of the run; nil reports nothing.
    var outputTokens: Int?
    /// Whether that report says the run stopped at the reply limit.
    var reachedLimit = false
    var summary = "Compact notes of the conversation."

    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { ["m"] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String { summary }
    func stream(
        model: String,
        system: String,
        turns: [PromptTurn],
        prompt: String,
        task: AITask,
        grammar: LocalLLMGrammar?,
        onStats: (@Sendable (AIRunStats) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        self.system = system
        self.prompt = prompt
        self.turns = turns
        self.task = task
        let summary = summary
        let outputTokens = outputTokens
        let reachedLimit = reachedLimit
        return AsyncThrowingStream { continuation in
            continuation.yield(summary)
            if let outputTokens {
                var stats = AIRunStats(promptTokens: 400, promptNanos: 1_000_000, outputTokens: outputTokens, outputNanos: 1_000_000)
                stats.reachedReplyLimit = reachedLimit
                onStats?(stats)
            }
            continuation.finish()
        }
    }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}

private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = 0
    func add(_ event: AIRunEvent) {
        if case .finished = event { lock.lock(); finished += 1; lock.unlock() }
    }
    var finishedCount: Int { lock.lock(); defer { lock.unlock() }; return finished }
}

/// Compact: the earlier summary rides in the system turn, the focus is the
/// final instruction, and a summary cut off at the reply limit never replaces
/// the chat.
final class CompactionTests: XCTestCase {
    private let bullets = ChatMessage(role: .user, text: "Answer in bullets from now on.")
    private let earlier = ChatMessage(role: .summary, text: "Earlier: asked about sleep.")
    private let question = ChatMessage(role: .user, text: "Does she nap?")
    private let answer = ChatMessage(role: .assistant, text: "Yes, most afternoons.")

    private func run(_ service: AssistantService, history: [ChatMessage], focus: String) async throws -> [String] {
        var out: [String] = []
        for try await text in service.streamCompaction(history: history, focus: focus) { out.append(text) }
        return out
    }

    // MARK: - Where things go

    func testEarlierSummaryIsInTheSystemTurnAndTheFocusIsTheFinalInstruction() async throws {
        let backend = CompactionBackend()
        let service = AssistantService(assistant: backend, model: "m")
        let history = [bullets, earlier, question, answer]

        let pieces = try await run(service, history: history, focus: "napping")

        XCTAssertEqual(pieces.last, backend.summary)
        XCTAssertEqual(backend.task, .compaction)
        XCTAssertEqual(backend.system, Prompts.compactSystem(service.systemPrompt, history: history))
        XCTAssertTrue(backend.system.contains("<summary>\nEarlier: asked about sleep.\n</summary>"))
        XCTAssertTrue(backend.system.contains("- Answer in bullets from now on."))
        XCTAssertEqual(backend.prompt, Prompts.compactChat(focus: "napping"))
        XCTAssertFalse(backend.prompt.contains("Earlier: asked about sleep."), "the summary is not in the final prompt")
        XCTAssertEqual(backend.turns, [
            PromptTurn(role: .user, text: "Does she nap?"),
            PromptTurn(role: .assistant, text: "Yes, most afternoons."),
        ])
    }

    func testFocusLineIsInTheInstructionOnlyWhenGiven() {
        let focused = Prompts.compactChat(focus: "medication changes")
        XCTAssertTrue(focused.contains("The therapist asked to keep this in particular, in full detail: medication changes"))
        XCTAssertTrue(focused.hasSuffix("in full detail: medication changes"), "the focus is the last thing the model reads")
        XCTAssertFalse(Prompts.compactChat(focus: "").contains("in particular"))
        XCTAssertTrue(Prompts.compactChat(focus: "").contains("Write a summary that will replace it"))
    }

    func testSystemTurnIsJustTheInstructionsBeforeAnySummary() {
        XCTAssertEqual(Prompts.compactSystem("BASE", history: [bullets, question]), "BASE")
    }

    // MARK: - The reply limit

    func testSummaryGetsAllTheRoomAReplyHas() {
        XCTAssertEqual(AITask.compaction.maxTokens, ContextBudget.replyHeadroomTokens)
        XCTAssertEqual(AITask.compaction.maxTokens, AITask.chat.maxTokens)
    }

    func testSummaryThatReachedTheReplyLimitFailsAsCutOff() async {
        let backend = CompactionBackend()
        backend.outputTokens = AITask.compaction.maxTokens
        backend.reachedLimit = true
        let service = AssistantService(assistant: backend, model: "m")
        do {
            _ = try await run(service, history: [question, answer], focus: "")
            XCTFail("a summary cut off at the limit should fail")
        } catch {
            XCTAssertEqual(error as? CompactionError, .cutOff)
            XCTAssertTrue(error.localizedDescription.contains("Try Compact again"))
        }
    }

    /// A summary the model finished is kept, however long it is: only the
    /// engine's word that it stopped at the limit means it is cut off.
    func testSummaryTheModelFinishedSucceedsAtAnyLength() async throws {
        for tokens in [100, AITask.compaction.maxTokens - 1, AITask.compaction.maxTokens] {
            let backend = CompactionBackend()
            backend.outputTokens = tokens
            backend.reachedLimit = false
            let service = AssistantService(assistant: backend, model: "m")
            let pieces = try await run(service, history: [question, answer], focus: "")
            XCTAssertEqual(pieces.last, backend.summary, "\(tokens) tokens")
        }
    }

    /// A shorter limit than the task's (a tight window) is still caught.
    func testSummaryCutOffBelowTheTaskLimitStillFails() async {
        let backend = CompactionBackend()
        backend.outputTokens = AITask.compaction.maxTokens / 4
        backend.reachedLimit = true
        let service = AssistantService(assistant: backend, model: "m")
        do {
            _ = try await run(service, history: [question, answer], focus: "")
            XCTFail("a summary cut off at a smaller limit should fail")
        } catch {
            XCTAssertEqual(error as? CompactionError, .cutOff)
        }
    }

    func testSummaryWithNoReportedCountSucceeds() async throws {
        let backend = CompactionBackend()
        backend.outputTokens = nil
        let service = AssistantService(assistant: backend, model: "m")
        let pieces = try await run(service, history: [question, answer], focus: "")
        XCTAssertEqual(pieces.last, backend.summary)
    }

    /// The run's own report still reaches whoever listens for it.
    func testTheRunReportIsStillPassedOn() async throws {
        let backend = CompactionBackend()
        backend.outputTokens = 100
        let log = EventLog()
        var service = AssistantService(assistant: backend, model: "m")
        service.report = { log.add($0) }
        _ = try await run(service, history: [question, answer], focus: "")
        XCTAssertEqual(log.finishedCount, 1)
    }
}
