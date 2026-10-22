import XCTest
@testable import Aletheia

final class AIEngineProblemTests: XCTestCase {
    func testUnrelatedErrorsAreNotEngineProblems() {
        XCTAssertNil(AIEngineProblem.from(error: URLError(.badURL)))
    }

    func testTheUnavailableBuiltInEngineOffersRetryWithItsMessage() {
        let problem = AIEngineProblem.from(error: BuiltInModelUnavailableError.unavailable)
        XCTAssertEqual(problem, .erroring(BuiltInModelUnavailableError.unavailable.localizedDescription))
        XCTAssertEqual(problem?.action, .retry)
    }

    func testEveryProblemHasTitleMessageAndAction() {
        let all: [AIEngineProblem] = [
            .erroring("x"),
            .builtInModelMissing,
            .builtInModelCorrupt,
        ]
        for problem in all {
            XCTAssertFalse(problem.title.isEmpty)
            XCTAssertFalse(problem.message.isEmpty)
            XCTAssertFalse(problem.actionTitle.isEmpty)
        }
    }

    // MARK: - Copy Details

    func testIncidentCarriesTheUnderlyingError() throws {
        let incident = try XCTUnwrap(AIEngineIncident.from(error: LocalLLMEngineError.loadFailed("bad gguf")))
        XCTAssertEqual(incident.problem, .builtInModelCorrupt)
        XCTAssertTrue(incident.technical.contains("loadFailed"))
        XCTAssertTrue(incident.technical.contains("bad gguf"))
    }

    func testIncidentIsNilForUnrelatedErrors() {
        XCTAssertNil(AIEngineIncident.from(error: URLError(.badURL)))
    }

    func testSupportReportListsTheFactsSupportNeeds() throws {
        let incident = try XCTUnwrap(AIEngineIncident.from(error: LocalLLMEngineError.modelNotDownloaded))
        let text = AIEngineSupportReport.text(
            incident: incident, appVersion: "2.35.0", macOS: "Version 14.5", backend: "Built-in model", model: "Qwen"
        )
        for expected in ["Problem: The AI model isn't downloaded", "modelNotDownloaded", "Backend: Built-in model", "Model: Qwen", "App version: 2.35.0", "macOS: Version 14.5"] {
            XCTAssertTrue(text.contains(expected), "missing \(expected)")
        }
    }

    func testSupportReportHasOnlyTheEightExpectedLines() throws {
        // Guards against adding free-form content (questions, transcripts, names).
        let incident = AIEngineIncident(problem: .builtInModelMissing, technical: "modelNotDownloaded")
        let text = AIEngineSupportReport.text(incident: incident, appVersion: "1", macOS: "m", backend: "b", model: "x")
        XCTAssertEqual(text.split(separator: "\n").count, 8)
    }

    // MARK: - Recovery routing

    private final class ActionLog {
        var calls: [String] = []
        var failure: Error?
        lazy var actions = AIEngineActions(
            downloadBuiltInModel: { [unowned self] onProgress in
                self.calls.append("builtIn")
                onProgress(0.5, "halfway")
                if let error = self.failure { throw error }
            }
        )
    }

    private struct Boom: LocalizedError {
        var errorDescription: String? { "boom" }
    }

    @MainActor
    func testBuiltInModelMissingAndCorruptRouteToTheBuiltInDownload() async throws {
        let log = ActionLog()
        try await AIEngineRecovery.perform(.builtInModelMissing, actions: log.actions)
        try await AIEngineRecovery.perform(.builtInModelCorrupt, actions: log.actions)
        XCTAssertEqual(log.calls, ["builtIn", "builtIn"])
        XCTAssertEqual(AIEngineRecoveryController.startingStatus(for: .builtInModelCorrupt), "Downloading the AI model…")
    }

    func testRetryDoesNothingButRetry() async throws {
        let log = ActionLog()
        try await AIEngineRecovery.perform(.erroring("x"), actions: log.actions)
        XCTAssertEqual(log.calls, [])
    }

