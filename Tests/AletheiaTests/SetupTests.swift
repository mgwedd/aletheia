import XCTest
@testable import Aletheia

final class SetupTests: XCTestCase {
    private func check(_ kind: ToolHealthCheck.Kind, _ status: ToolHealthCheck.Status) -> ToolHealthCheck {
        ToolHealthCheck(kind: kind, title: "\(kind)", status: status, detail: "")
    }

    func testOkChecksHaveNoAction() {
        for kind in [ToolHealthCheck.Kind.dataFolder, .microphone, .screenRecording, .whisperModel, .builtInModel, .appleIntelligence, .calendar, .reminders, .termsAndPrivacy] {
            XCTAssertNil(Setup.action(for: check(kind, .ok)))
        }
    }

    func testActionMapping() {
        XCTAssertEqual(Setup.action(for: check(.dataFolder, .failed)), .chooseFolder)
        XCTAssertEqual(Setup.action(for: check(.microphone, .warning)), .requestMicrophone)
        XCTAssertEqual(Setup.action(for: check(.microphone, .failed)), .openMicrophoneSettings)
        XCTAssertEqual(Setup.action(for: check(.screenRecording, .failed)), .requestScreenRecording)
        XCTAssertEqual(Setup.action(for: check(.whisperModel, .failed)), .downloadTranscriptionModel)
        XCTAssertEqual(Setup.action(for: check(.builtInModel, .failed)), .downloadBuiltInModel)
        XCTAssertEqual(Setup.action(for: check(.appleIntelligence, .failed)), .enableAppleIntelligence)
        XCTAssertNil(Setup.action(for: check(.appleIntelligence, .warning)))
        XCTAssertEqual(Setup.action(for: check(.calendar, .warning)), .requestCalendarAccess)
        XCTAssertEqual(Setup.action(for: check(.reminders, .warning)), .requestRemindersAccess)
        XCTAssertEqual(Setup.action(for: check(.termsAndPrivacy, .warning)), .reviewTerms)
    }

    /// A missing built-in model blocks setup and offers the in-app download.
    @MainActor
    func testBuiltInModelCheck() {
        let missing = ToolHealth.classifyBuiltInModel(installed: false, modelName: "Llama 3.1 8B", sizeMB: 6036)
        XCTAssertEqual(missing.status, .failed)
        XCTAssertFalse(Setup.isReady([missing]))
        XCTAssertEqual(Setup.action(for: missing), .downloadBuiltInModel)
        let ready = ToolHealth.classifyBuiltInModel(installed: true, modelName: "Llama 3.1 8B", sizeMB: 6036)
        XCTAssertEqual(ready.status, .ok)
        XCTAssertNil(Setup.action(for: ready))
    }

    func testIsReadyIgnoresWarningsButNotFailures() {
        let allOk = [check(.dataFolder, .ok), check(.microphone, .ok), check(.builtInModel, .ok)]
        XCTAssertTrue(Setup.isReady(allOk))

        let withWarning = [check(.dataFolder, .ok), check(.microphone, .warning), check(.builtInModel, .warning)]
        XCTAssertTrue(Setup.isReady(withWarning), "warnings shouldn't block finishing setup")

        let withFailure = [check(.dataFolder, .failed), check(.microphone, .ok)]
        XCTAssertFalse(Setup.isReady(withFailure))
    }

    func testItemsPreserveOrderAndActions() {
        let checks = [check(.dataFolder, .failed), check(.microphone, .ok), check(.builtInModel, .warning)]
        let items = Setup.items(from: checks)
        XCTAssertEqual(items.count, 3)
        XCTAssertEqual(items[0].action, .chooseFolder)
        XCTAssertNil(items[1].action)
        XCTAssertEqual(items[2].action, .downloadBuiltInModel)
    }

    func testProgressCountsDoneRowsAndHighlightsTheFirstActionableOne() {
        let items = Setup.items(from: [
            check(.dataFolder, .ok),
            check(.appleIntelligence, .warning),   // nothing to click
            check(.microphone, .warning),
            check(.builtInModel, .failed),
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
}
