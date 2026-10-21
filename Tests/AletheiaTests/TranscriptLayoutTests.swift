import XCTest
@testable import Aletheia

/// A narrow pane drops the comments rail rather than squeezing the transcript
/// text down to a letter per line.
final class TranscriptLayoutTests: XCTestCase {
    func testRailShowsOnlyWhenTheTextKeepsItsMinimumWidth() {
        let threshold = TranscriptLayout.minTextWidth + TranscriptLayout.railWidth
        XCTAssertTrue(TranscriptLayout.showsCommentsRail(width: threshold))
        XCTAssertTrue(TranscriptLayout.showsCommentsRail(width: threshold + 300))
        XCTAssertFalse(TranscriptLayout.showsCommentsRail(width: threshold - 1))
        XCTAssertFalse(TranscriptLayout.showsCommentsRail(width: 360))
        XCTAssertFalse(TranscriptLayout.showsCommentsRail(width: 0))
    }

    func testThresholdAccountsForTheRailsOwnMinimumWidth() {
        XCTAssertEqual(TranscriptLayout.railWidth, CommentsRailView.minWidth + 1)
        XCTAssertGreaterThan(TranscriptLayout.minTextWidth, 88 + 24, "wider than the text's own gutters")
    }

    func testSessionPaneUsesThePolicyAndRailUsesItsSharedMinimum() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Views")
        let detail = try String(contentsOf: views.appendingPathComponent("SessionDetailView.swift"), encoding: .utf8)
        XCTAssertTrue(detail.contains("TranscriptLayout.showsCommentsRail(width:"))
        let rail = try String(contentsOf: views.appendingPathComponent("CommentsRailView.swift"), encoding: .utf8)
        XCTAssertTrue(rail.contains(".frame(minWidth: Self.minWidth"))
    }
}
