import XCTest
@testable import Aletheia

final class AppLockPolicyTests: XCTestCase {
    func testLocksOnlyWhenEnabledAndAbleToAuthenticate() {
        XCTAssertTrue(AppLockPolicy.shouldLock(enabled: true, canAuthenticate: true))
        XCTAssertFalse(AppLockPolicy.shouldLock(enabled: false, canAuthenticate: true))
    }

    func testNeverLocksWhenTheMacCannotAuthenticate() {
        // A Mac with no Touch ID and no password must not be trapped out of its data.
        XCTAssertFalse(AppLockPolicy.shouldLock(enabled: true, canAuthenticate: false))
        XCTAssertFalse(AppLockPolicy.shouldLock(enabled: false, canAuthenticate: false))
    }

    func testPromptsOnlyWhenLockedAndAppIsActive() {
        XCTAssertTrue(AppLockPolicy.shouldPromptNow(isLocked: true, appIsActive: true))
        XCTAssertFalse(AppLockPolicy.shouldPromptNow(isLocked: true, appIsActive: false))
        XCTAssertFalse(AppLockPolicy.shouldPromptNow(isLocked: false, appIsActive: true))
    }

    func testMainWindowOpensOnlyWhenMissingOrClosed() {
        func open(_ exists: Bool, _ visible: Bool, _ mini: Bool, _ hidden: Bool = false) -> Bool {
            MainWindow.needsOpen(exists: exists, isVisible: visible, isMiniaturized: mini, appHidden: hidden)
        }
        XCTAssertTrue(open(false, false, false))
        XCTAssertTrue(open(true, false, false))          // closed
        XCTAssertFalse(open(true, true, false))          // on screen
        XCTAssertFalse(open(true, false, true))          // minimised
        XCTAssertFalse(open(true, false, false, true))   // app merely hidden
    }

    func testCancelThenActivationChurnDoesNotReprompt() {
        var gate = AutoPromptGate()
        XCTAssertTrue(gate.allowsAutoPrompt)
        gate.userCancelled()
        XCTAssertFalse(gate.allowsAutoPrompt)            // became active again, no resign in between
        gate.appResigned()
        XCTAssertTrue(gate.allowsAutoPrompt)             // really left and came back
        gate.reset()
        XCTAssertTrue(gate.allowsAutoPrompt)
    }

    func testResignBeforeCancelDoesNotCount() {
        var gate = AutoPromptGate()
        gate.appResigned()
        gate.userCancelled()
        XCTAssertFalse(gate.allowsAutoPrompt)
    }

    // MARK: - Idle auto-lock (HIPAA §164.312(a)(2)(iii) "automatic logoff")

    func testAutoLocksOnceTheIdleIntervalHasElapsed() {
        let lastActivity = Date(timeIntervalSince1970: 0)
        let exactlyAtTimeout = lastActivity.addingTimeInterval(5 * 60)
        let pastTimeout = lastActivity.addingTimeInterval(5 * 60 + 1)
        let beforeTimeout = lastActivity.addingTimeInterval(5 * 60 - 1)

        XCTAssertTrue(AppLockPolicy.shouldAutoLock(lastActivity: lastActivity, timeoutMinutes: 5, now: exactlyAtTimeout))
        XCTAssertTrue(AppLockPolicy.shouldAutoLock(lastActivity: lastActivity, timeoutMinutes: 5, now: pastTimeout))
        XCTAssertFalse(AppLockPolicy.shouldAutoLock(lastActivity: lastActivity, timeoutMinutes: 5, now: beforeTimeout))
    }

    func testNeverAutoLocksWhenTimeoutIsOff() {
        let lastActivity = Date(timeIntervalSince1970: 0)
        let farInTheFuture = lastActivity.addingTimeInterval(60 * 60 * 24 * 365)

        XCTAssertFalse(AppLockPolicy.shouldAutoLock(lastActivity: lastActivity, timeoutMinutes: 0, now: farInTheFuture))
        XCTAssertFalse(AppLockPolicy.shouldAutoLock(lastActivity: lastActivity, timeoutMinutes: -1, now: farInTheFuture))
    }

    func testAutoLockAtActivityMomentIsAlwaysFalse() {
        // Zero elapsed idle time never triggers a lock, whatever the timeout.
        let now = Date()
        XCTAssertFalse(AppLockPolicy.shouldAutoLock(lastActivity: now, timeoutMinutes: 1, now: now))
    }

    @MainActor
    func testAppLockRelocksOnHideAndNotOnResignActive() async {
        let settings = AppSettings.shared
        let priorEnabled = settings.appLockEnabled
        defer { settings.appLockEnabled = priorEnabled }
        settings.appLockEnabled = true

        let appLock = AppLock(settings: settings, canAuthenticate: { true })
        XCTAssertTrue(appLock.isLocked)

        appLock.simulateUnlockedForTesting()
        XCTAssertFalse(appLock.isLocked)

        // Switching to another app (or closing the main window while the chat
        // window stays open) resigns active status without hiding — must not re-lock.
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        await Task.yield()
        XCTAssertFalse(appLock.isLocked)

        // Explicitly hiding Aletheia (⌘H) posts didHideNotification at the app
        // level regardless of which window is open, and must re-lock.
        NotificationCenter.default.post(name: NSApplication.didHideNotification, object: nil)
        await Task.yield()
        XCTAssertTrue(appLock.isLocked)
    }
}
