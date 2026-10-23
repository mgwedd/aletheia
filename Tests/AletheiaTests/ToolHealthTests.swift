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
}

final class ScreenAccessProbeGateTests: XCTestCase {
    func testOneArmBuysExactlyOneProbe() {
        _ = ScreenAccessProbeGate.consume() // start from a known state
        XCTAssertFalse(ScreenAccessProbeGate.consume(), "no probe without a user action")
        ScreenAccessProbeGate.arm()
        XCTAssertTrue(ScreenAccessProbeGate.consume())
        XCTAssertFalse(ScreenAccessProbeGate.consume(), "the probe is spent until armed again")
    }

    func testCheckIdentityIsStableAcrossRuns() {
        let a = ToolHealthCheck(kind: .microphone, title: "Microphone access", status: .ok, detail: "x")
        let b = ToolHealthCheck(kind: .microphone, title: "Microphone access", status: .ok, detail: "x")
        XCTAssertEqual(a.id, b.id)
        XCTAssertEqual(a, b)
    }
}
