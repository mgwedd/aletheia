import XCTest
@testable import Aletheia

/// The " (overlapping)" label stays in the stored transcript (offsets, comment
/// anchors and the model's `~` hint all depend on it) but is never shown or
/// exported. Synthetic text.
final class TranscriptOverlapLabelTests: XCTestCase {
    private let stored = """
    [00:10] You (overlapping): Let me finish.
    [00:12] Call audio (overlapping): But I think so.
    [00:20] Call audio: Fine, go on.
    """

    func testRemovingLabelsKeepsEverythingElse() {
        XCTAssertEqual(TranscriptStyler.removingOverlapLabels(stored), """
        [00:10] You: Let me finish.
        [00:12] Call audio: But I think so.
        [00:20] Call audio: Fine, go on.
        """)
    }

    func testRemovingLabelsLeavesSpokenTextAlone() {
        // Only the label position counts, not the same words said aloud.
        let text = "[00:01] You: I said (overlapping): twice.\n[00:02] You (overlapping): ok"
        XCTAssertEqual(
            TranscriptStyler.removingOverlapLabels(text),
            "[00:01] You: I said (overlapping): twice.\n[00:02] You: ok")
    }

    func testTextWithoutLabelsIsReturnedUnchanged() {
        let text = "[00:01] You: hi\nfree text"
        XCTAssertEqual(TranscriptStyler.removingOverlapLabels(text), text)
    }

    /// The view hides exactly the ranges the styler tags, and those are the
    /// suffix and nothing else.
    func testHiddenRangesAreExactlyTheSuffixes() {
        let ns = stored as NSString
        let tags = TranscriptStyler.spans(in: stored).filter { $0.role == .overlapTag }
        XCTAssertEqual(tags.count, 2)
        for tag in tags { XCTAssertEqual(ns.substring(with: tag.range), " (overlapping)") }
    }

    /// Anchors resolve against the stored text, so they land on the same quoted
    /// passage whether or not the view hides the label.
    func testCommentAnchorsStillResolveOnOverlappingLines() {
        let ns = stored as NSString
        let quote = "But I think so."
        let start = ns.range(of: quote).location
        let spans = TranscriptHighlighter.spans(in: stored, comments: [
            (id: "a", quote: quote, start: start),
            (id: "b", quote: "Let me finish", start: nil),
            (id: "c", quote: "Fine, go on.", start: ns.range(of: "Fine").location),
        ])
        XCTAssertEqual(spans.map { ns.substring(with: $0.range) }, [quote, "Let me finish", "Fine, go on."])
        XCTAssertEqual(spans[0].range.location, start)
    }

    func testSearchFocusStillFindsTheMatchOnAnOverlappingLine() {
        let range = SearchMatchFocus(query: "think", passage: 1).transcriptRange(in: stored)
        XCTAssertEqual(range.map { (stored as NSString).substring(with: $0) }, "think")
    }

    func testFormatterStillWritesTheSuffixAndCompactorStillEmitsTheHint() {
        let formatted = TranscriptFormatter.format([
            TranscribedLine(source: "You", startTime: 10, endTime: 16, text: "Let me finish."),
            TranscribedLine(source: "Call audio", startTime: 12, endTime: 18, text: "But I think so."),
        ])
        XCTAssertTrue(formatted.contains("(overlapping)"))
        let compact = TranscriptCompactor.compact(formatted)
        XCTAssertTrue(compact.contains("Y~:"))
        XCTAssertTrue(compact.contains("C~:"))
        XCTAssertFalse(compact.contains("(overlapping)"))
        // Nothing the reader sees or exports has the label.
        XCTAssertFalse(TranscriptStyler.removingOverlapLabels(formatted).contains("overlapping"))
    }

    func testMarkdownExportDropsTheLabel() {
        let md = MarkdownExporter.session(date: Date(), patientName: "Jane Doe", transcript: stored, summary: nil)
        XCTAssertFalse(md.contains("overlapping"))
        XCTAssertTrue(md.contains("[00:12] Jane: But I think so."))
    }
}
