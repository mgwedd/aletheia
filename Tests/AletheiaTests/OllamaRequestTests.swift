import XCTest
@testable import Aletheia

/// A fake that records the task each request was tagged with.
private final class TaskRecordingAssistant: Assistant, @unchecked Sendable {
    var tasks: [AITask] = []
    func isReachable() async -> Bool { true }
    func listModels() async throws -> [String] { ["m"] }
    func hasModel(_ name: String) async -> Bool { true }
    func generate(model: String, system: String, prompt: String) async throws -> String { "" }
    func generate(model: String, system: String, prompt: String, task: AITask) async throws -> String {
        tasks.append(task)
        return ""
    }
    func pullModel(_ name: String, onProgress: @escaping (Double, String) -> Void) async throws {}
}

final class OllamaRequestTests: XCTestCase {
    private func options(_ body: [String: Any]) -> [String: Any] { body["options"] as? [String: Any] ?? [:] }

    func testContextIsTheMacsBudgetWhateverThePromptSize() {
        let small = OllamaClient.generateBody(model: "m", system: "s", prompt: "hi", stream: true, contextTokens: 16_384)
        let large = OllamaClient.generateBody(
            model: "m", system: "s", prompt: String(repeating: "x", count: 40_000), stream: true, contextTokens: 16_384)
        XCTAssertEqual(options(small)["num_ctx"] as? Int, 16_384)
        XCTAssertEqual(options(large)["num_ctx"] as? Int, 16_384)
        let defaulted = OllamaClient.generateBody(model: "m", system: "", prompt: "p", stream: false)
        XCTAssertEqual(options(defaulted)["num_ctx"] as? Int, ContextBudget.current.tokens)
    }

    func testBodySkipsAnEmptySystemPromptAndKeepsTheModelLoaded() {
        let body = OllamaClient.generateBody(model: "m", system: " ", prompt: "p", stream: true)
        XCTAssertNil(body["system"])
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["keep_alive"] as? String, "30m")
    }

    func testTemperatureFollowsTheTask() {
        func temperature(_ task: AITask) -> Double? {
            let body = OllamaClient.generateBody(model: "m", system: "", prompt: "p", stream: false, task: task)
            return options(body)["temperature"] as? Double
        }
        XCTAssertEqual(temperature(.note), 0.2)
        XCTAssertEqual(temperature(.digest), 0.2)
        XCTAssertEqual(temperature(.compaction), 0.2)
        XCTAssertEqual(temperature(.chat), 0.3)
    }

    func testWarmUpUsesTheSameContextAndKeepAliveAsRealRequests() {
        let warm = OllamaClient.warmUpBody(model: "m", contextTokens: 32_768)
        let real = OllamaClient.generateBody(model: "m", system: "s", prompt: "p", stream: true, contextTokens: 32_768)
        XCTAssertEqual(warm["prompt"] as? String, "")
        XCTAssertEqual(warm["keep_alive"] as? String, real["keep_alive"] as? String)
        XCTAssertEqual(options(warm)["num_ctx"] as? Int, options(real)["num_ctx"] as? Int)
    }

    func testUnloadRequestShape() {
        let body = OllamaClient.unloadBody(model: "m")
        XCTAssertEqual(body["model"] as? String, "m")
        XCTAssertEqual(body["prompt"] as? String, "")
        XCTAssertEqual(body["keep_alive"] as? Int, 0)
    }

    private let url = URL(string: "http://127.0.0.1:11434")!

    func testFailedWarmUpDoesNotDebounce() {
        let residency = OllamaResidency()
        let t0 = Date()
        XCTAssertTrue(residency.claimWarmUp(baseURL: url, model: "m", now: t0))
        // No `warmed` (the request failed), so an immediate retry is allowed.
        XCTAssertTrue(residency.claimWarmUp(baseURL: url, model: "m", now: t0.addingTimeInterval(1)))
        XCTAssertTrue(residency.takeLoaded().isEmpty)
    }

    func testChangingBaseURLIsNotDebounced() {
        let residency = OllamaResidency()
        let t0 = Date()
        residency.warmed(baseURL: url, model: "m", now: t0)
        let other = URL(string: "http://127.0.0.1:11435")!
        XCTAssertTrue(residency.claimWarmUp(baseURL: other, model: "m", now: t0.addingTimeInterval(1)))
    }

    func testLockUnloadsEveryModelUsedSinceTheLastUnload() {
        let residency = OllamaResidency()
        residency.began(baseURL: url, model: "a"); residency.ended()
        residency.began(baseURL: url, model: "b"); residency.ended()
        residency.warmed(baseURL: url, model: "c")
        XCTAssertEqual(Set(residency.takeLoaded().map(\.model)), ["a", "b", "c"])
        XCTAssertTrue(residency.takeLoaded().isEmpty)
    }

    func testNoWarmUpWhileLocked() {
        let residency = OllamaResidency()
        residency.setLocked(true)
        XCTAssertFalse(residency.claimWarmUp(baseURL: url, model: "m"))
        residency.setLocked(false)
        XCTAssertTrue(residency.claimWarmUp(baseURL: url, model: "m"))
    }

    func testWarmUpIsDebouncedAndSkippedWhileARequestRuns() {
        let residency = OllamaResidency()
        let t0 = Date()
        XCTAssertTrue(residency.claimWarmUp(baseURL: url, model: "m", now: t0))
        residency.warmed(baseURL: url, model: "m", now: t0)
        XCTAssertFalse(residency.claimWarmUp(baseURL: url, model: "m", now: t0.addingTimeInterval(60)))
        XCTAssertTrue(residency.claimWarmUp(
            baseURL: url, model: "m", now: t0.addingTimeInterval(OllamaResidency.warmInterval + 1)))
        residency.began(baseURL: url, model: "m", now: t0)
        XCTAssertFalse(residency.claimWarmUp(baseURL: url, model: "m", now: t0.addingTimeInterval(3600)))
        residency.ended(now: t0)
        XCTAssertEqual(residency.takeLoaded().map(\.model), ["m"])
        XCTAssertTrue(residency.takeLoaded().isEmpty)
    }

    func testServiceTagsRequestsWithTheirTask() async throws {
        let fake = TaskRecordingAssistant()
        let service = AssistantService(assistant: fake, model: "m")
        _ = try await service.summarize(transcript: "t")
        _ = try await service.answerAboutPatient(context: "c", history: [], question: "q")
        XCTAssertEqual(fake.tasks, [.note, .chat])
    }
}
