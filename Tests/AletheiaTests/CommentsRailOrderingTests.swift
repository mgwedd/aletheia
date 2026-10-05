import XCTest
@testable import Aletheia

/// The rail orders active comments the way they read against the transcript:
/// anchored comments first in time order, then un-anchored ones in creation
/// order. This pins that pure comparator without rendering any SwiftUI.
final class CommentsRailOrderingTests: XCTestCase {
    private func comment(_ body: String, anchor: Double?, created: TimeInterval) -> SessionComment {
        SessionComment(
            id: body, quotedText: "", body: body,
            createdAt: Date(timeIntervalSince1970: created),
            updatedAt: Date(timeIntervalSince1970: created),
            anchorSeconds: anchor
        )
    }

    private func sorted(_ comments: [SessionComment]) -> [String] {
        comments.sorted(by: CommentsRailView.byTranscriptPosition).map(\.body)
    }

    func testAnchoredSortByTimeThenUnanchoredByCreation() {
        let comments = [
            comment("late-typed", anchor: nil, created: 100),
            comment("at-0600", anchor: 600, created: 50),
            comment("early-typed", anchor: nil, created: 10),
            comment("at-0120", anchor: 120, created: 90),
        ]
        XCTAssertEqual(sorted(comments), ["at-0120", "at-0600", "early-typed", "late-typed"])
    }

    func testAnchoredComeBeforeUnanchored() {
        let comments = [
            comment("typed", anchor: nil, created: 1),
            comment("anchored", anchor: 999, created: 2),
        ]
        XCTAssertEqual(sorted(comments), ["anchored", "typed"])
    }

    func testEqualAnchorsTieBreakOnCreation() {
        let comments = [
            comment("second", anchor: 300, created: 200),
            comment("first", anchor: 300, created: 100),
        ]
        XCTAssertEqual(sorted(comments), ["first", "second"])
    }
}
