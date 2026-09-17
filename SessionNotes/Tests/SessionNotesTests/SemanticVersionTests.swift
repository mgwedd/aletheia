import XCTest
@testable import SessionNotes

final class SemanticVersionTests: XCTestCase {
    func testParsesFullAndPartialVersions() {
        XCTAssertEqual(SemanticVersion("1.2.3"), SemanticVersion(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(SemanticVersion("2.0"), SemanticVersion(major: 2, minor: 0, patch: 0))
        XCTAssertEqual(SemanticVersion("3"), SemanticVersion(major: 3, minor: 0, patch: 0))
    }

    func testIgnoresPreReleaseAndBuildMetadata() {
        XCTAssertEqual(SemanticVersion("1.4.0-beta.1"), SemanticVersion(major: 1, minor: 4, patch: 0))
        XCTAssertEqual(SemanticVersion("1.4.0+build7"), SemanticVersion(major: 1, minor: 4, patch: 0))
    }

    func testRejectsNonNumeric() {
        XCTAssertNil(SemanticVersion("not-a-version"))
        XCTAssertNil(SemanticVersion("1.x.0"))
    }

    func testOrdering() {
        XCTAssertLessThan(SemanticVersion("1.0.0")!, SemanticVersion("1.0.1")!)
        XCTAssertLessThan(SemanticVersion("1.0.9")!, SemanticVersion("1.1.0")!)
        XCTAssertLessThan(SemanticVersion("1.9.9")!, SemanticVersion("2.0.0")!)
        XCTAssertGreaterThan(SemanticVersion("2.0.0")!, SemanticVersion("1.99.99")!)
        XCTAssertEqual(SemanticVersion("1.2.3")!, SemanticVersion("1.2.3")!)
    }
}
