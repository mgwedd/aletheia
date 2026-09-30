import XCTest
@testable import Aletheia

final class CalendarSchedulerTests: XCTestCase {
    func testCalendarSchedulerErrorDescriptions() {
        XCTAssertNotNil(CalendarSchedulerError.accessDenied.errorDescription)
        XCTAssertTrue(CalendarSchedulerError.accessDenied.errorDescription?.contains("permission") == true)
        XCTAssertNotNil(CalendarSchedulerError.unavailable.errorDescription)
        XCTAssertTrue(CalendarSchedulerError.unavailable.errorDescription?.contains("calendar is available") == true)
    }
}
