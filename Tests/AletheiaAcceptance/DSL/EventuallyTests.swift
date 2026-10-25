import XCTest

final class EventuallyTests: XCTestCase {
    func test_returnsOnceTheConditionHolds() async throws {
        var polls = 0
        try await eventually("three polls") {
            polls += 1
            return polls >= 3
        }
        XCTAssertEqual(polls, 3)
    }

    func test_returnsAtOnceWhenAlreadyTrue() async throws {
        var polls = 0
        try await eventually("already true") { polls += 1; return true }
        XCTAssertEqual(polls, 1)
    }

    func test_timeoutNamesWhatWasAwaited() async {
        do {
            try await eventually(within: 0.05, "the sheet to close") { false }
            XCTFail("should have timed out")
        } catch let timeout as EventuallyTimeout {
            XCTAssertEqual(timeout.what, "the sheet to close")
            XCTAssertTrue("\(timeout)".contains("the sheet to close"))
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    func test_aThrowingConditionPropagates() async {
        struct Boom: Error {}
        do {
            try await eventually("never") { throw Boom() }
            XCTFail("should have thrown")
        } catch is Boom {
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }
}