    func testDownloadForwardsProgress() async throws {
        let log = ActionLog()
        var seen: [(Double, String)] = []
        try await AIEngineRecovery.perform(.builtInModelMissing, actions: log.actions) { seen.append(($0, $1)) }
        XCTAssertEqual(seen.count, 1)
        XCTAssertEqual(seen.first?.0, 0.5)
        XCTAssertEqual(seen.first?.1, "halfway")
    }

    func testFailureFromAnActionPropagates() async {
        let log = ActionLog()
        log.failure = Boom()
        do {
            try await AIEngineRecovery.perform(.builtInModelMissing, actions: log.actions)
            XCTFail("expected a throw")
        } catch {
            XCTAssertEqual(error.localizedDescription, "boom")
        }
    }

    // MARK: - Recovery controller

    @MainActor
    func testControllerReportsSuccessAndClearsWorking() async {
        let controller = AIEngineRecoveryController()
        let ok = await controller.run(.erroring("x")) { _, _ in }
        XCTAssertTrue(ok)
        XCTAssertFalse(controller.isWorking)
        XCTAssertNil(controller.failure)
    }

    @MainActor
    func testControllerCapturesFailureMessage() async {
        let controller = AIEngineRecoveryController()
        let ok = await controller.run(.erroring("x")) { _, _ in throw Boom() }
        XCTAssertFalse(ok)
        XCTAssertFalse(controller.isWorking)
        XCTAssertEqual(controller.failure, "boom")
    }

    @MainActor
    func testControllerShowsStatusAndZeroProgressForADownloadWhileItRuns() async {
        let controller = AIEngineRecoveryController()
        var duringStatus = ""
        var duringProgress: Double?
        var duringWorking = false
        _ = await controller.run(.builtInModelMissing) { _, _ in
            duringStatus = controller.status
            duringProgress = controller.progress
            duringWorking = controller.isWorking
        }
        XCTAssertTrue(duringWorking)
        XCTAssertEqual(duringStatus, "Downloading the AI model…")
        XCTAssertEqual(duringProgress, 0)
    }

    @MainActor
    func testControllerHasNoProgressBarWhenRetrying() async {
        let controller = AIEngineRecoveryController()
        var duringProgress: Double? = 1
        _ = await controller.run(.erroring("x")) { _, _ in duringProgress = controller.progress }
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
        _ = await controller.run(.erroring("x")) { _, _ in
            secondResult = await controller.run(.erroring("x")) { _, _ in XCTFail("must not run") }
        }
        XCTAssertEqual(secondResult, false)
    }

    @MainActor
    func testControllerClearsAnOldFailureOnTheNextRun() async {
        let controller = AIEngineRecoveryController()
        _ = await controller.run(.erroring("x")) { _, _ in throw Boom() }
        XCTAssertNotNil(controller.failure)
        _ = await controller.run(.erroring("x")) { _, _ in }
        XCTAssertNil(controller.failure)
    }

    // MARK: - Health probe (the banner)

    func testMissingBuiltInModelErrorBecomesADownloadThatRetries() {
        let problem = AIEngineProblem.from(error: LocalLLMEngineError.modelNotDownloaded)
        XCTAssertEqual(problem, .builtInModelMissing)
        XCTAssertEqual(problem?.action, .downloadBuiltInModel)
        XCTAssertEqual(problem?.actionTitle, "Download Model")
        XCTAssertEqual(problem?.retriesAfterAction, true)
    }

    func testCorruptBuiltInModelOffersRedownloadAndRetries() {
        let problem = AIEngineProblem.from(error: LocalLLMEngineError.loadFailed("bad gguf"))
        XCTAssertEqual(problem, .builtInModelCorrupt)
        XCTAssertEqual(problem?.action, .downloadBuiltInModel)
        XCTAssertEqual(problem?.actionTitle, "Re-download Model")
        XCTAssertEqual(problem?.retriesAfterAction, true)
    }

