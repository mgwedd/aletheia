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
}
