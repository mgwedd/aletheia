import XCTest
@testable import Aletheia

/// An answer's text is one selectable run, with code set apart as a card.
final class AnswerTextTests: XCTestCase {
    private let look = AnswerText.Look(size: 15, lineSpacing: 0, blockSpacing: 8, listSpacing: 4, ink: Theme.text)

    func testProseBlocksFormOneRun() {
        let blocks = MarkdownParser.parse("## Sleep\nPoor.\n\n- Wakes at 3am\n1. Naps\n\n> Tired.")
        let segments = AnswerText.segments(blocks)
        XCTAssertEqual(segments.count, 1)
        guard case let .prose(run)? = segments.first else { return XCTFail("not prose: \(segments)") }
        let text = AnswerText.attributed(run, look: look).string
        for piece in ["Sleep", "Poor.", "•\tWakes at 3am", "1.\tNaps", "Tired."] {
            XCTAssertTrue(text.contains(piece), "missing \(piece) in \(text)")
        }
    }

    func testCodeSplitsTheRun() {
        let segments = AnswerText.segments(MarkdownParser.parse("Before.\n\n```\nlet x = 1\n```\n\nAfter."))
        XCTAssertEqual(segments.count, 3)
        if case .card = segments[1] {} else { XCTFail("code is not a card: \(segments)") }
    }

    func testInlineMarkupIsDropped() {
        let text = AnswerText.attributed(MarkdownParser.parse("She is **very** tired."), look: look).string
        XCTAssertEqual(text, "She is very tired.")
    }
}
