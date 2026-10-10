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
