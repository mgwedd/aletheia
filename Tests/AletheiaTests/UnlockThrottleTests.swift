import XCTest
@testable import Aletheia

final class UnlockThrottleTests: XCTestCase {
    func testBackoffGrowsAndResets() {
        var now = Date(timeIntervalSince1970: 0)
        var throttle = UnlockThrottle(freeAttempts: 2, baseDelay: 2, maxDelay: 10, now: { now })

        throttle.recordFailure()
        throttle.recordFailure()
        XCTAssertEqual(throttle.remainingDelay, 0, "the free attempts cost nothing")

        throttle.recordFailure()
        XCTAssertEqual(throttle.remainingDelay, 2)
        now.addTimeInterval(2)
        XCTAssertEqual(throttle.remainingDelay, 0, "the wait runs out with the clock")

        throttle.recordFailure()
        XCTAssertEqual(throttle.remainingDelay, 4)
        now.addTimeInterval(4)
        throttle.recordFailure()
        XCTAssertEqual(throttle.remainingDelay, 8)
        now.addTimeInterval(8)
        throttle.recordFailure()
        XCTAssertEqual(throttle.remainingDelay, 10, "capped")

        throttle.recordSuccess()
        XCTAssertEqual(throttle.remainingDelay, 0)
        XCTAssertEqual(throttle.failures, 0)
        throttle.recordFailure()
        XCTAssertEqual(throttle.remainingDelay, 0, "the free attempts are back")
    }

    func testSettingTheClockBackDoesNotStretchTheWait() {
        var now = Date(timeIntervalSince1970: 1_000_000)
        var throttle = UnlockThrottle(freeAttempts: 0, baseDelay: 5, maxDelay: 60, now: { now })
        throttle.recordFailure()
        XCTAssertEqual(throttle.remainingDelay, 5)
        now.addTimeInterval(-86_400)
        XCTAssertEqual(throttle.remainingDelay, 5, "never more than the wait that was imposed")
    }
}
