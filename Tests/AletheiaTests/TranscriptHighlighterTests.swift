import XCTest
@testable import Aletheia

final class TranscriptHighlighterTests: XCTestCase {
    private let transcript = """
    [00:00] Therapist: How was your week?
    [00:12] Client: Honestly, hard. I barely slept.
    [00:40] Therapist: Tell me about the sleep.
    """

    func testFindsAQuoteAndReturnsItsRange() {
        let spans = TranscriptHighlighter.spans(in: transcript, comments: [(id: "c1", quote: "barely slept", start: nil)])
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.commentID, "c1")
        let ns = transcript as NSString
        XCTAssertEqual(ns.substring(with: spans[0].range), "barely slept")
    }

    func testEmptyOrWhitespaceQuotesAreSkipped() {
        let spans = TranscriptHighlighter.spans(in: transcript, comments: [
            (id: "a", quote: "", start: nil),
            (id: "b", quote: "   ", start: nil),
        ])
        XCTAssertTrue(spans.isEmpty)
    }

    func testQuoteNotPresentIsSkippedRatherThanMisanchored() {
        let spans = TranscriptHighlighter.spans(in: transcript, comments: [(id: "a", quote: "not in the transcript", start: nil)])
        XCTAssertTrue(spans.isEmpty)
    }

    func testMultipleCommentsEachGetASpanInOrder() {
        let spans = TranscriptHighlighter.spans(in: transcript, comments: [
            (id: "a", quote: "How was your week", start: nil),
            (id: "b", quote: "Tell me about the sleep", start: nil),
        ])
        XCTAssertEqual(spans.map(\.commentID), ["a", "b"])
    }

    /// Ranges are NSString (UTF-16) offsets, so a quote after a multi-unit
    /// character must still slice back to the right substring.
    func testRangesAreUTF16CorrectAfterEmoji() {
        let text = "😀 the cat sat"
        let spans = TranscriptHighlighter.spans(in: text, comments: [(id: "a", quote: "cat", start: nil)])
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual((text as NSString).substring(with: spans[0].range), "cat")
    }

    func testQuoteIsTrimmedBeforeMatching() {
        let spans = TranscriptHighlighter.spans(in: transcript, comments: [(id: "a", quote: "  barely slept  ", start: nil)])
        XCTAssertEqual(spans.count, 1)
    }

    // MARK: - Position anchoring

    /// Every UTF-16 offset at which `needle` starts in `text`.
    private func offsets(of needle: String, in text: String) -> [Int] {
        let ns = text as NSString
        var found: [Int] = []
        var from = 0
        while from < ns.length {
            let r = ns.range(of: needle, options: [.literal], range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound { break }
            found.append(r.location)
            from = NSMaxRange(r)
        }
        return found
    }

    /// The reported bug: a speaker label appears on every line, so two comments
    /// on different "Therapist" labels used to both land on the first one.
    func testSameQuoteWithDifferentHintsResolvesToDifferentRanges() {
        let starts = offsets(of: "Therapist", in: transcript)
        XCTAssertEqual(starts.count, 2)
        let spans = TranscriptHighlighter.spans(in: transcript, comments: [
            (id: "a", quote: "Therapist", start: starts[0]),
            (id: "b", quote: "Therapist", start: starts[1]),
        ])
        XCTAssertEqual(spans.map(\.commentID), ["a", "b"])
        XCTAssertEqual(spans[0].range, NSRange(location: starts[0], length: 9))
        XCTAssertEqual(spans[1].range, NSRange(location: starts[1], length: 9))
        XCTAssertNotEqual(spans[0].range, spans[1].range)
    }

    func testExactHintIsUsed() {
        let starts = offsets(of: "Therapist", in: transcript)
        let range = TranscriptHighlighter.resolve(quote: "Therapist", hintStart: starts[1], in: transcript)
        XCTAssertEqual(range, NSRange(location: starts[1], length: 9))
    }

    /// The transcript was edited before the comment's passage, shifting it: the
    /// stored offset no longer holds the quote, so the nearest occurrence wins.
    func testStaleHintAfterInsertionPicksNearestOccurrence() {
        let hint = offsets(of: "Therapist", in: transcript)[1]
        let edited = "[00:00] Intro line added later.\n" + transcript
        let starts = offsets(of: "Therapist", in: edited)
        XCTAssertEqual(starts.count, 2)
        // The hint now points into different text, not at "Therapist".
        let ns = edited as NSString
        XCTAssertNotEqual(ns.substring(with: NSRange(location: hint, length: 9)), "Therapist")
        let range = TranscriptHighlighter.resolve(quote: "Therapist", hintStart: hint, in: edited)
        XCTAssertEqual(range, NSRange(location: starts[1], length: 9))
    }

    func testNearestOccurrenceAndTieBreak() {
        let text = "ab__ab___ab"   // "ab" at 0, 4, 9
        XCTAssertEqual(TranscriptHighlighter.resolve(quote: "ab", hintStart: 5, in: text), NSRange(location: 4, length: 2))
        XCTAssertEqual(TranscriptHighlighter.resolve(quote: "ab", hintStart: 8, in: text), NSRange(location: 9, length: 2))
        // Equidistant from 0 and 4: the earlier occurrence wins.
        XCTAssertEqual(TranscriptHighlighter.resolve(quote: "ab", hintStart: 2, in: text), NSRange(location: 0, length: 2))
    }

    func testHintOutOfBoundsFallsBackWithoutCrashing() {
        let expected = NSRange(location: offsets(of: "barely slept", in: transcript)[0], length: 12)
        XCTAssertEqual(TranscriptHighlighter.resolve(quote: "barely slept", hintStart: 10_000, in: transcript), expected)
        XCTAssertEqual(TranscriptHighlighter.resolve(quote: "barely slept", hintStart: -5, in: transcript), expected)
    }

    func testLegacyUniqueQuoteWithoutHintResolves() {
        let range = TranscriptHighlighter.resolve(quote: "barely slept", hintStart: nil, in: transcript)
        XCTAssertEqual(range, NSRange(location: offsets(of: "barely slept", in: transcript)[0], length: 12))
    }

    /// A legacy comment on a repeated word has no way to say which occurrence it
    /// meant, so it stays un-highlighted rather than guessing the first.
    func testLegacyDuplicatedQuoteWithoutHintIsNotAnchored() {
        XCTAssertNil(TranscriptHighlighter.resolve(quote: "Therapist", hintStart: nil, in: transcript))
        let spans = TranscriptHighlighter.spans(in: transcript, comments: [(id: "a", quote: "Therapist", start: nil)])
        XCTAssertTrue(spans.isEmpty)
    }

    func testHintedQuoteThatNoLongerExistsIsNotAnchored() {
        XCTAssertNil(TranscriptHighlighter.resolve(quote: "gone entirely", hintStart: 5, in: transcript))
    }

    func testUnplacedIDsListsQuotedCommentsWithoutASpan() {
        let starts = offsets(of: "Therapist", in: transcript)
        let unplaced = TranscriptHighlighter.unplacedIDs(in: transcript, comments: [
            (id: "placed", quote: "Therapist", start: starts[1]),
            (id: "legacyDuplicate", quote: "Therapist", start: nil),
            (id: "missing", quote: "not in the transcript", start: 3),
            (id: "general", quote: "", start: nil),
        ])
        XCTAssertEqual(unplaced, ["legacyDuplicate", "missing"])
    }

    func testOverlappingAndDuplicateRangesStayInBounds() {
        let start = offsets(of: "barely slept", in: transcript)[0]
        let spans = TranscriptHighlighter.spans(in: transcript, comments: [
            (id: "a", quote: "barely slept", start: start),
            (id: "b", quote: "barely slept", start: start),
            (id: "c", quote: "slept", start: start + 7),
        ])
        XCTAssertEqual(spans.count, 3)
        let length = (transcript as NSString).length
        for span in spans {
            XCTAssertTrue(NSMaxRange(span.range) <= length)
        }
    }

    // MARK: - Click resolution

    func testCommentAtIndexUsesPlacedRangesNotQuoteText() {
        let starts = offsets(of: "Therapist", in: transcript)
        let spans = TranscriptHighlighter.spans(in: transcript, comments: [
            (id: "a", quote: "Therapist", start: starts[0]),
            (id: "b", quote: "Therapist", start: starts[1]),
        ])
        XCTAssertEqual(TranscriptHighlighter.commentID(at: starts[0] + 2, in: spans), "a")
        XCTAssertEqual(TranscriptHighlighter.commentID(at: starts[1] + 2, in: spans), "b")
        XCTAssertNil(TranscriptHighlighter.commentID(at: starts[0] + 9, in: spans))
    }

    func testCommentAtIndexPrefersTheMostSpecificOverlap() {
        let start = offsets(of: "barely slept", in: transcript)[0]
        let spans = TranscriptHighlighter.spans(in: transcript, comments: [
            (id: "wide", quote: "barely slept", start: start),
            (id: "narrow", quote: "slept", start: start + 7),
        ])
        XCTAssertEqual(TranscriptHighlighter.commentID(at: start + 8, in: spans), "narrow")
        XCTAssertEqual(TranscriptHighlighter.commentID(at: start + 1, in: spans), "wide")
    }

    // MARK: - Focus requests

    /// Focus is an event: re-clicking the same comment bumps the token, so it
    /// scrolls again; a plain re-render (same token) must not.
    func testFocusRequestFiresOnTokenChangeEvenForTheSameComment() {
        XCTAssertTrue(TranscriptHighlighter.isNewFocusRequest(commentID: "a", token: 1, lastHandledToken: nil))
        XCTAssertFalse(TranscriptHighlighter.isNewFocusRequest(commentID: "a", token: 1, lastHandledToken: 1))
        XCTAssertTrue(TranscriptHighlighter.isNewFocusRequest(commentID: "a", token: 2, lastHandledToken: 1))
    }

    func testFocusRequestNeedsAFocusedComment() {
        XCTAssertFalse(TranscriptHighlighter.isNewFocusRequest(commentID: nil, token: 5, lastHandledToken: 4))
    }

    // MARK: - Selection trimming

    func testTrimmedDropsSurroundingWhitespaceFromASelection() {
        let text = "[00:00] Therapist: Hello.\n[00:05] Client: Hi."
        let ns = text as NSString
        let raw = ns.range(of: " Therapist: Hello.\n")
        let trimmed = TranscriptHighlighter.trimmed(raw, in: text)
        XCTAssertEqual(trimmed.map { ns.substring(with: $0) }, "Therapist: Hello.")
    }

    func testTrimmedRejectsEmptyOrOutOfBoundsRanges() {
        let text = "a  b"
        XCTAssertNil(TranscriptHighlighter.trimmed(NSRange(location: 1, length: 2), in: text))
        XCTAssertNil(TranscriptHighlighter.trimmed(NSRange(location: 0, length: 0), in: text))
        XCTAssertNil(TranscriptHighlighter.trimmed(NSRange(location: 2, length: 10), in: text))
    }
}
