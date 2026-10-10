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

    // MARK: - Health check mapping (the passive banner)

    func testHealthStatesMapToProblems() {
        XCTAssertEqual(AIEngineProblem.from(state: .notInstalled, modelName: "m"), .notInstalled)
        XCTAssertEqual(AIEngineProblem.from(state: .installedNotRunning, modelName: "m"), .notRunning)
        XCTAssertEqual(AIEngineProblem.from(state: .modelMissing, modelName: "qwen2.5:7b"), .modelMissing("qwen2.5:7b"))
    }

    func testHealthyOrSettlingStatesShowNoBanner() {
        XCTAssertNil(AIEngineProblem.from(state: .ready, modelName: "m"))
        XCTAssertNil(AIEngineProblem.from(state: .starting, modelName: "m"))
        XCTAssertNil(AIEngineProblem.from(state: .running, modelName: "m"))
    }

    func testBannerAgreesWithTheSetupChecklistClassification() {
        // Same inputs the banner feeds `OllamaEngineState.classify`.
        let notRunning = OllamaEngineState.classify(installed: true, isLaunching: false, reachable: false, hasModel: nil)
        XCTAssertEqual(AIEngineProblem.from(state: notRunning, modelName: "m"), .notRunning)
        let missing = OllamaEngineState.classify(installed: true, isLaunching: false, reachable: true, hasModel: false)
        XCTAssertEqual(AIEngineProblem.from(state: missing, modelName: "m"), .modelMissing("m"))
        let ready = OllamaEngineState.classify(installed: true, isLaunching: false, reachable: true, hasModel: true)
        XCTAssertNil(AIEngineProblem.from(state: ready, modelName: "m"))
    }

    // MARK: - Copy Details

    func testIncidentCarriesTheUnderlyingError() throws {
        let incident = try XCTUnwrap(AIEngineIncident.from(error: OllamaError.modelNotFound("qwen2.5:7b"), ollamaInstalled: true))
        XCTAssertEqual(incident.problem, .modelMissing("qwen2.5:7b"))
        XCTAssertTrue(incident.technical.contains("modelNotFound"))
        XCTAssertTrue(incident.technical.contains("qwen2.5:7b"))
    }

    func testIncidentIsNilForUnrelatedErrors() {
        XCTAssertNil(AIEngineIncident.from(error: URLError(.badURL), ollamaInstalled: true))
    }

    func testSupportReportListsTheFactsSupportNeeds() throws {
        let incident = try XCTUnwrap(AIEngineIncident.from(error: OllamaError.notReachable, ollamaInstalled: true))
        let text = AIEngineSupportReport.text(
            incident: incident, appVersion: "2.35.0", macOS: "Version 14.5", backend: "Ollama", model: "qwen2.5:7b"
        )
        for expected in ["Problem: The local AI engine isn't running", "notReachable", "Backend: Ollama", "Model: qwen2.5:7b", "App version: 2.35.0", "macOS: Version 14.5"] {
            XCTAssertTrue(text.contains(expected), "missing \(expected)")
        }
    }

    func testSupportReportHasOnlyTheEightExpectedLines() throws {
        // Guards against adding free-form content (questions, transcripts, names).
        let incident = AIEngineIncident(problem: .notRunning, technical: "notReachable")
        let text = AIEngineSupportReport.text(incident: incident, appVersion: "1", macOS: "m", backend: "b", model: "x")
        XCTAssertEqual(text.split(separator: "\n").count, 8)
    }
}
