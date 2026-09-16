import XCTest
@testable import SessionNotes

final class StableIDTests: XCTestCase {
    func testSameStringProducesSameID() {
        let a = StableID.uuid(from: "2026-09-16_Session")
        let b = StableID.uuid(from: "2026-09-16_Session")
        XCTAssertEqual(a, b)
    }

    func testDifferentStringsProduceDifferentIDs() {
        let a = StableID.uuid(from: "2026-09-16_Session")
        let b = StableID.uuid(from: "2026-09-16_Session-2")
        XCTAssertNotEqual(a, b)
    }

    func testProducesWellFormedVersion4UUID() {
        let id = StableID.uuid(from: "any-folder-name")
        // Version nibble (bits 12-15 of time_hi_and_version, i.e. byte 6's
        // high nibble) should read 4, and the variant bits (byte 8's top
        // two bits) should read 10 — both are what we force in StableID.
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        XCTAssertEqual(bytes[6] & 0xF0, 0x40)
        XCTAssertEqual(bytes[8] & 0xC0, 0x80)
    }
}
