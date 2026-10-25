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
    func testHideRespectsSettingAndDisplaySleepLocks() async {
        let settings = AppSettings.shared
        let priorEnabled = settings.appLockEnabled
        let priorHide = settings.lockWhenHidden
        defer { settings.appLockEnabled = priorEnabled; settings.lockWhenHidden = priorHide }
        settings.appLockEnabled = true
        settings.lockWhenHidden = false

        let appLock = AppLock(settings: settings, canAuthenticate: { true })
        XCTAssertTrue(appLock.isLocked)

        appLock.simulateUnlockedForTesting()
        XCTAssertFalse(appLock.isLocked)

        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        NotificationCenter.default.post(name: NSApplication.didHideNotification, object: nil)
        await Task.yield()
        await Task.yield()
        XCTAssertFalse(appLock.isLocked)

        settings.lockWhenHidden = true
        NotificationCenter.default.post(name: NSApplication.didHideNotification, object: nil)
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(appLock.isLocked)

        appLock.simulateUnlockedForTesting()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.screensDidSleepNotification, object: nil)
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(appLock.isLocked)
    }

    @MainActor
    func testUnlockEndsWhenTheMacSleepsOrTheUserSwitches() async {
        let settings = AppSettings.shared
        let priorEnabled = settings.appLockEnabled
        defer { settings.appLockEnabled = priorEnabled }
        settings.appLockEnabled = true

        let appLock = AppLock(settings: settings, canAuthenticate: { true })

        appLock.simulateUnlockedForTesting()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(appLock.isLocked)

        appLock.simulateUnlockedForTesting()
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(appLock.isLocked)
    }

    func testRelockTriggersAreLeavingTheMacOnly() {
        XCTAssertEqual(RelockTrigger.allCases, [.systemSleep, .displaySleep, .screenLock, .userSwitch])
        let names = RelockTrigger.allCases.map(\.notificationName)
        XCTAssertEqual(names, [
            NSWorkspace.willSleepNotification,
            NSWorkspace.screensDidSleepNotification,
            Notification.Name("com.apple.screenIsLocked"),
            NSWorkspace.sessionDidResignActiveNotification,
        ])
        XCTAssertFalse(names.contains(NSApplication.didHideNotification))
        XCTAssertTrue(names.contains(NSWorkspace.screensDidSleepNotification))
        XCTAssertEqual(RelockTrigger.allCases.filter(\.isDistributed), [.screenLock])
    }

    func testAppLockSourceHasHideAndDisplaySleepTrigger() throws {
        let source = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Services/AppLock.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("didHideNotification"))
        XCTAssertTrue(source.contains("screensDidSleepNotification"))
    }

    func testNewDefaultsAndExplicitChoices() {
        let suiteName = "app-lock-\(UUID())"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let fresh = AppSettings(defaults: defaults)
        XCTAssertTrue(fresh.appLockEnabled)
        XCTAssertEqual(fresh.idleAutoLockMinutes, 15)
        XCTAssertTrue(fresh.hideFromScreenSharing)
        defaults.set(false, forKey: "appLockEnabled")
        defaults.set(0, forKey: "idleAutoLockMinutes")
        let explicit = AppSettings(defaults: defaults)
        XCTAssertFalse(explicit.appLockEnabled)
        XCTAssertEqual(explicit.idleAutoLockMinutes, 0)
    }

    @MainActor
    func testLockIfEnabledRelocksAnUnlockedApp() {
        let settings = AppSettings.shared
        let priorEnabled = settings.appLockEnabled
        defer { settings.appLockEnabled = priorEnabled }
        settings.appLockEnabled = true

        let appLock = AppLock(settings: settings, canAuthenticate: { true })
        appLock.simulateUnlockedForTesting()
        XCTAssertFalse(appLock.isLocked)
        appLock.lockIfEnabled()
        XCTAssertTrue(appLock.isLocked)
    }

    @MainActor
    func testAppLockNotifiesFailedUnlock() {
        let settings = AppSettings.shared
        let appLock = AppLock(settings: settings, canAuthenticate: { true })
        var failedReason: String?
        appLock.onUnlockFailed = { failedReason = $0 }

        appLock.simulateUnlockFailedForTesting(reason: "Biometry lockout")
        XCTAssertEqual(failedReason, "Biometry lockout")
        XCTAssertEqual(appLock.lastError, "Biometry lockout")
    }

    private final class SpotlightSpy: SpotlightIndexing {
        private(set) var clears = 0
        func replaceIndex(with entries: [SpotlightEntry]) {}
        func clear() { clears += 1 }
    }

    @MainActor
    func testLockClearsSpotlightAndIdleTimerRunsInCommonModes() throws {
        let settings = AppSettings.shared
        let priorEnabled = settings.appLockEnabled
        defer { settings.appLockEnabled = priorEnabled }
        settings.appLockEnabled = true

        let spy = SpotlightSpy()
        let appLock = AppLock(settings: settings, canAuthenticate: { true }, spotlight: spy)
        appLock.simulateUnlockedForTesting()
        XCTAssertEqual(spy.clears, 0)
        appLock.lockIfEnabled()
        XCTAssertTrue(appLock.isLocked)
        XCTAssertEqual(spy.clears, 1, "locking removes our Spotlight items")
        appLock.lockIfEnabled()
        XCTAssertEqual(spy.clears, 1, "already locked: nothing more to clear")

        appLock.simulateUnlockedForTesting()

        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Services/AppLock.swift")
        let code = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(code.contains("RunLoop.main.add(timer, forMode: .common)"))
        XCTAssertFalse(code.contains("Timer.scheduledTimer"), "scheduledTimer uses the default mode and stalls during menu tracking")
    }

    @MainActor
    func testIdleLockFollowsTheInjectedClock() {
        let settings = AppSettings(defaults: UserDefaults(suiteName: "idle-clock-\(UUID().uuidString)")!)
        settings.appLockEnabled = true
        settings.idleAutoLockMinutes = 1
        var now = Date()
        let appLock = AppLock(
            settings: settings, canAuthenticate: { true }, isAppActive: { true },
            spotlight: SpotlightSpy(), now: { now })
        appLock.simulateUnlockedForTesting()

        now.addTimeInterval(59)
        appLock.checkIdleTimeout()
        XCTAssertFalse(appLock.isLocked, "locked before a minute of idle time")

        now.addTimeInterval(1)
        appLock.checkIdleTimeout()
        XCTAssertTrue(appLock.isLocked, "did not lock after a minute of idle time")
    }
}
