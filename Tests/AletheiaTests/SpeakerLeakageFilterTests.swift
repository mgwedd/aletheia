import XCTest
@testable import Aletheia

final class SpeakerLeakageFilterTests: XCTestCase {
    private func mic(_ text: String, at start: TimeInterval) -> TranscribedLine {
        TranscribedLine(source: "Therapist", startTime: start, text: text)
    }

    private func call(_ text: String, at start: TimeInterval) -> TranscribedLine {
        TranscribedLine(source: "Call audio", startTime: start, text: text)
    }

    private let spoken = "So I have been feeling really overwhelmed at work lately."

    func testEchoOfCallLineIsDropped() {
        let result = SpeakerLeakageFilter.dropLeakedLines(
            mic: [mic("so I have been feeling really overwhelmed at work lately", at: 10.4)],
            call: [call(spoken, at: 10)]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testPartialEchoContainedInCallLineIsDropped() {
        let result = SpeakerLeakageFilter.dropLeakedLines(
            mic: [mic("feeling really overwhelmed at work", at: 11)],
            call: [call(spoken, at: 10)]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testPunctuationCaseAndApostrophesAreIgnored() {
        let result = SpeakerLeakageFilter.dropLeakedLines(
            mic: [mic("I dont know what to do.", at: 5)],
            call: [call("I DON'T know, what to do!", at: 5)]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testTherapistReflectionWithNewWordsIsKept() {
        // 7 of 11 words overlap in order (0.64), under the 0.8 threshold.
        let line = mic("It sounds like you have been feeling really overwhelmed at work", at: 11)
        let result = SpeakerLeakageFilter.dropLeakedLines(mic: [line], call: [call(spoken, at: 10)])
        XCTAssertEqual(result, [line])
    }

    func testUnrelatedTherapistSpeechIsKept() {
        let line = mic("Let's talk about how you have been sleeping this month", at: 10)
        let result = SpeakerLeakageFilter.dropLeakedLines(mic: [line], call: [call(spoken, at: 10)])
        XCTAssertEqual(result, [line])
    }

    func testShortLinesAreKeptEvenWhenIdentical() {
        let yes = mic("Yes, okay.", at: 10)
        let hmm = mic("Mm-hm, I see", at: 12)
        let result = SpeakerLeakageFilter.dropLeakedLines(
            mic: [yes, hmm],
            call: [call("Yes, okay.", at: 10), call("Mm-hm, I see", at: 12)]
        )
        XCTAssertEqual(result, [yes, hmm])
    }

    func testMinWordsIsConfigurable() {
        let result = SpeakerLeakageFilter.dropLeakedLines(
            mic: [mic("Yes, okay.", at: 10)],
            call: [call("Yes, okay.", at: 10)],
            minWords: 2
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testSameWordsFarApartInTimeAreKept() {
        let line = mic("so I have been feeling really overwhelmed at work lately", at: 40)
        let result = SpeakerLeakageFilter.dropLeakedLines(mic: [line], call: [call(spoken, at: 10)])
        XCTAssertEqual(result, [line])
    }

    func testTimeWindowBoundaryIsInclusive() {
        let text = "so I have been feeling really overwhelmed at work lately"
        let atEdge = SpeakerLeakageFilter.dropLeakedLines(mic: [mic(text, at: 15)], call: [call(spoken, at: 10)])
        XCTAssertTrue(atEdge.isEmpty)
        let pastEdge = SpeakerLeakageFilter.dropLeakedLines(mic: [mic(text, at: 15.1)], call: [call(spoken, at: 10)])
        XCTAssertEqual(pastEdge.count, 1)
    }

    func testNoCallLinesLeavesMicUntouched() {
        let lines = [mic("so I have been feeling really overwhelmed at work lately", at: 10)]
        XCTAssertEqual(SpeakerLeakageFilter.dropLeakedLines(mic: lines, call: []), lines)
    }

    func testEmptyMicYieldsEmpty() {
        XCTAssertTrue(SpeakerLeakageFilter.dropLeakedLines(mic: [], call: [call(spoken, at: 1)]).isEmpty)
    }

    func testOrderIsPreservedAndOnlyEchoesAreRemoved() {
        let first = mic("Thanks for coming in today, how has the week been", at: 2)
        let echo = mic("so I have been feeling really overwhelmed at work lately", at: 10.2)
        let last = mic("That sounds exhausting, tell me more about the deadlines", at: 20)
        let result = SpeakerLeakageFilter.dropLeakedLines(
            mic: [first, echo, last],
            call: [call(spoken, at: 10)]
        )
        XCTAssertEqual(result, [first, last])
    }

    func testEchoSpanningTwoCallLinesIsDropped() {
        let result = SpeakerLeakageFilter.dropLeakedLines(
            mic: [mic("so I have been feeling really overwhelmed at work lately and I cannot sleep", at: 10)],
            call: [
                call("So I have been feeling really overwhelmed", at: 9),
                call("at work lately and I cannot sleep.", at: 13),
            ]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testWordsNormalisation() {
        XCTAssertEqual(SpeakerLeakageFilter.words(in: "Don't STOP -- really?"), ["dont", "stop", "really"])
        XCTAssertEqual(SpeakerLeakageFilter.words(in: "  ... "), [])
    }
}
