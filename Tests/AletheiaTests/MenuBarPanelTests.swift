import XCTest
@testable import Aletheia

final class MenuBarPanelTests: XCTestCase {
    func testIconFollowsRecordingState() {
        XCTAssertEqual(MenuBarPanel.iconSymbol(isRecording: false, isPaused: false), "waveform")
        XCTAssertEqual(MenuBarPanel.iconSymbol(isRecording: true, isPaused: false), "record.circle.fill")
        XCTAssertEqual(MenuBarPanel.iconSymbol(isRecording: true, isPaused: true), "pause.circle.fill")
    }

    func testStateOrder() {
        XCTAssertEqual(MenuBarPanel.state(isLocked: true, isRecording: true, isPaused: false), .locked)
        XCTAssertEqual(MenuBarPanel.state(isLocked: false, isRecording: false, isPaused: false), .idle)
        XCTAssertEqual(MenuBarPanel.state(isLocked: false, isRecording: true, isPaused: false), .recording)
        XCTAssertEqual(MenuBarPanel.state(isLocked: false, isRecording: true, isPaused: true), .paused)
    }

    func testIdleOffersPickerAndStart() {
        let content = MenuBarPanel.content(.idle, hasPatients: true)
        XCTAssertEqual(content.status, "Not recording")
        XCTAssertEqual(content.controls, ["Patient", "Start recording"])
    }

    func testLockedShowsOnlyUnlock() {
        let content = MenuBarPanel.content(.locked, hasPatients: true)
        XCTAssertEqual(content.status, "Aletheia is locked")
        XCTAssertEqual(content.controls, ["Unlock"])
        XCTAssertFalse(content.showsSessionDetail)
    }

    func testNoPatientsOffersNoControls() {
        XCTAssertEqual(MenuBarPanel.content(.idle, hasPatients: false).controls, [])
    }
}
