import XCTest
@testable import Aletheia

final class ContextBudgetTests: XCTestCase {
    /// Material is never cut where it is tagged: callers size it, and a prompt
    /// that still doesn't fit is refused by the budget check.
    func testUntrustedTextIsNeverCut() {
        let huge = String(repeating: "a", count: 2_000_000)
        for kind in UntrustedText.Kind.allCases {
            XCTAssertEqual(UntrustedText(kind, huge).text, huge, "\(kind)")
        }
    }

    /// A huge comment is not cut silently: only the parts that match go in,
    /// under a line saying so, and the coverage names the field.
    func testHugeCommentGoesInAsMatchingPartsAndIsReported() throws {
        let budget = ContextBudget(tokens: 8_192)
        let filler = (1...4_000).map { "Line \($0) about the weather and the bus." }
        var lines = filler
        lines.insert("She mentioned her sister's wedding again.", at: 2_500)
        let fields = try TherapistFields(
            notes: "short", comments: [lines.joined(separator: "\n")], background: "",
            query: "sister wedding", budget: budget)
        XCTAssertEqual(fields.excerpted, [.comments])
        XCTAssertEqual(fields.notes, "short")
        let comment = try XCTUnwrap(fields.comments.first)
        XCTAssertLessThanOrEqual(comment.count, TherapistInput.room(in: budget))
        XCTAssertTrue(comment.contains("sister's wedding"))
        XCTAssertTrue(comment.hasPrefix("(About "))
        XCTAssertEqual(fields.coverageNote, "Only the parts of the margin comments that match were read: it is too long to send whole.")
    }
}
