import XCTest
@testable import Aletheia

final class ScheduleQuickPickTests: XCTestCase {
    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    func testPicksAreSevenFourteenTwentyEightDaysOut() {
        XCTAssertEqual(ScheduleQuickPick.allCases.map(\.days), [7, 14, 28])
    }

    func testPickMovesTheDayAndKeepsTheTimeOfDay() {
        let now = date(2026, 10, 9, 8)
        let current = date(2026, 10, 16, 14, 30)
        let picked = ScheduleQuickPick.inTwoWeeks.date(from: now, keepingTimeOf: current, calendar: calendar)
        XCTAssertEqual(picked, date(2026, 10, 23, 14, 30))
    }

    func testMatchesComparesDaysNotTimes() {
        let now = date(2026, 10, 9, 8)
        XCTAssertTrue(ScheduleQuickPick.nextWeek.matches(date(2026, 10, 16, 17), now: now, calendar: calendar))
        XCTAssertFalse(ScheduleQuickPick.nextWeek.matches(date(2026, 10, 17, 9), now: now, calendar: calendar))
        XCTAssertFalse(ScheduleQuickPick.inFourWeeks.matches(date(2026, 10, 16, 9), now: now, calendar: calendar))
    }
}

final class ScheduleNextSessionTests: XCTestCase {
    func testTheStandardLengthsAreOfferedAsTheyAre() {
        XCTAssertEqual(ScheduleNextSession.lengthChoices(including: 50), [30, 45, 50, 60, 90])
    }

    func testAnUnusualCurrentLengthIsKeptAndSortedIn() {
        XCTAssertEqual(ScheduleNextSession.lengthChoices(including: 75), [30, 45, 50, 60, 75, 90])
        XCTAssertEqual(ScheduleNextSession.lengthChoices(including: 15), [15, 30, 45, 50, 60, 90])
    }

    func testTheFooterSaysWhetherAFileIsSaved() {
        XCTAssertEqual(ScheduleNextSession.footerText(exportICS: false), "Adds an event to your calendar.")
        XCTAssertTrue(ScheduleNextSession.footerText(exportICS: true).contains(".ics"))
    }

    func testASuccessfulScheduleIsConfirmedWithOrWithoutTheFile() {
        XCTAssertEqual(
            ScheduleNextSession.outcome(eventTitle: "Session", calendarFailure: nil, icsSaved: false),
            .confirmation("Added “Session” to your Calendar."))
        XCTAssertEqual(
            ScheduleNextSession.outcome(eventTitle: "Session", calendarFailure: nil, icsSaved: true),
            .confirmation("Added “Session” to your Calendar and saved .ics file."))
    }

    func testACalendarFailureIsNeverHiddenEvenWhenTheFileWasSaved() {
        XCTAssertEqual(
            ScheduleNextSession.outcome(eventTitle: "Session", calendarFailure: "No access", icsSaved: true),
            .confirmation("Saved .ics file. Could not add to Calendar: No access"))
        XCTAssertEqual(
            ScheduleNextSession.outcome(eventTitle: "Session", calendarFailure: "No access", icsSaved: false),
            .error("No access"))
    }
}
