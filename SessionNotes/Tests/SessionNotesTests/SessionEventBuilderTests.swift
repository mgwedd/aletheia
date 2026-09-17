import XCTest
@testable import SessionNotes

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
}
