import XCTest
@testable import Aletheia

final class SpeakerLeakageFilterTests: XCTestCase {
    private func mic(_ text: String, at start: TimeInterval) -> TranscribedLine {
        TranscribedLine(source: "Therapist", startTime: start, endTime: start + 1, text: text)
    }

    private func call(_ text: String, at start: TimeInterval) -> TranscribedLine {
        TranscribedLine(source: "Call audio", startTime: start, endTime: start + 1, text: text)
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

    /// A real speaker-bleed recording: one voice on the call track, echoed
    /// into the mic. The tracks are cut at different points and differ in a
    /// few words ("ECMA 335" / "ECMA335", "12" / "12th", an extra "Well").
    func testRealSpeakerBleedIsDroppedAndTherapistSpeechOverItIsKept() {
        let callLines = [
            call("binaries you can get your hands on. We're talking stripped-elf, PE and mako executables, JVM bytecode with obfuscated constant pools,", at: 15),
            call("ECMA335-compliant .NET assemblies, bare-metal firmware with architecture-specific instruction", at: 22),
            call("sets, and even OCI container layers entangled in declarative infrastructure manifests.", at: 28),
            call("It is October 12th, 2026, and you're watching The Code Report.", at: 45),
            call("So is it really true that one person plus Claude made the entire Adobe suite obsolete", at: 48),
            call("overnight? On the surface, yes, as you can see on the website, you can download a Rust-based version", at: 53),
        ]
        let therapist = mic("Sorry to interrupt, can you tell me more about that", at: 25)
        let result = SpeakerLeakageFilter.dropLeakedLines(
            mic: [
                mic("PE and Mako executables, JVM bytecode with obfuscated constant pools, ECMA 335 compliant", at: 18),
                mic(".NET assemblies, bare metal firmware with architecture-specific instruction sets,", at: 24),
                therapist,
                mic("and even OCI container layers entangled in declarative infrastructure manifests.", at: 28),
                mic("It is October 12, 2026, and you're watching the code report. So is it really true that", at: 44),
                mic("one person plus Claude made the entire Adobe suite obsolete overnight? Well, on the surface,", at: 50),
            ],
            call: callLines
        )
        XCTAssertEqual(result, [therapist])
    }
}
