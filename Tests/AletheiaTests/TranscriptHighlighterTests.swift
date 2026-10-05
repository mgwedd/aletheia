import XCTest
@testable import Aletheia

final class TranscriptHighlighterTests: XCTestCase {
    private let transcript = """
    [00:00] Therapist: How was your week?
    [00:12] Client: Honestly, hard. I barely slept.
    [00:40] Therapist: Tell me about the sleep.
    """

    func testFindsAQuoteAndReturnsItsRange() {
        let spans = TranscriptHighlighter.spans(in: transcript, comments: [(id: "c1", quote: "barely slept")])
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.commentID, "c1")
        let ns = transcript as NSString
        XCTAssertEqual(ns.substring(with: spans[0].range), "barely slept")
    }

    func testEmptyOrWhitespaceQuotesAreSkipped() {
        let spans = TranscriptHighlighter.spans(in: transcript, comments: [
            (id: "a", quote: ""),
            (id: "b", quote: "   "),
        ])
        XCTAssertTrue(spans.isEmpty)
    }

    func testQuoteNotPresentIsSkippedRatherThanMisanchored() {
        let spans = TranscriptHighlighter.spans(in: transcript, comments: [(id: "a", quote: "not in the transcript")])
        XCTAssertTrue(spans.isEmpty)
    }

    func testMultipleCommentsEachGetASpanInOrder() {
        let spans = TranscriptHighlighter.spans(in: transcript, comments: [
            (id: "a", quote: "How was your week"),
            (id: "b", quote: "Tell me about the sleep"),
        ])
        XCTAssertEqual(spans.map(\.commentID), ["a", "b"])
    }

    /// Ranges are NSString (UTF-16) offsets, so a quote after a multi-unit
    /// character must still slice back to the right substring.
    func testRangesAreUTF16CorrectAfterEmoji() {
        let text = "😀 the cat sat"
        let spans = TranscriptHighlighter.spans(in: text, comments: [(id: "a", quote: "cat")])
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual((text as NSString).substring(with: spans[0].range), "cat")
    }

    func testQuoteIsTrimmedBeforeMatching() {
        let spans = TranscriptHighlighter.spans(in: transcript, comments: [(id: "a", quote: "  barely slept  ")])
        XCTAssertEqual(spans.count, 1)
    }
}
