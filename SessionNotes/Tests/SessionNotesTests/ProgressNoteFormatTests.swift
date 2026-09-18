import XCTest
@testable import SessionNotes

final class ProgressNoteFormatTests: XCTestCase {
    func testSectionHeadingsMatchEachFormat() {
        XCTAssertEqual(ProgressNoteFormat.soap.sections.map(\.heading), ["Subjective", "Objective", "Assessment", "Plan"])
        XCTAssertEqual(ProgressNoteFormat.dap.sections.map(\.heading), ["Data", "Assessment", "Plan"])
        XCTAssertEqual(ProgressNoteFormat.birp.sections.map(\.heading), ["Behavior", "Intervention", "Response", "Plan"])
        XCTAssertTrue(ProgressNoteFormat.narrative.sections.isEmpty)
    }

    func testEveryStructuredSectionHasGuidance() {
        for format in ProgressNoteFormat.allCases where !format.sections.isEmpty {
            for section in format.sections {
                XCTAssertFalse(section.guidance.trimmingCharacters(in: .whitespaces).isEmpty,
                               "\(format.rawValue)/\(section.heading) needs guidance")
            }
        }
    }

    func testRawValueRoundTrips() {
        for format in ProgressNoteFormat.allCases {
            XCTAssertEqual(ProgressNoteFormat(rawValue: format.rawValue), format)
        }
    }

    func testShortAndDisplayNamesAreDistinct() {
        let shorts = Set(ProgressNoteFormat.allCases.map(\.shortName))
        XCTAssertEqual(shorts.count, ProgressNoteFormat.allCases.count)
        let displays = Set(ProgressNoteFormat.allCases.map(\.displayName))
        XCTAssertEqual(displays.count, ProgressNoteFormat.allCases.count)
    }
}
