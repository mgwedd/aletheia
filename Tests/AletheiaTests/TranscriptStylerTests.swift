import XCTest
@testable import Aletheia

final class TranscriptStylerTests: XCTestCase {
    func testTimestampAndSpeakerOnATypicalLine() {
        let spans = TranscriptStyler.spans(in: "[00:16] Therapist: - No problem.")
        XCTAssertEqual(spans, [
            TranscriptStyler.Span(range: NSRange(location: 0, length: 7), role: .timestamp),
            TranscriptStyler.Span(range: NSRange(location: 8, length: 9), role: .speaker("Therapist")),
        ])
    }

    func testOverlappingSuffixIsNotPartOfTheSpeaker() {
        let text = "[01:03] Call audio (overlapping): I wrote it down."
        let spans = TranscriptStyler.spans(in: text)
        XCTAssertEqual(spans.count, 2)
        XCTAssertEqual(spans[1].role, .speaker("Call audio"))
        XCTAssertEqual(spans[1].range, NSRange(location: 8, length: 10))
    }

    func testEveryLineIsStyledWithItsOwnOffsets() {
        let text = "[00:14] Therapist: Hi.\n[00:29] Call audio: Hello."
        let spans = TranscriptStyler.spans(in: text)
        XCTAssertEqual(spans.map(\.role), [
            .timestamp, .speaker("Therapist"), .timestamp, .speaker("Call audio"),
        ])
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: spans[2].range), "[00:29]")
        XCTAssertEqual(ns.substring(with: spans[3].range), "Call audio")
    }

    func testLongSessionTimestampsAndHourForm() {
        XCTAssertEqual(TranscriptStyler.spans(in: "[62:03] Therapist: x").first?.range.length, 7)
        XCTAssertEqual(TranscriptStyler.spans(in: "[1:02:03] Therapist: x").first?.range.length, 9)
    }

    func testOnlyLineStartsAreStyled() {
        XCTAssertTrue(TranscriptStyler.spans(in: "she said [00:16] Therapist: hi").isEmpty)
        XCTAssertTrue(TranscriptStyler.spans(in: "plain text with no markers").isEmpty)
    }

    func testHalfTypedLinesGetNoStylingOrOnlyTheTimestamp() {
        XCTAssertTrue(TranscriptStyler.spans(in: "[00:1 Therapist: x").isEmpty)
        // A time stamp without a speaker label: the stamp is still styled.
        let spans = TranscriptStyler.spans(in: "[00:16] no label here")
        XCTAssertEqual(spans.map(\.role), [.timestamp])
    }

    func testToneByLabel() {
        XCTAssertEqual(TranscriptStyler.tone(for: "Therapist"), .therapist)
        XCTAssertEqual(TranscriptStyler.tone(for: "Call audio"), .callAudio)
        XCTAssertEqual(TranscriptStyler.tone(for: " call AUDIO "), .callAudio)
        XCTAssertEqual(TranscriptStyler.tone(for: "Jordan"), .other)
    }

    func testStylingNeverChangesTheText() {
        // Spans only point into the text; none may run past it.
        let text = "[00:14] Therapist: Hi.\n[00:29] Call audio (overlapping): Hello.\n"
        let length = (text as NSString).length
        for span in TranscriptStyler.spans(in: text) {
            XCTAssertLessThanOrEqual(NSMaxRange(span.range), length)
        }
    }
}
