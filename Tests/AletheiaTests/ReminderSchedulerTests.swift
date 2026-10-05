import XCTest
@testable import Aletheia

final class ReminderSchedulerTests: XCTestCase {
    func testReminderSchedulerErrorDescriptions() {
        XCTAssertNotNil(ReminderSchedulerError.accessDenied.errorDescription)
        XCTAssertTrue(ReminderSchedulerError.accessDenied.errorDescription?.contains("permission") == true)
        XCTAssertNotNil(ReminderSchedulerError.unavailable.errorDescription)
        XCTAssertTrue(ReminderSchedulerError.unavailable.errorDescription?.contains("Reminders aren't available") == true)
    }
}
