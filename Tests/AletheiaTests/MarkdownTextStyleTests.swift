import SwiftUI
import XCTest
@testable import Aletheia

/// The style → font/spacing mapping behind `MarkdownMessageView`: chat answers
/// keep the inherited sans look, generated notes use the serif theme tokens.
final class MarkdownTextStyleTests: XCTestCase {
    func testReadingStyleInheritsBodyFontAndSpacing() {
        XCTAssertNil(MarkdownTextStyle.reading.bodyFont)
        XCTAssertNil(MarkdownTextStyle.reading.lineSpacing)
        XCTAssertEqual(MarkdownTextStyle.reading.blockSpacing, 8)
        XCTAssertEqual(MarkdownTextStyle.reading.listSpacing, 4)
    }

    func testReadingStyleKeepsTheChatHeadingScale() {
        XCTAssertEqual(MarkdownTextStyle.reading.headingFont(1), Font.title2.bold())
        XCTAssertEqual(MarkdownTextStyle.reading.headingFont(2), Font.title3.bold())
        XCTAssertEqual(MarkdownTextStyle.reading.headingFont(3), Font.headline)
        XCTAssertEqual(MarkdownTextStyle.reading.headingFont(4), Font.subheadline.bold())
        XCTAssertEqual(MarkdownTextStyle.reading.headingTopPadding(1), 2)
        XCTAssertEqual(MarkdownTextStyle.reading.headingTopPadding(2), 2)
        XCTAssertEqual(MarkdownTextStyle.reading.headingTopPadding(3), 0)
    }

    func testNoteStyleUsesTheSerifThemeTokens() {
        XCTAssertEqual(MarkdownTextStyle.note.bodyFont, Theme.Typography.noteBody)
        XCTAssertEqual(MarkdownTextStyle.note.lineSpacing, Theme.Typography.noteLineSpacing)
        for level in 1...2 {
            XCTAssertEqual(MarkdownTextStyle.note.headingFont(level), Theme.Typography.noteHeading)
            XCTAssertEqual(MarkdownTextStyle.note.headingTopPadding(level), 12)
        }
        for level in 3...6 {
            XCTAssertEqual(MarkdownTextStyle.note.headingFont(level), Theme.Typography.noteBody.weight(.semibold))
            XCTAssertEqual(MarkdownTextStyle.note.headingTopPadding(level), 4)
        }
    }

    func testNoteParagraphGapIsClearlyLargerThanLineSpacing() {
        let note = MarkdownTextStyle.note
        XCTAssertGreaterThanOrEqual(note.blockSpacing, 2 * Theme.Typography.noteLineSpacing)
        XCTAssertGreaterThan(note.listSpacing, Theme.Typography.noteLineSpacing)
        XCTAssertLessThan(note.listSpacing, note.blockSpacing)
        // A heading sits closer to what it introduces than to what came before.
        XCTAssertLessThan(note.blockSpacing + note.headingBottomPadding, note.blockSpacing + note.headingTopPadding(2))
    }

    func testOnlyTheNoteStyleTidiesText() {
        let raw = "Here is the note:\nOne.\nTwo."
        XCTAssertEqual(MarkdownTextStyle.reading.prepared(raw), raw)
        XCTAssertEqual(MarkdownTextStyle.note.prepared(raw), "One.\n\nTwo.")
        XCTAssertEqual(MarkdownTextStyle.reading.headingBottomPadding, 0)
    }
}
