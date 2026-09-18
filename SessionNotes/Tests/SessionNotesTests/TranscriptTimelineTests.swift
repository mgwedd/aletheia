import XCTest
@testable import SessionNotes

final class TranscriptTimelineTests: XCTestCase {
    func testLeadingSecondsMinuteSecond() {
        XCTAssertEqual(TranscriptTimeline.leadingSeconds(of: "[00:15] Therapist: Hi there."), 15)
        XCTAssertEqual(TranscriptTimeline.leadingSeconds(of: "[02:05] Call audio: Hello."), 125)
    }

    func testLeadingSecondsMinutesPastSixty() {
        // The transcriber emits MM:SS where MM can exceed 59 on a long session.
        XCTAssertEqual(TranscriptTimeline.leadingSeconds(of: "[75:12] Therapist: ..."), 75 * 60 + 12)
    }

    func testLeadingSecondsHourForm() {
        XCTAssertEqual(TranscriptTimeline.leadingSeconds(of: "[1:02:03] Therapist: ..."), 3723)
    }

    func testLeadingSecondsIgnoresLeadingWhitespace() {
        XCTAssertEqual(TranscriptTimeline.leadingSeconds(of: "   [00:30] x"), 30)
    }

    func testLeadingSecondsNilForUntimestampedLine() {
        XCTAssertNil(TranscriptTimeline.leadingSeconds(of: "Therapist: no time code here"))
        XCTAssertNil(TranscriptTimeline.leadingSeconds(of: ""))
        XCTAssertNil(TranscriptTimeline.leadingSeconds(of: "[notatime] x"))
    }

    func testSecondsForQuotePicksContainingLine() {
        let transcript = """
        [00:00] Therapist: How was your week?
        [00:12] Call audio: Honestly, hard. I barely slept.
        [00:40] Therapist: Tell me about the sleep.
        """
        XCTAssertEqual(TranscriptTimeline.seconds(forQuote: "barely slept", in: transcript), 12)
        XCTAssertEqual(TranscriptTimeline.seconds(forQuote: "Tell me about the sleep", in: transcript), 40)
        XCTAssertEqual(TranscriptTimeline.seconds(forQuote: "How was your week", in: transcript), 0)
    }

    func testSecondsForQuoteNilWhenNotFound() {
        let transcript = "[00:00] Therapist: Hello."
        XCTAssertNil(TranscriptTimeline.seconds(forQuote: "not in the transcript", in: transcript))
        XCTAssertNil(TranscriptTimeline.seconds(forQuote: "   ", in: transcript))
    }

    func testFormat() {
        XCTAssertEqual(TranscriptTimeline.format(15), "0:15")
        XCTAssertEqual(TranscriptTimeline.format(125), "2:05")
        XCTAssertEqual(TranscriptTimeline.format(3723), "1:02:03")
        XCTAssertEqual(TranscriptTimeline.format(-5), "0:00")
    }
}