    func testBuiltInOutOfMemoryAndGenerationFailuresOfferRetry() {
        let oom = AIEngineProblem.from(error: LocalLLMEngineError.outOfMemory)
        XCTAssertEqual(oom, .erroring(LocalLLMEngineError.outOfMemory.localizedDescription))
        XCTAssertEqual(oom?.action, .retry)
        XCTAssertEqual(oom?.actionTitle, "Try Again")
        XCTAssertEqual(oom?.retriesAfterAction, true)

        let gen = AIEngineProblem.from(error: LocalLLMEngineError.generationFailed("decode failed"))
        XCTAssertEqual(gen, .erroring("decode failed"))
        XCTAssertEqual(gen?.action, .retry)

        XCTAssertNil(AIEngineProblem.from(error: LocalLLMEngineError.unavailable("not built")))
    }

    func testProbeOnBuiltInEngineReportsOnlyAMissingModel() {
        func builtIn(present: Bool) -> AIEngineProbe {
            AIEngineProbe(isBuiltInBackend: true, builtInModelPresent: { present })
        }
        XCTAssertEqual(builtIn(present: false).problem(), .builtInModelMissing)
        XCTAssertNil(builtIn(present: true).problem())
    }

    func testProbeIsQuietWhenTheBuiltInEngineIsNotInUse() {
        let probe = AIEngineProbe(isBuiltInBackend: false, builtInModelPresent: { false })
        XCTAssertNil(probe.problem())
    }

    // MARK: - Retry once

    func testPendingRetriesAreTakenOnce() {
        var retries = PendingRetries<EngineRetryKind, String>()
        XCTAssertTrue(retries.takeAll().isEmpty)
        retries.set("question", for: .chat)
        XCTAssertEqual(retries.takeAll(), ["question"])
        XCTAssertTrue(retries.takeAll().isEmpty, "a second take must not re-run the request")
        XCTAssertTrue(retries.isEmpty)
    }

    func testARepeatFailureOfTheSameKindReplacesTheEarlierRequest() {
        var retries = PendingRetries<EngineRetryKind, Int>()
        retries.set(1, for: .chat)
        retries.set(2, for: .chat)
        XCTAssertEqual(retries.takeAll(), [2])
    }

    func testANoteAndAChatThatBothFailedAreBothKept() {
        var retries = PendingRetries<EngineRetryKind, String>()
        retries.set("note", for: .note)
        retries.set("chat", for: .chat)
        retries.set("note again", for: .note)
        XCTAssertEqual(retries.takeAll(), ["note again", "chat"],
                       "the chat failing second must not overwrite the note's retry; order is first-requested")
    }

    func testClearDropsEverythingSoACancelledAlertCannotRunLater() {
        var retries = PendingRetries<EngineRetryKind, String>()
        retries.set("note", for: .note)
        retries.set("chat", for: .chat)
        retries.clear()
        XCTAssertTrue(retries.isEmpty)
        XCTAssertTrue(retries.takeAll().isEmpty)
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

    // MARK: - Where Copy Details is offered

    private func alertSource() throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Views/AIEngineProblemAlert.swift")
        return try String(contentsOf: file, encoding: .utf8)
    }

    /// The banner comes from a passive health check, so its only "technical"
    /// detail would be the problem's own name: nothing for support to learn.
    func testBannerDoesNotOfferCopyDetails() throws {
        let source = try alertSource()
        let start = try XCTUnwrap(source.range(of: "struct AIEngineBanner: View"))
        let end = try XCTUnwrap(source.range(of: "enum AIEngineHealth"))
        XCTAssertFalse(source[start.lowerBound..<end.lowerBound].contains("Button(\"Copy Details\")"))
    }

    /// The alert for a real failed request carries the underlying error, so it keeps the button.
    func testRequestAlertKeepsCopyDetails() throws {
        let source = try alertSource()
        let start = try XCTUnwrap(source.range(of: "private struct AIEngineAlert"))
        let end = try XCTUnwrap(source.range(of: "struct AIEngineBanner: View"))
        XCTAssertTrue(source[start.lowerBound..<end.lowerBound].contains("Button(\"Copy Details\")"))
    }
}
