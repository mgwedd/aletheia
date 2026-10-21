import XCTest
@testable import Aletheia

final class ChatComposerLayoutTests: XCTestCase {
    func testReturnSendsAndModifiedReturnAddsALine() {
        XCTAssertEqual(ChatComposerLayout.returnKeyAction(shift: false, option: false), .send)
        XCTAssertEqual(ChatComposerLayout.returnKeyAction(shift: true, option: false), .newline)
        XCTAssertEqual(ChatComposerLayout.returnKeyAction(shift: false, option: true), .newline)
        XCTAssertEqual(ChatComposerLayout.returnKeyAction(shift: true, option: true), .newline)
    }

    func testTabMovesFocusInsteadOfTyping() {
        XCTAssertEqual(ChatComposerLayout.tabKeyAction(shift: false), .nextControl)
        XCTAssertEqual(ChatComposerLayout.tabKeyAction(shift: true), .previousControl)
    }

    func testSizingTextIsNeverEmptyAndCountsATrailingNewline() {
        XCTAssertEqual(ChatComposerLayout.sizingText(for: ""), " ")
        XCTAssertEqual(ChatComposerLayout.sizingText(for: "hello"), "hello")
        XCTAssertEqual(ChatComposerLayout.sizingText(for: "hello\n"), "hello\n ")
        XCTAssertEqual(ChatComposerLayout.sizingText(for: "a\n\n"), "a\n\n ")
    }

    func testFieldGrowsThenScrolls() {
        XCTAssertLessThan(ChatComposerLayout.minFieldHeight, ChatComposerLayout.maxFieldHeight)
        // Room for several lines of body text before it has to scroll.
        XCTAssertGreaterThanOrEqual(ChatComposerLayout.maxFieldHeight, ChatComposerLayout.minFieldHeight * 2.5)
    }

    func testEffortSelectorIsCalledModelEffortAndNamesEveryLevel() {
        XCTAssertEqual(AnswerEffort.label, "Model effort")
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
