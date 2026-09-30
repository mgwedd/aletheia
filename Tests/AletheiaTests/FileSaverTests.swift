import XCTest
@testable import Aletheia

final class FileSaverTests: XCTestCase {
    func testFileNameSanitizesDisallowedCharacters() {
        let name = FileSaver.fileName("Patient/Name*", "Summary: Notes?")
        XCTAssertEqual(name, "Patient-Name- - Summary- Notes-")
    }

    func testFileNameJoinsMultiplePartsWithHyphenSpace() {
        let name = FileSaver.fileName("Alice Smith", "2026-09-30")
        XCTAssertEqual(name, "Alice Smith - 2026-09-30")
    }
}
