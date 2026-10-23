import XCTest
@testable import Aletheia

final class RevocationFetchPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testNeverFetchedIsDueWhenUpdateChecksAreOn() {
        XCTAssertTrue(RevocationFetchPolicy(updateChecksEnabled: true, lastAttempt: nil).shouldFetch(now: now))
    }

    func testDisabledWhenUpdateChecksAreOff() {
        XCTAssertFalse(RevocationFetchPolicy(updateChecksEnabled: false, lastAttempt: nil).shouldFetch(now: now))
        XCTAssertFalse(RevocationFetchPolicy(updateChecksEnabled: false, lastAttempt: now - 3 * 86_400).shouldFetch(now: now))
    }

    func testAtMostOncePer24Hours() {
        func due(_ age: TimeInterval) -> Bool {
            RevocationFetchPolicy(updateChecksEnabled: true, lastAttempt: now - age).shouldFetch(now: now)
        }
        XCTAssertFalse(due(0))
        XCTAssertFalse(due(23 * 3600 + 3599))
        XCTAssertTrue(due(24 * 3600))
        XCTAssertTrue(due(5 * 86_400))
    }

    func testClockSetBackIsTreatedAsDue() {
        XCTAssertTrue(RevocationFetchPolicy(updateChecksEnabled: true, lastAttempt: now + 3600).shouldFetch(now: now))
    }

    func testIntervalIsTwentyFourHours() {
        XCTAssertEqual(RevocationFetchPolicy.minimumInterval, 86_400)
    }
}
