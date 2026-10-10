import XCTest
@testable import Aletheia

final class ReleaseNotesFormatterTests: XCTestCase {
    func testStripsListMarkersAndBlankLines() {
        let notes = "- Faster transcription\n\n* Fixes for damaged records\n• Plain bullet\nNo marker"
        XCTAssertEqual(
            ReleaseNotesFormatter.items(from: notes),
            ["Faster transcription", "Fixes for damaged records", "Plain bullet", "No marker"]
        )
    }

    func testDropsMarkdownHeadings() {
        XCTAssertEqual(ReleaseNotesFormatter.items(from: "## Features\n- One"), ["One"])
    }

    func testEmptyNotesYieldNoItems() {
        XCTAssertEqual(ReleaseNotesFormatter.items(from: "  \n \n"), [])
    }
}
