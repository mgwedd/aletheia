import XCTest
@testable import Aletheia

final class ChatComposerLayoutTests: XCTestCase {
    func testLineBreaksCollapseToASingleSpaceOnSend() {
        XCTAssertEqual(ChatComposerLayout.collapsingLineBreaks("one\ntwo"), "one two")
        XCTAssertEqual(ChatComposerLayout.collapsingLineBreaks("one \n\n  two\r\nthree"), "one two three")
        XCTAssertEqual(ChatComposerLayout.collapsingLineBreaks("no breaks here"), "no breaks here")
    }

    func testFieldGrowsThenScrolls() {
        XCTAssertLessThan(ChatComposerLayout.minFieldHeight, ChatComposerLayout.maxFieldHeight)
        // Room for several lines of body text before it has to scroll.
        XCTAssertGreaterThanOrEqual(ChatComposerLayout.maxFieldHeight, ChatComposerLayout.minFieldHeight * 2.5)
    }

    func testEffortSelectorIsCalledModelEffortAndNamesEveryLevel() {
        XCTAssertEqual(AnswerEffort.label, "AI effort")
        XCTAssertEqual(AnswerEffort.allCases.map(\.displayName), ["Fast", "Normal", "Focus"])
    }

    /// The selector is a segmented control with short labels; the long
    /// descriptions stay out of the composer and the note menu.
    func testPickersDoNotListTheDescriptions() throws {
        let views = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Views")
        for name in ["ChatPaneView.swift", "SessionDetailView.swift"] {
            let source = try String(contentsOf: views.appendingPathComponent(name), encoding: .utf8)
            XCTAssertFalse(source.contains("\\(level.displayName) — \\(level.blurb)"), "\(name) still lists effort descriptions")
        }
    }
}
