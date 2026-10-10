import XCTest
@testable import Aletheia

final class AIEngineProblemTests: XCTestCase {
    func testUnreachableAndNotInstalledOffersGetOllama() {
        let problem = AIEngineProblem.from(error: OllamaError.notReachable, ollamaInstalled: false)
        XCTAssertEqual(problem, .notInstalled)
        XCTAssertEqual(problem?.action, .getOllama)
        XCTAssertEqual(problem?.actionTitle, "Get Ollama")
        XCTAssertEqual(problem?.retriesAfterAction, false)
    }

    func testUnreachableButInstalledOffersStart() {
        let problem = AIEngineProblem.from(error: OllamaError.notReachable, ollamaInstalled: true)
        XCTAssertEqual(problem, .notRunning)
        XCTAssertEqual(problem?.action, .startOllama)
        XCTAssertEqual(problem?.retriesAfterAction, true)
    }

    func testMissingModelOffersDownloadOfThatModel() {
        let problem = AIEngineProblem.from(error: OllamaError.modelNotFound("qwen2.5:7b"), ollamaInstalled: true)
        XCTAssertEqual(problem, .modelMissing("qwen2.5:7b"))
        XCTAssertEqual(problem?.action, .downloadModel("qwen2.5:7b"))
        XCTAssertTrue(problem?.message.contains("qwen2.5:7b") ?? false)
    }

    func testServerErrorOffersRetry() {
        let problem = AIEngineProblem.from(error: OllamaError.badResponse, ollamaInstalled: true)
        XCTAssertEqual(problem?.action, .retry)
        XCTAssertEqual(problem?.actionTitle, "Try Again")
    }

    func testUnrelatedErrorsAreNotEngineProblems() {
        XCTAssertNil(AIEngineProblem.from(error: URLError(.badURL), ollamaInstalled: true))
    }

    func testEveryProblemHasTitleMessageAndAction() {
        let all: [AIEngineProblem] = [.notInstalled, .notRunning, .modelMissing("m"), .erroring("x")]
        for problem in all {
            XCTAssertFalse(problem.title.isEmpty)
            XCTAssertFalse(problem.message.isEmpty)
            XCTAssertFalse(problem.actionTitle.isEmpty)
        }
    }
}
