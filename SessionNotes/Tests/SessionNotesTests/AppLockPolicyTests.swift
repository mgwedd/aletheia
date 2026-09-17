import XCTest
@testable import SessionNotes

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
}
