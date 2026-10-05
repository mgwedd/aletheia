import AVFoundation
import XCTest
@testable import Aletheia

/// Guards the status-mapping that the setup checklist and Settings status
/// section rely on: a granted permission must read as OK, and a status must
/// flip the moment the underlying grant changes (the "nothing updates" /
/// "doesn't read that perm is granted" regressions).
@MainActor
final class ToolHealthTests: XCTestCase {
    // MARK: Microphone

    func testMicrophoneAuthorizedIsOK() {
        XCTAssertEqual(ToolHealth.classifyMicrophone(.authorized).status, .ok)
    }

    func testMicrophoneDeniedAndRestrictedFail() {
        XCTAssertEqual(ToolHealth.classifyMicrophone(.denied).status, .failed)
        XCTAssertEqual(ToolHealth.classifyMicrophone(.restricted).status, .failed)
    }

    func testMicrophoneNotDeterminedIsWarning() {
        XCTAssertEqual(ToolHealth.classifyMicrophone(.notDetermined).status, .warning)
    }

    // MARK: Screen / call-audio capture

    func testScreenRecordingGrantedIsOK() {
        let check = ToolHealth.classifyScreenRecording(granted: true)
        XCTAssertEqual(check.status, .ok)
        XCTAssertEqual(check.kind, .screenRecording)
    }

    func testScreenRecordingDeniedFails() {
        XCTAssertEqual(ToolHealth.classifyScreenRecording(granted: false).status, .failed)
    }

    /// The core regression: after the user flips the toggle on and the app
    /// re-polls, the row must go from failed to OK.
    func testScreenRecordingFlipsAfterGrant() {
        XCTAssertEqual(ToolHealth.classifyScreenRecording(granted: false).status, .failed)
        XCTAssertEqual(ToolHealth.classifyScreenRecording(granted: true).status, .ok)
    }

    // MARK: Transcription model

    func testWhisperModelPresentIsOK() {
        XCTAssertEqual(ToolHealth.classifyWhisperModel(exists: true, modelDisplayName: "Small", sizeMB: 488).status, .ok)
    }

    func testWhisperModelMissingFailsAndNamesSize() {
        let check = ToolHealth.classifyWhisperModel(exists: false, modelDisplayName: "Small", sizeMB: 488)
        XCTAssertEqual(check.status, .failed)
        XCTAssertTrue(check.detail.contains("488"))
    }

    // MARK: Ollama / AI

    func testOllamaUnreachableFails() {
        let check = ToolHealth.classifyOllama(reachable: false, hasModel: false, modelName: "llama3.1:8b")
        XCTAssertEqual(check.status, .failed)
    }

    func testOllamaReachableWithoutModelIsWarning() {
        let check = ToolHealth.classifyOllama(reachable: true, hasModel: false, modelName: "llama3.1:8b")
        XCTAssertEqual(check.status, .warning)
    }

    func testOllamaReadyIsOK() {
        let check = ToolHealth.classifyOllama(reachable: true, hasModel: true, modelName: "llama3.1:8b")
        XCTAssertEqual(check.status, .ok)
        XCTAssertTrue(check.detail.contains("llama3.1:8b"))
    }

    // MARK: #111 — installed-but-not-running vs. never-installed

    /// The regression this fixes: unreachable used to always mean "go install
    /// it", even when Ollama was already on the Mac and had simply quit (e.g.
    /// after a reboot). Now the two are distinguished so the checklist can
    /// offer to launch it instead of reopening the download page forever.
    func testOllamaUnreachableAndInstalledOffersLaunchState() {
        let check = ToolHealth.classifyOllama(reachable: false, hasModel: false, modelName: "llama3.1:8b", installed: true)
        XCTAssertEqual(check.status, .failed)
        XCTAssertEqual(check.ollamaState, .installedNotRunning)
        XCTAssertTrue(check.detail.localizedCaseInsensitiveContains("launch"))
    }

    func testOllamaUnreachableAndNotInstalledOffersDownloadState() {
        let check = ToolHealth.classifyOllama(reachable: false, hasModel: false, modelName: "llama3.1:8b", installed: false)
        XCTAssertEqual(check.status, .failed)
        XCTAssertEqual(check.ollamaState, .notInstalled)
        XCTAssertTrue(check.detail.localizedCaseInsensitiveContains("install"))
    }

    func testOllamaReachableStatesCarryTheirEngineState() {
        XCTAssertEqual(
            ToolHealth.classifyOllama(reachable: true, hasModel: false, modelName: "llama3.1:8b").ollamaState,
            .modelMissing
        )
        XCTAssertEqual(
            ToolHealth.classifyOllama(reachable: true, hasModel: true, modelName: "llama3.1:8b").ollamaState,
            .ready
        )
    }
}
