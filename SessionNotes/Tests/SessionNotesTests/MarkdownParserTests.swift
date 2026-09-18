import XCTest
@testable import SessionNotes

final class MarkdownParserTests: XCTestCase {
    func testPlainProseIsOneParagraph() {
        XCTAssertEqual(
            MarkdownParser.parse("The patient reported improved sleep."),
            [.paragraph("The patient reported improved sleep.")]
        )
    }

    func testBlankLineSeparatesParagraphs() {
        XCTAssertEqual(
            MarkdownParser.parse("First point.\n\nSecond point."),
            [.paragraph("First point."), .paragraph("Second point.")]
        )
    }

    func testSoftBreaksArePreservedWithinAParagraph() {
        XCTAssertEqual(
            MarkdownParser.parse("Line one\nLine two"),
            [.paragraph("Line one\nLine two")]
        )
    }

    func testHeadingLevels() {
        XCTAssertEqual(MarkdownParser.parse("# Title"), [.heading(level: 1, text: "Title")])
        XCTAssertEqual(MarkdownParser.parse("### Deeper"), [.heading(level: 3, text: "Deeper")])
    }

    func testHashWithoutSpaceIsNotAHeading() {
        XCTAssertEqual(MarkdownParser.parse("#hashtag not a heading"),
                       [.paragraph("#hashtag not a heading")])
    }

    func testSevenHashesIsProseNotHeading() {
        XCTAssertEqual(MarkdownParser.parse("####### too deep"),
                       [.paragraph("####### too deep")])
    }

    func testBulletedListAcceptsDashStarPlus() {
        XCTAssertEqual(
            MarkdownParser.parse("- one\n* two\n+ three"),
            [.bulleted(["one", "two", "three"])]
        )
    }

    func testNumberedListWithDotAndParen() {
        XCTAssertEqual(
            MarkdownParser.parse("1. first\n2) second"),
            [.numbered(["first", "second"])]
        )
    }

    func testBlockQuoteGroupsConsecutiveLines() {
        XCTAssertEqual(
            MarkdownParser.parse("> quoted one\n> quoted two"),
            [.quote(["quoted one", "quoted two"])]
        )
    }

    func testFencedCodeWithLanguage() {
        let md = "```swift\nlet x = 1\n```"
        XCTAssertEqual(MarkdownParser.parse(md), [.code(language: "swift", code: "let x = 1")])
    }

    func testFencedCodePreservesBlankLinesAndIndentation() {
        let md = "```\nline1\n\n    indented\n```"
        XCTAssertEqual(MarkdownParser.parse(md), [.code(language: nil, code: "line1\n\n    indented")])
    }

    func testUnterminatedFenceStreamsToEnd() {
        // Mid-stream a closing fence hasn't arrived yet: the rest must render as
        // code, not be reclassified as prose.
        let md = "```python\nprint('hi')\nmore code"
        XCTAssertEqual(MarkdownParser.parse(md), [.code(language: "python", code: "print('hi')\nmore code")])
    }

    func testMermaidBlockIsDetected() {
        let md = "```mermaid\nflowchart LR\n  A --> B\n```"
        let blocks = MarkdownParser.parse(md)
        XCTAssertEqual(blocks, [.code(language: "mermaid", code: "flowchart LR\n  A --> B")])
        XCTAssertTrue(blocks.first?.isMermaid == true)
    }

    func testCodeBlockDoesNotSwallowFollowingProse() {
        let md = "```\ncode\n```\nAfter the block."
        XCTAssertEqual(
            MarkdownParser.parse(md),
            [.code(language: nil, code: "code"), .paragraph("After the block.")]
        )
    }

    func testThematicBreak() {
        XCTAssertEqual(MarkdownParser.parse("---"), [.rule])
        XCTAssertEqual(MarkdownParser.parse("***"), [.rule])
    }

    func testDashListIsNotMistakenForRule() {
        XCTAssertEqual(MarkdownParser.parse("- a real bullet"), [.bulleted(["a real bullet"])])
    }

    func testCRLFNewlinesBehaveLikeLF() {
        XCTAssertEqual(
            MarkdownParser.parse("# Title\r\n\r\nBody."),
            [.heading(level: 1, text: "Title"), .paragraph("Body.")]
        )
    }

    func testMixedDocumentOrder() {
        let md = """
        # Summary

        The patient discussed:

        - work stress
        - sleep

        > "I feel stuck."

        ```mermaid
        flowchart TD
          A --> B
        ```

        Follow up next week.
        """
        XCTAssertEqual(
            MarkdownParser.parse(md),
            [
                .heading(level: 1, text: "Summary"),
                .paragraph("The patient discussed:"),
                .bulleted(["work stress", "sleep"]),
                .quote(["\"I feel stuck.\""]),
                .code(language: "mermaid", code: "flowchart TD\n  A --> B"),
                .paragraph("Follow up next week."),
            ]
        )
    }

    func testEmptyStringYieldsNoBlocks() {
        XCTAssertEqual(MarkdownParser.parse(""), [])
        XCTAssertEqual(MarkdownParser.parse("   \n\n  "), [])
    }
}
