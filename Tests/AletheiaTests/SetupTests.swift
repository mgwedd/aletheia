import XCTest
@testable import Aletheia

final class SetupTests: XCTestCase {
    private func check(_ kind: ToolHealthCheck.Kind, _ status: ToolHealthCheck.Status) -> ToolHealthCheck {
        ToolHealthCheck(kind: kind, title: "\(kind)", status: status, detail: "")
    }

    func testOkChecksHaveNoAction() {
        for kind in [ToolHealthCheck.Kind.dataFolder, .microphone, .screenRecording, .whisperModel, .ollama, .appleIntelligence, .calendar, .reminders] {
            XCTAssertNil(Setup.action(for: check(kind, .ok)))
        }
    }

    func testActionMapping() {
        XCTAssertEqual(Setup.action(for: check(.dataFolder, .failed)), .chooseFolder)
        XCTAssertEqual(Setup.action(for: check(.microphone, .warning)), .requestMicrophone)
        XCTAssertEqual(Setup.action(for: check(.microphone, .failed)), .openMicrophoneSettings)
        XCTAssertEqual(Setup.action(for: check(.screenRecording, .failed)), .requestScreenRecording)
        XCTAssertEqual(Setup.action(for: check(.whisperModel, .failed)), .downloadTranscriptionModel)
        // No engine-state detail (older/other caller, or a plain fixture like
        // `check(...)` here) falls back to the pre-#111 "install" action rather
        // than guessing Ollama is already there.
        XCTAssertEqual(Setup.action(for: check(.ollama, .failed)), .installOrOpenOllama)
        XCTAssertEqual(Setup.action(for: check(.ollama, .warning)), .downloadOllamaModel)
        XCTAssertEqual(Setup.action(for: check(.appleIntelligence, .failed)), .enableAppleIntelligence)
        XCTAssertNil(Setup.action(for: check(.appleIntelligence, .warning)))
        XCTAssertEqual(Setup.action(for: check(.calendar, .warning)), .requestCalendarAccess)
        XCTAssertEqual(Setup.action(for: check(.reminders, .warning)), .requestRemindersAccess)
    }

    // MARK: #111 — launch vs. install, driven by `ollamaState`

    // `ToolHealth` is main-actor isolated, so these build their checks there.
    @MainActor
    func testOllamaFailedWithInstalledNotRunningOffersLaunch() {
        let installedNotRunning = ToolHealth.classifyOllama(reachable: false, hasModel: false, modelName: "llama3.1:8b", installed: true)
        XCTAssertEqual(Setup.action(for: installedNotRunning), .launchOllama)
    }

    @MainActor
    func testOllamaFailedWithNotInstalledOffersDownloadPage() {
        let notInstalled = ToolHealth.classifyOllama(reachable: false, hasModel: false, modelName: "llama3.1:8b", installed: false)
        XCTAssertEqual(Setup.action(for: notInstalled), .installOrOpenOllama)
    }

    func testIsReadyIgnoresWarningsButNotFailures() {
        let allOk = [check(.dataFolder, .ok), check(.microphone, .ok), check(.ollama, .ok)]
        XCTAssertTrue(Setup.isReady(allOk))

        let withWarning = [check(.dataFolder, .ok), check(.microphone, .warning), check(.ollama, .warning)]
        XCTAssertTrue(Setup.isReady(withWarning), "warnings shouldn't block finishing setup")

        let withFailure = [check(.dataFolder, .failed), check(.microphone, .ok)]
        XCTAssertFalse(Setup.isReady(withFailure))
    }

    func testItemsPreserveOrderAndActions() {
        let checks = [check(.dataFolder, .failed), check(.microphone, .ok), check(.ollama, .warning)]
        let items = Setup.items(from: checks)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].action, .chooseFolder)
        XCTAssertNil(items[1].action)
        XCTAssertEqual(items[2].action, .downloadOllamaModel)
    }

    func testProgressCountsDoneRowsAndHighlightsTheFirstActionableOne() {
        let items = Setup.items(from: [
            check(.dataFolder, .ok),
            check(.appleIntelligence, .warning),   // nothing to click
            check(.microphone, .warning),
            check(.ollama, .failed),
        ])
        let progress = Setup.progress(items)
        XCTAssertEqual(progress.done, 1)
        XCTAssertEqual(progress.total, 4)
        XCTAssertEqual(progress.currentID, items[2].id)
        XCTAssertEqual(progress.fraction, 0.25, accuracy: 0.0001)
    }

    func testProgressWhenEverythingIsDoneOrEmpty() {
        let done = Setup.progress(Setup.items(from: [check(.dataFolder, .ok), check(.microphone, .ok)]))
        XCTAssertEqual(done.done, 2)
        XCTAssertNil(done.currentID)
        XCTAssertEqual(done.fraction, 1, accuracy: 0.0001)

        let empty = Setup.progress([])
        XCTAssertEqual(empty.total, 0)
        XCTAssertEqual(empty.fraction, 0)
    }

    // A periodic refresh rebuilds every row from scratch. Rows must keep their
    // identity and compare equal, or SwiftUI rebuilds the list (visible jitter)
    // and the "skip unchanged results" check never skips.
    func testRefreshingUnchangedChecksKeepsIdentityAndEquality() {
        let first = Setup.items(from: [check(.dataFolder, .ok), check(.microphone, .warning), check(.ollama, .failed)])
        let second = Setup.items(from: [check(.dataFolder, .ok), check(.microphone, .warning), check(.ollama, .failed)])
        XCTAssertEqual(first.map(\.id), second.map(\.id))
        XCTAssertEqual(first.map(\.check), second.map(\.check))
        XCTAssertEqual(Setup.progress(first).currentID, Setup.progress(second).currentID)
    }

    func testAChangedStatusIsDetectedAsDifferent() {
        let before = Setup.items(from: [check(.microphone, .warning)])
        let after = Setup.items(from: [check(.microphone, .ok)])
        XCTAssertEqual(before.map(\.id), after.map(\.id))
        XCTAssertNotEqual(before.map(\.check), after.map(\.check))
    }
}
