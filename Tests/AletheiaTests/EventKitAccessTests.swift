import XCTest
@testable import Aletheia

final class EventKitAccessTests: XCTestCase {
    func testStatusDoesNotCrash() {
        let calendarStatus = EventKitAccess.status(.calendar)
        let remindersStatus = EventKitAccess.status(.reminders)

        XCTAssertTrue([EventKitAccess.Status.granted, .notDetermined, .denied, .unavailable].contains(calendarStatus))
        XCTAssertTrue([EventKitAccess.Status.granted, .notDetermined, .denied, .unavailable].contains(remindersStatus))
    }
}
