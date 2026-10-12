import XCTest
@testable import Aletheia

final class SingleFlightTests: XCTestCase {
    func testSecondBeginWhileRunningIsRefused() {
        var flight = SingleFlight()
        XCTAssertTrue(flight.begin())
        XCTAssertFalse(flight.begin())
        XCTAssertTrue(flight.isRunning)
    }

    func testCanBeginAgainAfterEnd() {
        var flight = SingleFlight()
        XCTAssertTrue(flight.begin())
        flight.end()
        XCTAssertFalse(flight.isRunning)
        XCTAssertTrue(flight.begin())
    }

    func testEndWithoutBeginIsHarmless() {
        var flight = SingleFlight()
        flight.end()
        XCTAssertTrue(flight.begin())
    }
}
