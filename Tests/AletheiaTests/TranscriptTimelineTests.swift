import XCTest
@testable import Aletheia

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

    /// A repeated speaker label is why this exists: searching for the quote
    /// would always land on the first line, the offset lands on the right one.
    func testSecondsAtOffsetPicksTheLineContainingTheOffset() {
        let transcript = """
        [00:07] Therapist: How are you?
        [00:10] Therapist: Say more about that.
        [00:25] Client: Okay.
        """
        let ns = transcript as NSString
        let firstLabel = ns.range(of: "Therapist").location
        let secondLabel = ns.range(of: "Therapist", options: [], range: NSRange(location: firstLabel + 1, length: ns.length - firstLabel - 1)).location
        XCTAssertEqual(TranscriptTimeline.seconds(atOffset: firstLabel, in: transcript), 7)
        XCTAssertEqual(TranscriptTimeline.seconds(atOffset: secondLabel, in: transcript), 10)
        XCTAssertEqual(TranscriptTimeline.seconds(atOffset: ns.range(of: "Okay").location, in: transcript), 25)
    }

    func testSecondsAtOffsetBoundaries() {
        let transcript = "[00:07] a\n[00:10] b"
        // Start of the transcript, the newline ending line one, the start of
        // line two, and one past the end (a caret at the very end).
        XCTAssertEqual(TranscriptTimeline.seconds(atOffset: 0, in: transcript), 7)
        XCTAssertEqual(TranscriptTimeline.seconds(atOffset: 9, in: transcript), 7)
        XCTAssertEqual(TranscriptTimeline.seconds(atOffset: 10, in: transcript), 10)
        XCTAssertEqual(TranscriptTimeline.seconds(atOffset: (transcript as NSString).length, in: transcript), 10)
        XCTAssertNil(TranscriptTimeline.seconds(atOffset: -1, in: transcript))
        XCTAssertNil(TranscriptTimeline.seconds(atOffset: 999, in: transcript))
    }

    func testSecondsAtOffsetFallsBackToEarlierTimestampedLine() {
        let transcript = "[00:30] a\nhand-typed line\nanother"
        let offset = (transcript as NSString).range(of: "another").location
        XCTAssertEqual(TranscriptTimeline.seconds(atOffset: offset, in: transcript), 30)
        XCTAssertNil(TranscriptTimeline.seconds(atOffset: 0, in: "no time codes here"))
    }

    func testSecondsAtOffsetIsUTF16Correct() {
        let transcript = "[00:05] 😀 hi\n[00:09] bye"
        let offset = (transcript as NSString).range(of: "bye").location
        XCTAssertEqual(TranscriptTimeline.seconds(atOffset: offset, in: transcript), 9)
    }

    func testFormat() {
        XCTAssertEqual(TranscriptTimeline.format(15), "0:15")
        XCTAssertEqual(TranscriptTimeline.format(125), "2:05")
        XCTAssertEqual(TranscriptTimeline.format(3723), "1:02:03")
        XCTAssertEqual(TranscriptTimeline.format(-5), "0:00")
    }
}
