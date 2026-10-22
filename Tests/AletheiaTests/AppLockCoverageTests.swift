import AppKit
import XCTest
@testable import Aletheia

final class AppLockCoverageTests: XCTestCase {
    func testLockedMenuNeverShowsPatientDataOrStartsAnotherRecording() {
        XCTAssertFalse(MenuBarContentPolicy.showsPatientNames(isLocked: true))
        XCTAssertFalse(MenuBarContentPolicy.showsLevels(isLocked: true))
        XCTAssertFalse(MenuBarContentPolicy.canStartRecording(isLocked: true, isStarting: false))
        XCTAssertTrue(MenuBarContentPolicy.keepsRecording(isLocked: true, isRecording: true))
    }

    func testWindowSharingPolicy() {
        XCTAssertEqual(WindowSharingPolicy.sharingType(isLocked: true, hideFromScreenSharing: false, sessionException: true), .none)
        XCTAssertEqual(WindowSharingPolicy.sharingType(isLocked: false, hideFromScreenSharing: true, sessionException: false), .none)
        XCTAssertEqual(WindowSharingPolicy.sharingType(isLocked: false, hideFromScreenSharing: true, sessionException: true), .readOnly)
        XCTAssertEqual(WindowSharingPolicy.sharingType(isLocked: false, hideFromScreenSharing: false, sessionException: false), .readOnly)
    }

    func testEverySceneHasLockCoverOrLockedMenu() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/AletheiaApp.swift"), encoding: .utf8)
        for scene in ["WindowGroup(id: MainWindow.id)", "WindowGroup(\"Ask About This Patient\"", "Window(\"Aletheia Doctor\"", "Window(\"Keyboard Shortcuts\"", "Settings {"] {
            guard let range = source.range(of: scene) else { return XCTFail("Missing scene: \(scene)") }
            let sceneBody = source[range.lowerBound...].prefix(4000)
            XCTAssertTrue(sceneBody.contains(".modifier(LockCover("), "Uncovered scene: \(scene)")
        }
        XCTAssertTrue(source.contains(".environmentObject(appLock)"))
        let menu = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Views/RecordingMenuBar.swift"), encoding: .utf8)
        XCTAssertTrue(menu.contains("if appLock.isLocked"))
    }
}
