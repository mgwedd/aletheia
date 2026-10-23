import AppKit
import Combine
import XCTest
@testable import Aletheia

final class AppLockCoverageTests: XCTestCase {
    func testLockedMenuNeverShowsPatientDataOrStartsAnotherRecording() {
        XCTAssertFalse(MenuBarContentPolicy.canStartRecording(isLocked: true, isStarting: false))
        XCTAssertFalse(MenuBarContentPolicy.canStartRecording(isLocked: false, isStarting: true))
        XCTAssertTrue(MenuBarContentPolicy.canStartRecording(isLocked: false, isStarting: false))
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
        XCTAssertTrue(source.contains("windowShield.start()"), "sheets, alerts and popovers need the app-wide shield")
        XCTAssertTrue(source.contains("appLock.observeBackgroundWork("), "a lock mid-recording must keep the key")
        let menu = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Views/RecordingMenuBar.swift"), encoding: .utf8)
        XCTAssertTrue(menu.contains("if appLock.isLocked"))
    }

    func testSheetsAlertsAndPopoversHideWhileLockedButFilePanelsDoNot() {
        XCTAssertTrue(WindowSharingPolicy.hidesWhileLocked(isSheet: true, isPopover: false, isFilePanel: false))
        XCTAssertTrue(WindowSharingPolicy.hidesWhileLocked(isSheet: false, isPopover: true, isFilePanel: false))
        XCTAssertFalse(WindowSharingPolicy.hidesWhileLocked(isSheet: true, isPopover: false, isFilePanel: true))
        XCTAssertFalse(WindowSharingPolicy.hidesWhileLocked(isSheet: false, isPopover: false, isFilePanel: false))
    }

    func testLockedInputToHiddenWindowsIsDropped() {
        typealias P = WindowSharingPolicy
        XCTAssertEqual(P.lockedEventAction(isLocked: false, windowIsHidden: true, attachedSheetIsHidden: true, isMouseDown: true), .pass)
        XCTAssertEqual(P.lockedEventAction(isLocked: true, windowIsHidden: true, attachedSheetIsHidden: false, isMouseDown: false), .drop)
        XCTAssertEqual(P.lockedEventAction(isLocked: true, windowIsHidden: false, attachedSheetIsHidden: true, isMouseDown: true), .dropAndUnlock)
        XCTAssertEqual(P.lockedEventAction(isLocked: true, windowIsHidden: false, attachedSheetIsHidden: true, isMouseDown: false), .pass)
        XCTAssertEqual(P.lockedEventAction(isLocked: true, windowIsHidden: false, attachedSheetIsHidden: false, isMouseDown: true), .pass)
    }

    private func lockSettings() -> (AppSettings, () -> Void) {
        let suite = "app-lock-coverage-\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        let settings = AppSettings(defaults: defaults)
        settings.appLockEnabled = true
        return (settings, { defaults.removePersistentDomain(forName: suite) })
    }

    @MainActor
    func testShieldHidesOverlayWindowsWhileLockedAndRestoresThemOnUnlock() {
        let (settings, cleanUp) = lockSettings()
        defer { cleanUp() }
        settings.hideFromScreenSharing = false
        let appLock = AppLock(settings: settings, canAuthenticate: { true })
        appLock.simulateUnlockedForTesting()
        let scene = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        let sheet = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        sheet.alphaValue = 0.9
        let shield = WindowShield(appLock: appLock, settings: settings, windows: { [scene, sheet] }, isOverlay: { $0 === sheet })

        shield.apply()
        XCTAssertEqual(scene.sharingType, .readOnly)
        XCTAssertEqual(sheet.sharingType, .readOnly)
        XCTAssertFalse(shield.isHidden(sheet))

        appLock.lockIfEnabled()
        shield.apply()
        XCTAssertEqual(scene.sharingType, .none)
        XCTAssertEqual(sheet.sharingType, .none)
        XCTAssertEqual(scene.alphaValue, 1)
        XCTAssertEqual(sheet.alphaValue, 0)
        XCTAssertTrue(shield.isHidden(sheet))
        XCTAssertFalse(shield.isHidden(scene))

        appLock.simulateUnlockedForTesting()
        shield.apply()
        XCTAssertEqual(sheet.alphaValue, 0.9, accuracy: 0.001)
        XCTAssertFalse(shield.isHidden(sheet))
        XCTAssertEqual(sheet.sharingType, .readOnly)
    }

