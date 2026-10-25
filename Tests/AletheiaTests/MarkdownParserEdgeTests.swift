import XCTest
@testable import Aletheia

/// The parts of document assembly the basic parser tests leave open: fence
/// matching rules, what interrupts a paragraph, near-miss markers that must stay
/// prose, and that a note's words are never lost on the way to the screen.
final class MarkdownParserEdgeTests: XCTestCase {
    private func parse(_ lines: String...) -> [MarkdownBlock] { MarkdownParser.parse(lines.joined(separator: "\n")) }

    // MARK: Fences

    func testTildeFencesWorkAndABacktickFenceDoesNotCloseThem() {
        XCTAssertEqual(
            parse("~~~swift", "let x = 1", "```", "~~~", "after"),
            [.code(language: "swift", code: "let x = 1\n```"), .paragraph("after")])
    }

    func testAShorterFenceDoesNotCloseALongerOne() {
        XCTAssertEqual(
            parse("````", "```", "inside", "````"),
            [.code(language: nil, code: "```\ninside")])
    }

    func testAFenceWithAnInfoStringDoesNotCloseABlock() {
        XCTAssertEqual(
            parse("```", "a", "```js", "b", "```"),
            [.code(language: nil, code: "a\n```js\nb")])
    }

    func testTwoBackticksAreProse() {
        XCTAssertEqual(parse("``not a fence``"), [.paragraph("``not a fence``")])
    }

    func testMarkdownInsideACodeBlockStaysLiteral() {
        XCTAssertEqual(
            parse("```", "# not a heading", "- not a bullet", "```"),
            [.code(language: nil, code: "# not a heading\n- not a bullet")])
    }

    func testTheLanguageIsLowercasedAndOnlyMermaidIsMermaid() {
        XCTAssertEqual(parse("```Mermaid", "graph TD", "```").first?.isMermaid, true)
        XCTAssertEqual(parse("```python", "x", "```").first?.isMermaid, false)
        XCTAssertFalse(MarkdownBlock.paragraph("mermaid").isMermaid)
    }

    // MARK: Near misses stay prose

    func testMarkersWithoutTheirSpaceAreProse() {
        XCTAssertEqual(parse("-item"), [.paragraph("-item")])
        XCTAssertEqual(parse("1.5 mg daily"), [.paragraph("1.5 mg daily")])
        XCTAssertEqual(parse("1) ok"), [.numbered(["ok"])])
        XCTAssertEqual(parse(">quote"), [.paragraph(">quote")])
        XCTAssertEqual(parse("# "), [.paragraph("#")], "a heading with no text is not a heading")
    }

    func testAVeryLongNumberIsNotAListMarker() {
        XCTAssertEqual(parse("1234567890. item"), [.paragraph("1234567890. item")])
    }

    func testRulesNeedThreeMatchingCharacters() {
        XCTAssertEqual(parse("--"), [.paragraph("--")])
        XCTAssertEqual(parse("* * *"), [.rule])
        XCTAssertEqual(parse("___"), [.rule])
        XCTAssertEqual(parse("-*-"), [.paragraph("-*-")])
    }

    // MARK: What interrupts what

    func testBlocksInterruptAParagraphWithoutAnyBlankLine() {
        XCTAssertEqual(
            parse("intro", "## Plan", "next", "- a", "> q", "---", "tail"),
            [.paragraph("intro"), .heading(level: 2, text: "Plan"), .paragraph("next"),
             .bulleted(["a"]), .quote(["q"]), .rule, .paragraph("tail")])
    }

    func testABlankLineSplitsAListIntoTwo() {
        XCTAssertEqual(parse("- a", "", "- b"), [.bulleted(["a"]), .bulleted(["b"])])
    }

    func testABulletListFollowedByANumberedListStaysTwoBlocks() {
        XCTAssertEqual(parse("- a", "1. b"), [.bulleted(["a"]), .numbered(["b"])])
    }

    func testAnEmptyQuoteLineIsKeptInsideTheQuote() {
        XCTAssertEqual(parse("> a", ">", "> b"), [.quote(["a", "", "b"])])
    }

    func testIndentedMarkersStillCount() {
        XCTAssertEqual(parse("   # Title", "   - item"), [.heading(level: 1, text: "Title"), .bulleted(["item"])])
    }

    // MARK: Streaming and completeness

    private let document = """
    # Summary
    The patient *reported* improved sleep.

    - slept 7 hours
    - fewer nightmares

    1. continue plan
    2. review in two weeks

    > "I feel lighter"

    ```mermaid
    graph TD; A-->B
    ```
    ---
    Closing remarks.
    """

    func testEveryPrefixOfADocumentParsesWithoutLosingTheTextSoFar() {
        for end in document.indices {
            let prefix = String(document[...end])
            let blocks = MarkdownParser.parse(prefix)
            // A list marker is structure the renderer redraws, not text.
            // A code fence's language is a label, not content, even while it is half typed.
            let withoutMarkers = prefix
                .replacingOccurrences(of: #"(?m)^\s*\d+[.)](\s|$)"#, with: "", options: .regularExpression)
                .replacingOccurrences(of: #"(?m)^```\w*"#, with: "", options: .regularExpression)
            let words = withoutMarkers.split { !$0.isLetter && !$0.isNumber }.map(String.init)
            let rendered = blocks.map(Self.text).joined(separator: " ")
            for word in words {
                XCTAssertTrue(rendered.contains(word), "'\(word)' was dropped from a partial document ending \(prefix.suffix(12))")
            }
        }
    }

    func testTheWholeDocumentKeepsItsOrderAndShape() {
        XCTAssertEqual(MarkdownParser.parse(document), [
            .heading(level: 1, text: "Summary"),
            .paragraph("The patient *reported* improved sleep."),
            .bulleted(["slept 7 hours", "fewer nightmares"]),
            .numbered(["continue plan", "review in two weeks"]),
            .quote(["\"I feel lighter\""]),
            .code(language: "mermaid", code: "graph TD; A-->B"),
            .rule,
            .paragraph("Closing remarks."),
        ])
    }

    func testWindowsLineEndingsInsideCodeAreNormalized() {
        XCTAssertEqual(MarkdownParser.parse("```\r\na\r\nb\r\n```"), [.code(language: nil, code: "a\nb")])
    }

    private static func text(_ block: MarkdownBlock) -> String {
        switch block {
        case let .heading(_, text), let .paragraph(text): return text
        case let .bulleted(items), let .numbered(items), let .quote(items): return items.joined(separator: " ")
        case let .code(_, code): return code
        case .rule: return ""
        }
    }
}
