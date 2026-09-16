import XCTest
@testable import SessionNotes

final class SetupTests: XCTestCase {
    private func check(_ kind: ToolHealthCheck.Kind, _ status: ToolHealthCheck.Status) -> ToolHealthCheck {
        ToolHealthCheck(kind: kind, title: "\(kind)", status: status, detail: "")
    }

    func testOkChecksHaveNoAction() {
        for kind in [ToolHealthCheck.Kind.dataFolder, .microphone, .screenRecording, .whisperModel, .ollama] {
            XCTAssertNil(Setup.action(for: check(kind, .ok)))
        }
    }

    func testActionMapping() {
        XCTAssertEqual(Setup.action(for: check(.dataFolder, .failed)), .chooseFolder)
        XCTAssertEqual(Setup.action(for: check(.microphone, .warning)), .requestMicrophone)
        XCTAssertEqual(Setup.action(for: check(.microphone, .failed)), .openMicrophoneSettings)
        XCTAssertEqual(Setup.action(for: check(.screenRecording, .failed)), .openScreenRecordingSettings)
        XCTAssertEqual(Setup.action(for: check(.whisperModel, .failed)), .downloadTranscriptionModel)
        XCTAssertEqual(Setup.action(for: check(.ollama, .failed)), .installOrOpenOllama)
        XCTAssertEqual(Setup.action(for: check(.ollama, .warning)), .downloadOllamaModel)
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
}
