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

    // MARK: - Recovery routing

    private final class ActionLog {
        var calls: [String] = []
        var failure: Error?
        lazy var actions = AIEngineActions(
            openDownloadPage: { [unowned self] in self.calls.append("open") },
            startOllama: { [unowned self] in
                self.calls.append("start")
                if let error = self.failure { throw error }
            },
            pullModel: { [unowned self] name, onProgress in
                self.calls.append("pull:\(name)")
                onProgress(0.5, "halfway")
                if let error = self.failure { throw error }
            }
        )
    }

    func testEachProblemRoutesToItsOwnAction() async throws {
        let log = ActionLog()
        try await AIEngineRecovery.perform(.notInstalled, actions: log.actions)
        try await AIEngineRecovery.perform(.notRunning, actions: log.actions)
        try await AIEngineRecovery.perform(.modelMissing("qwen2.5:7b"), actions: log.actions)
        try await AIEngineRecovery.perform(.erroring("x"), actions: log.actions)
        XCTAssertEqual(log.calls, ["open", "start", "pull:qwen2.5:7b"])
    }

    func testDownloadForwardsProgress() async throws {
        let log = ActionLog()
        var seen: [(Double, String)] = []
        try await AIEngineRecovery.perform(.modelMissing("m"), actions: log.actions) { seen.append(($0, $1)) }
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.0, 0.5)
        XCTAssertEqual(seen.first?.1, "halfway")
    }

    func testFailureFromAnActionPropagates() async {
        let log = ActionLog()
        log.failure = OllamaLauncher.LaunchError.timedOut
        do {
            try await AIEngineRecovery.perform(.notRunning, actions: log.actions)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error as? OllamaLauncher.LaunchError, .timedOut)
        }
    }

    // MARK: - Recovery controller

    @MainActor
    func testControllerReportsSuccessAndClearsWorking() async {
        let controller = AIEngineRecoveryController()
        let ok = await controller.run(.notRunning) { _, _ in }
        XCTAssertTrue(ok)
        XCTAssertFalse(controller.isWorking)
        XCTAssertNil(controller.failure)
    }

    @MainActor
    func testControllerCapturesFailureMessage() async {
        let controller = AIEngineRecoveryController()
        let ok = await controller.run(.notRunning) { _, _ in throw OllamaLauncher.LaunchError.timedOut }
        XCTAssertFalse(ok)
        XCTAssertFalse(controller.isWorking)
        XCTAssertEqual(controller.failure, OllamaLauncher.LaunchError.timedOut.errorDescription)
    }

    @MainActor
    func testControllerShowsStatusAndZeroProgressForADownloadWhileItRuns() async {
        let controller = AIEngineRecoveryController()
        var duringStatus = ""
        var duringProgress: Double?
        var duringWorking = false
        _ = await controller.run(.modelMissing("qwen2.5:7b")) { _, _ in
            duringStatus = controller.status
            duringProgress = controller.progress
            duringWorking = controller.isWorking
        }
        XCTAssertTrue(duringWorking)
        XCTAssertEqual(duringStatus, "Downloading qwen2.5:7b…")
        XCTAssertEqual(duringProgress, 0)
    }

    @MainActor
    func testControllerHasNoProgressBarWhenStartingOllama() async {
        let controller = AIEngineRecoveryController()
        var duringProgress: Double? = 1
        _ = await controller.run(.notRunning) { _, _ in duringProgress = controller.progress }
        XCTAssertNil(duringProgress)
    }

    @MainActor
    func testControllerClampsAndStoresProgress() {
        let controller = AIEngineRecoveryController()
        controller.report(fraction: 1.7, text: "almost")
        XCTAssertEqual(controller.progress, 1)
        XCTAssertEqual(controller.status, "almost")
        controller.report(fraction: -1, text: "")
        XCTAssertEqual(controller.progress, 0)
        XCTAssertEqual(controller.status, "almost", "empty text keeps the previous status")
    }

    @MainActor
    func testControllerIgnoresASecondRunWhileOneIsActive() async {
        let controller = AIEngineRecoveryController()
        var secondResult: Bool?
        _ = await controller.run(.notRunning) { _, _ in
            secondResult = await controller.run(.notRunning) { _, _ in XCTFail("must not run") }
        }
        XCTAssertEqual(secondResult, false)
    }

    @MainActor
    func testControllerClearsAnOldFailureOnTheNextRun() async {
        let controller = AIEngineRecoveryController()
        _ = await controller.run(.notRunning) { _, _ in throw OllamaError.badResponse }
        XCTAssertNotNil(controller.failure)
        _ = await controller.run(.notRunning) { _, _ in }
        XCTAssertNil(controller.failure)
    }

    // MARK: - Health probe (the banner)

    private func probe(
        ollama: Bool = true, installed: Bool, reachable: Bool, hasModel: Bool = true
    ) -> AIEngineProbe {
        AIEngineProbe(
            isOllamaBackend: ollama, modelName: "m",
            isReachable: { reachable }, hasModel: { _ in hasModel }, isInstalled: { installed }
        )
    }

    func testProbeReportsNotInstalled() async {
        let problem = await probe(installed: false, reachable: false).problem()
        XCTAssertEqual(problem, .notInstalled)
    }

    func testProbeReportsInstalledButNotRunning() async {
        let problem = await probe(installed: true, reachable: false).problem()
        XCTAssertEqual(problem, .notRunning)
    }

    func testProbeReportsMissingModel() async {
        let problem = await probe(installed: true, reachable: true, hasModel: false).problem()
        XCTAssertEqual(problem, .modelMissing("m"))
    }

    func testProbeIsQuietWhenReady() async {
        let problem = await probe(installed: true, reachable: true).problem()
        XCTAssertNil(problem)
    }

    func testRunningOllamaCountsAsInstalledEvenIfTheAppIsNotFound() async {
        // e.g. started from the command line or Homebrew.
        let problem = await probe(installed: false, reachable: true).problem()
        XCTAssertNil(problem)
    }

    func testProbeIsQuietForOtherBackends() async {
        let problem = await probe(ollama: false, installed: false, reachable: false).problem()
        XCTAssertNil(problem)
    }

    func testProbeDoesNotCheckTheModelWhenUnreachable() async {
        var asked = false
        let p = AIEngineProbe(
            isOllamaBackend: true, modelName: "m",
            isReachable: { false }, hasModel: { _ in asked = true; return true }, isInstalled: { true }
        )
        _ = await p.problem()
        XCTAssertFalse(asked)
    }

    // MARK: - Retry once

    func testPendingRetryIsTakenOnce() {
        var retry = PendingRetry<String>()
        XCTAssertNil(retry.take())
        retry.set("question")
        XCTAssertEqual(retry.take(), "question")
        XCTAssertNil(retry.take(), "a second take must not re-run the request")
    }

    func testPendingRetryKeepsOnlyTheLatest() {
        var retry = PendingRetry<Int>()
        retry.set(1)
        retry.set(2)
        XCTAssertEqual(retry.take(), 2)
    }

    // MARK: - Failed turn removal

    func testRemoveTurnDropsTheQuestionAndAnyPartialAnswer() {
        let earlier = ChatMessage(role: .assistant, text: "earlier")
        let question = ChatMessage(role: .user, text: "q")
        let partial = ChatMessage(role: .assistant, text: "par")
        var messages = [earlier, question, partial]
        messages.removeTurn(startingAt: question.id)
        XCTAssertEqual(messages, [earlier])
    }

    func testRemoveTurnLeavesMessagesAloneWhenTheIDIsUnknown() {
        let only = ChatMessage(role: .user, text: "q")
        var messages = [only]
        messages.removeTurn(startingAt: UUID())
        XCTAssertEqual(messages, [only])
    }
}
