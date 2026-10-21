import XCTest
@testable import Aletheia

/// Text can be selected and copied on read-only screens. Selectable text takes
/// mouse clicks, so it is kept off anything that acts on a click: the patient and
/// session lists (row selection), the search results, and the comment cards
/// (click to focus). These scans pin both sides.
final class SelectableTextTests: XCTestCase {
    private func source(_ name: String) throws -> String {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Views/\(name)")
        return try String(contentsOf: file, encoding: .utf8)
    }

    func testReadOnlyScreensAllowSelection() throws {
        for name in ["SettingsView.swift", "SessionDetailView.swift", "ConsentGuideView.swift",
                     "FirstRunView.swift", "UpdatePromptView.swift", "ChatPaneView.swift"] {
            XCTAssertTrue(try source(name).contains(".textSelection(.enabled)"), "\(name) should allow selecting text")
        }
    }

    func testClickableListsNeverEnableSelection() throws {
        for name in ["PatientsListView.swift", "PatientDetailView.swift", "GlobalSearchResultsView.swift", "RecordingMenuBar.swift"] {
            XCTAssertFalse(try source(name).contains(".textSelection(.enabled)"), "\(name) has click-to-act rows")
        }
    }

    func testCommentCardsKeepTheirClickToFocus() throws {
        let session = try source("SessionDetailView.swift")
        let call = try XCTUnwrap(session.range(of: "CommentsRailView("))
        let after = session[call.upperBound...].prefix(700)
        XCTAssertTrue(after.contains(".textSelection(.disabled)"), "the comments rail must opt out of selection")
        XCTAssertFalse(try source("CommentsRailView.swift").contains(".textSelection(.enabled)"))
    }
}
