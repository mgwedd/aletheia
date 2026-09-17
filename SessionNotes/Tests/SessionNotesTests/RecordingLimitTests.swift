import XCTest
@testable import SessionNotes

final class RecordingLimitTests: XCTestCase {
    func testRemindsAtOrPastThreshold() {
        XCTAssertTrue(RecordingLimit.shouldRemind(elapsed: RecordingLimit.reminderThreshold))
        XCTAssertTrue(RecordingLimit.shouldRemind(elapsed: RecordingLimit.reminderThreshold + 1))
        XCTAssertTrue(RecordingLimit.shouldRemind(elapsed: 100 * 60))
    }

    func testDoesNotRemindBeforeThreshold() {
        XCTAssertFalse(RecordingLimit.shouldRemind(elapsed: 0))
        XCTAssertFalse(RecordingLimit.shouldRemind(elapsed: 60 * 60))          // 1h
        XCTAssertFalse(RecordingLimit.shouldRemind(elapsed: RecordingLimit.reminderThreshold - 1))
    }

    func testThresholdIsNinetyMinutes() {
        XCTAssertEqual(RecordingLimit.reminderThreshold, 90 * 60)
    }

    func testLongRecordingNotificationMentionsPatient() {
        let content = SessionNotifications.longRecordingReminder(patientName: "Jane Doe")
        XCTAssertTrue(content.body.contains("Jane Doe"))
        XCTAssertTrue(content.body.contains("90 minutes"))
    }
}
