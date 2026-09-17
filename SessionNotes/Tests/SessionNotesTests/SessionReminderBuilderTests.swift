import XCTest
@testable import SessionNotes

final class SessionReminderBuilderTests: XCTestCase {
    private var calendar: Calendar!
    private var now: Date!

    override func setUp() {
        super.setUp()
        // Fixed calendar/time so due-date math is deterministic.
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        calendar = cal
        // 2026-03-05 14:30 in that zone.
        now = cal.date(from: DateComponents(year: 2026, month: 3, day: 5, hour: 14, minute: 30))!
    }

    func testDraftTitleAndNotes() {
        let draft = SessionReminderBuilder.draft(
            patientName: "Jane Doe",
            sessionDate: calendar.date(from: DateComponents(year: 2026, month: 3, day: 5))!,
            leadTime: .tomorrow,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(draft.title, "Follow up: Jane Doe")
        XCTAssertTrue(draft.notes.contains("therapy session on"))
    }

    func testLeadTimesResolveToNineAMOnTheOffsetDay() {
        for (lead, expectedDay) in [(ReminderLeadTime.tomorrow, 6), (.inThreeDays, 8), (.nextWeek, 12)] {
            let due = lead.dueDate(from: now, calendar: calendar)
            let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            XCTAssertEqual(comps.day, expectedDay, "\(lead) should land on day \(expectedDay)")
            XCTAssertEqual(comps.hour, 9, "\(lead) should be at 9 AM")
            XCTAssertEqual(comps.minute, 0)
        }
    }

    func testDraftDueDateMatchesLeadTime() {
        let draft = SessionReminderBuilder.draft(
            patientName: "Jane",
            sessionDate: now,
            leadTime: .nextWeek,
            now: now,
            calendar: calendar
        )
        XCTAssertEqual(draft.dueDate, ReminderLeadTime.nextWeek.dueDate(from: now, calendar: calendar))
    }

    func testAllLeadTimesAreSelectableAndNamed() {
        for lead in ReminderLeadTime.allCases {
            XCTAssertFalse(lead.displayName.isEmpty)
            XCTAssertEqual(ReminderLeadTime(rawValue: lead.rawValue), lead)
        }
    }
}
