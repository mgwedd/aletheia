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
        XCTAssertEqual(MarkdownTextStyle.note.blockSpacing, 6)
        XCTAssertEqual(MarkdownTextStyle.note.listSpacing, 0)
        for level in 1...4 {
            XCTAssertEqual(MarkdownTextStyle.note.headingFont(level), Theme.Typography.noteHeading)
            XCTAssertEqual(MarkdownTextStyle.note.headingTopPadding(level), 12)
        }
    }
}
