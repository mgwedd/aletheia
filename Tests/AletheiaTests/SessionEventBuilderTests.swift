import XCTest
@testable import Aletheia

final class SessionEventBuilderTests: XCTestCase {
    private var calendar: Calendar!
    private var now: Date!

    override func setUp() {
        super.setUp()
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "America/New_York")!
        calendar = cal
        now = cal.date(from: DateComponents(year: 2026, month: 3, day: 5, hour: 14, minute: 30))!
    }

    func testDraftTitleAndDuration() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 9))!
        let draft = SessionEventBuilder.draft(patientName: "Jane Doe", start: start, durationMinutes: 50, calendar: calendar)
        XCTAssertEqual(draft.title, "Session with Jane Doe")
        XCTAssertEqual(draft.startDate, start)
        XCTAssertEqual(draft.endDate, calendar.date(byAdding: .minute, value: 50, to: start))
    }

    func testDefaultDurationIsATherapyHour() {
        let start = now!
        let draft = SessionEventBuilder.draft(patientName: "Jane", start: start, calendar: calendar)
        let minutes = calendar.dateComponents([.minute], from: draft.startDate, to: draft.endDate).minute
        XCTAssertEqual(minutes, 50)
    }

    func testSuggestedStartIsOneWeekOutAtNineAM() {
        let start = SessionEventBuilder.suggestedStart(from: now, calendar: calendar)
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: start)
        XCTAssertEqual(comps.day, 12, "one week after the 5th")
        XCTAssertEqual(comps.hour, 9)
        XCTAssertEqual(comps.minute, 0)
    }

    func testDraftWithRecurrence() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 3, day: 12, hour: 9))!
        let draft = SessionEventBuilder.draft(
            patientName: "Jane Doe",
            start: start,
            durationMinutes: 50,
            recurrence: .everyTwoWeeks,
            calendar: calendar
        )
        XCTAssertEqual(draft.recurrence, .everyTwoWeeks)
    }

    func testEventRecurrenceDisplayNamesAndRRule() {
        XCTAssertEqual(EventRecurrence.never.displayName, "Never")
        XCTAssertNil(EventRecurrence.never.rruleString)

        XCTAssertEqual(EventRecurrence.weekly.displayName, "Every week")
        XCTAssertEqual(EventRecurrence.weekly.rruleString, "FREQ=WEEKLY")

        XCTAssertEqual(EventRecurrence.everyTwoWeeks.displayName, "Every 2 weeks")
        XCTAssertEqual(EventRecurrence.everyTwoWeeks.rruleString, "FREQ=WEEKLY;INTERVAL=2")

        XCTAssertEqual(EventRecurrence.everyFourWeeks.displayName, "Every 4 weeks")
        XCTAssertEqual(EventRecurrence.everyFourWeeks.rruleString, "FREQ=WEEKLY;INTERVAL=4")

        XCTAssertEqual(EventRecurrence.monthly.displayName, "Every month")
        XCTAssertEqual(EventRecurrence.monthly.rruleString, "FREQ=MONTHLY")
    }

    func testICSExporterGeneratesRFC5545() {
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 15, minute: 0, second: 0))!
        let end = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 15, minute: 50, second: 0))!
        let stamp = cal.date(from: DateComponents(year: 2026, month: 10, day: 19, hour: 12, minute: 0, second: 0))!

        let draft = EventDraft(
            title: "Session with Jane, & John; \"Special\"",
            notes: "Therapy session;\nNext steps.",
            startDate: start,
            endDate: end,
            recurrence: .weekly
        )

        let ics = ICSExporter.generate(for: draft, uid: "test-uid-1234", now: stamp)

        XCTAssertTrue(ics.contains("BEGIN:VCALENDAR\r\n"))
        XCTAssertTrue(ics.contains("VERSION:2.0\r\n"))
        XCTAssertTrue(ics.contains("PRODID:-//Aletheia//Aletheia//EN\r\n"))
        XCTAssertTrue(ics.contains("BEGIN:VEVENT\r\n"))
        XCTAssertTrue(ics.contains("UID:test-uid-1234@aletheia\r\n"))
        XCTAssertTrue(ics.contains("DTSTAMP:20261019T120000Z\r\n"))
        XCTAssertTrue(ics.contains("DTSTART:20261026T150000Z\r\n"))
        XCTAssertTrue(ics.contains("DTEND:20261026T155000Z\r\n"))
        XCTAssertTrue(ics.contains("SUMMARY:Session with Jane\\, & John\\; \"Special\"\r\n"))
        XCTAssertTrue(ics.contains("DESCRIPTION:Therapy session\\;\\nNext steps.\r\n"))
        XCTAssertTrue(ics.contains("RRULE:FREQ=WEEKLY\r\n"))
        XCTAssertTrue(ics.contains("END:VEVENT\r\n"))
        XCTAssertTrue(ics.contains("END:VCALENDAR\r\n"))
    }

    func testICSExporterWithoutRecurrence() {
        let utc = TimeZone(identifier: "UTC")!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let start = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 15))!
        let end = cal.date(from: DateComponents(year: 2026, month: 10, day: 26, hour: 16))!

        let draft = EventDraft(
            title: "Single Session",
            notes: "",
            startDate: start,
            endDate: end,
            recurrence: .never
        )

        let ics = ICSExporter.generate(for: draft, uid: "single-123")
        XCTAssertFalse(ics.contains("RRULE"))
        XCTAssertFalse(ics.contains("DESCRIPTION"))
        XCTAssertTrue(ics.contains("SUMMARY:Single Session\r\n"))
    }
}