    @MainActor
    func testShieldAppliesScreenSharingSettingToEveryWindow() {
        let (settings, cleanUp) = lockSettings()
        defer { cleanUp() }
        settings.hideFromScreenSharing = true
        let appLock = AppLock(settings: settings, canAuthenticate: { true })
        appLock.simulateUnlockedForTesting()
        let windows = (0..<3).map { _ in NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true) }
        let shield = WindowShield(appLock: appLock, settings: settings, windows: { windows }, isOverlay: { _ in false })

        shield.apply()
        XCTAssertEqual(windows.map(\.sharingType), [.none, .none, .none])
        settings.allowScreenSharingThisSession = true
        shield.apply()
        XCTAssertEqual(windows.map(\.sharingType), [.readOnly, .readOnly, .readOnly])
    }

    @MainActor
    func testLockKeepsTheKeyUntilBackgroundWorkEnds() async {
        let (settings, cleanUp) = lockSettings()
        defer { cleanUp() }
        let appLock = AppLock(settings: settings, canAuthenticate: { true })
        appLock.simulateUnlockedForTesting()
        var keyDrops = 0
        appLock.onLock = { keyDrops += 1 }
        var busy = true
        let changes = PassthroughSubject<Void, Never>()
        appLock.observeBackgroundWork(busy: { busy }, changes: changes.eraseToAnyPublisher())

        appLock.lockIfEnabled()
        XCTAssertTrue(appLock.isLocked)
        XCTAssertEqual(keyDrops, 0, "a recording still writing keeps its key")
        XCTAssertTrue(appLock.keyDropPending)

        changes.send()
        await drainMainQueue()
        XCTAssertEqual(keyDrops, 0, "still busy")

        busy = false
        changes.send()
        await drainMainQueue()
        XCTAssertEqual(keyDrops, 1, "the key drops once the work ends")
        XCTAssertFalse(appLock.keyDropPending)

        changes.send()
        await drainMainQueue()
        XCTAssertEqual(keyDrops, 1, "dropped once")
    }

    @MainActor
    func testUnlockBeforeBackgroundWorkEndsCancelsThePendingKeyDrop() async {
        let (settings, cleanUp) = lockSettings()
        defer { cleanUp() }
        let appLock = AppLock(settings: settings, canAuthenticate: { true })
        appLock.simulateUnlockedForTesting()
        var keyDrops = 0
        appLock.onLock = { keyDrops += 1 }
        var busy = true
        let changes = PassthroughSubject<Void, Never>()
        appLock.observeBackgroundWork(busy: { busy }, changes: changes.eraseToAnyPublisher())

        appLock.lockIfEnabled()
        appLock.simulateUnlockedForTesting()
        busy = false
        changes.send()
        await drainMainQueue()
        XCTAssertEqual(keyDrops, 0)
        XCTAssertFalse(appLock.keyDropPending)
    }

    @MainActor
    func testLockWithNoBackgroundWorkDropsTheKeyAtOnce() {
        let (settings, cleanUp) = lockSettings()
        defer { cleanUp() }
        let appLock = AppLock(settings: settings, canAuthenticate: { true })
        appLock.simulateUnlockedForTesting()
        var keyDrops = 0
        appLock.onLock = { keyDrops += 1 }
        appLock.lockIfEnabled()
        XCTAssertEqual(keyDrops, 1)
        appLock.lockIfEnabled()
        XCTAssertEqual(keyDrops, 1, "already locked")
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}
