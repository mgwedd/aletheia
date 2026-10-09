import XCTest
@testable import Aletheia

final class TranscriptCleanerTests: XCTestCase {
    /// `end` defaults to one second after `start`.
    private func line(
        _ text: String,
        at start: TimeInterval,
        end: TimeInterval? = nil,
        source: String = "Therapist"
    ) -> TranscribedLine {
        TranscribedLine(source: source, startTime: start, endTime: end ?? start + 1, text: text)
    }

    func testBlankAudioTagIsDropped() {
        XCTAssertTrue(TranscriptCleaner.clean([line("[BLANK_AUDIO]", at: 0)]).isEmpty)
        XCTAssertTrue(TranscriptCleaner.clean([line(" [blank_audio] ", at: 0)]).isEmpty)
    }

    func testSilenceTagWithPaddingIsDropped() {
        XCTAssertTrue(TranscriptCleaner.clean([line("[ Silence ]", at: 20)]).isEmpty)
    }

    func testSplitTagIsRejoinedAndDropped() {
        let cleaned = TranscriptCleaner.clean([
            line("[", at: 0),
            line("static ]", at: 8),
            line("All right, I am testing the transcription features.", at: 10),
        ])
        XCTAssertEqual(cleaned.map(\.text), ["All right, I am testing the transcription features."])
        XCTAssertEqual(cleaned.first?.startTime, 10)
    }

    func testParenthesizedAndAsteriskAnnotationsAreDropped() {
        XCTAssertTrue(TranscriptCleaner.clean([line("(static)", at: 0)]).isEmpty)
        XCTAssertTrue(TranscriptCleaner.clean([line("*sigh*", at: 0)]).isEmpty)
        XCTAssertTrue(TranscriptCleaner.clean([line("[MUSIC] (applause)", at: 0)]).isEmpty)
    }

    func testPunctuationOnlySegmentIsDropped() {
        XCTAssertTrue(TranscriptCleaner.clean([line(" ... ", at: 0), line("   ", at: 5)]).isEmpty)
    }

    func testSpeechWithParentheticalIsKept() {
        let cleaned = TranscriptCleaner.clean([line("I felt (honestly) tired", at: 3)])
        XCTAssertEqual(cleaned.map(\.text), ["I felt (honestly) tired"])
    }

    func testUnclosedTagWithoutCloserIsLeftAlone() {
        let cleaned = TranscriptCleaner.clean([line("I think (maybe", at: 0), line("we should go.", at: 30)])
        XCTAssertEqual(cleaned.map(\.text), ["I think (maybe", "we should go."])
    }

    func testLinesWithinTwoSecondsAreCoalesced() {
        let cleaned = TranscriptCleaner.clean([
            line("I was thinking", at: 10),
            line("about last week.", at: 11.5),
        ])
        XCTAssertEqual(cleaned.count, 1)
        XCTAssertEqual(cleaned.first?.text, "I was thinking about last week.")
        XCTAssertEqual(cleaned.first?.startTime, 10)
    }

    func testLinesBeyondTwoSecondsAreNotCoalesced() {
        let cleaned = TranscriptCleaner.clean([
            line("First thought.", at: 10),
            line("Second thought.", at: 12.5),
        ])
        XCTAssertEqual(cleaned.map(\.text), ["First thought.", "Second thought."])
    }

    func testDifferentSourcesAreNotCoalesced() {
        let cleaned = TranscriptCleaner.clean([
            line("How are you?", at: 10, source: "Therapist"),
            line("Fine, thanks.", at: 11, source: "Call audio"),
        ])
        XCTAssertEqual(cleaned.count, 2)
        XCTAssertEqual(Set(cleaned.map(\.source)), ["Therapist", "Call audio"])
    }

    func testTurnMarkerPreventsCoalescingWithinWindow() {
        let cleaned = TranscriptCleaner.clean([
            line("- Hello, how are you doing today?", at: 10),
            line("- Hey, honey.", at: 12),
        ])
        XCTAssertEqual(cleaned.map(\.text), ["- Hello, how are you doing today?", "- Hey, honey."])
        XCTAssertEqual(cleaned.map(\.startTime), [10, 12])
    }

    func testTurnMarkerWithSurroundingWhitespaceIsDetected() {
        let cleaned = TranscriptCleaner.clean([
            line("Hello there.", at: 10),
            line("  - Hi.  ", at: 11),
        ])
        XCTAssertEqual(cleaned.map(\.text), ["Hello there.", "- Hi."])
    }

    func testFirstLineMarkerIsKeptUnchanged() {
        let cleaned = TranscriptCleaner.clean([line("- Hello.", at: 0)])
        XCTAssertEqual(cleaned.map(\.text), ["- Hello."])
    }

    func testNonMarkerLineMergesIntoMarkerLine() {
        let cleaned = TranscriptCleaner.clean([
            line("- Hello, how are you", at: 10),
            line("doing today?", at: 11),
        ])
        XCTAssertEqual(cleaned.map(\.text), ["- Hello, how are you doing today?"])
    }

    func testNegativeNumberAndHyphenatedWordAreNotMarkers() {
        let cleaned = TranscriptCleaner.clean([
            line("It dropped to", at: 10),
            line("-5 degrees", at: 11),
            line("-ish", at: 12),
        ])
        XCTAssertEqual(cleaned.map(\.text), ["It dropped to -5 degrees -ish"])
    }

    func testMarkerLineAbsorbsFollowingCloseLine() {
        let cleaned = TranscriptCleaner.clean([
            line("- Hello.", at: 10),
            line("- Hey, honey.", at: 11),
            line("How was your day?", at: 12),
        ])
        XCTAssertEqual(cleaned.map(\.text), ["- Hello.", "- Hey, honey. How was your day?"])
        XCTAssertEqual(cleaned.map(\.startTime), [10, 11])
    }

    func testMarkerAfterDroppedNonSpeechIsStillDetected() {
        let cleaned = TranscriptCleaner.clean([
            line("Hello.", at: 10),
            line("[BLANK_AUDIO]", at: 11),
            line(" - Hey.", at: 11.5),
        ])
        XCTAssertEqual(cleaned.map(\.text), ["Hello.", "- Hey."])
    }

    func testMarkersOnDifferentSourcesAreUnaffected() {
        let cleaned = TranscriptCleaner.clean([
            line("- How are you?", at: 10, source: "Therapist"),
            line("- Fine, thanks.", at: 11, source: "Call audio"),
            line("and you?", at: 12, source: "Call audio"),
        ])
        XCTAssertEqual(cleaned.count, 2)
        XCTAssertEqual(cleaned.first { $0.source == "Therapist" }?.text, "- How are you?")
        XCTAssertEqual(cleaned.first { $0.source == "Call audio" }?.text, "- Fine, thanks. and you?")
    }

    // MARK: - Cross-source timeline coalescing

    func testInterjectionSplitsLongTurn() {
        let cleaned = TranscriptCleaner.clean([
            line("I was saying", at: 10),
            line("that things got hard", at: 11.5),
            line("and then work piled up.", at: 13),
            line("Mm-hm.", at: 12, source: "Call audio"),
        ])
        XCTAssertEqual(cleaned.map(\.source), ["Therapist", "Call audio", "Therapist"])
        XCTAssertEqual(cleaned.map(\.text), [
            "I was saying that things got hard",
            "Mm-hm.",
            "and then work piled up.",
        ])
        XCTAssertEqual(cleaned.map(\.startTime), [10, 12, 13])
    }

    func testTurnResumedAfterInterjectionCoalescesAgain() {
        let cleaned = TranscriptCleaner.clean([
            line("One", at: 10),
            line("two", at: 11),
            line("Right.", at: 11.5, source: "Call audio"),
            line("three", at: 12),
            line("four", at: 13),
        ])
        XCTAssertEqual(cleaned.map(\.text), ["One two", "Right.", "three four"])
    }

    func testOtherSourceBeforeOrAfterTurnDoesNotSplitIt() {
        let cleaned = TranscriptCleaner.clean([
            line("Before.", at: 9, source: "Call audio"),
            line("I was thinking", at: 10),
            line("about last week.", at: 11.5),
            line("After.", at: 20, source: "Call audio"),
        ])
        XCTAssertEqual(cleaned.map(\.text), ["Before.", "I was thinking about last week.", "After."])
    }

    func testCoalescingStillWorksForBothSourcesWithoutInterjection() {
        let cleaned = TranscriptCleaner.clean([
            line("How are", at: 10),
            line("you today?", at: 11),
            line("Fine,", at: 20, source: "Call audio"),
            line("thanks.", at: 21, source: "Call audio"),
        ])
        XCTAssertEqual(cleaned.map(\.text), ["How are you today?", "Fine, thanks."])
    }

    func testTurnMarkerStillRespectedWithOtherSourcePresent() {
        let cleaned = TranscriptCleaner.clean([
            line("- Hello.", at: 10),
            line("- Hey, honey.", at: 11),
            line("Yes.", at: 30, source: "Call audio"),
        ])
        XCTAssertEqual(cleaned.map(\.text), ["- Hello.", "- Hey, honey.", "Yes."])
    }

    func testMergedLineKeepsFirstStartAndLastEnd() {
        let cleaned = TranscriptCleaner.clean([
            line("First", at: 10, end: 11),
            line("second", at: 11, end: 14.5),
        ])
        XCTAssertEqual(cleaned.count, 1)
        XCTAssertEqual(cleaned.first?.startTime, 10)
        XCTAssertEqual(cleaned.first?.endTime, 14.5)
    }

    func testRejoinedTagTakesEndOfLastJoinedSegment() {
        let cleaned = TranscriptCleaner.clean([
            line("(maybe", at: 10, end: 11),
            line("later) we go", at: 12, end: 13),
        ])
        XCTAssertEqual(cleaned.count, 1)
        XCTAssertEqual(cleaned.first?.text, "(maybe later) we go")
        XCTAssertEqual(cleaned.first?.endTime, 13)
    }

    func testOutputIsSortedByStartTimeAcrossSources() {
        let cleaned = TranscriptCleaner.clean([
            line("Late.", at: 50),
            line("Early.", at: 5),
            line("Middle.", at: 25, source: "Call audio"),
        ])
        XCTAssertEqual(cleaned.map(\.text), ["Early.", "Middle.", "Late."])
    }

    func testEqualStartTimesOrderBySourceFirstAppearance() {
        let callFirst = TranscriptCleaner.clean([
            line("From call.", at: 5, source: "Call audio"),
            line("From mic.", at: 5, source: "Therapist"),
        ])
        XCTAssertEqual(callFirst.map(\.source), ["Call audio", "Therapist"])

        let micFirst = TranscriptCleaner.clean([
            line("From mic.", at: 5, source: "Therapist"),
            line("From call.", at: 5, source: "Call audio"),
        ])
        XCTAssertEqual(micFirst.map(\.source), ["Therapist", "Call audio"])
    }

    func testEqualStartTimesInOneSourceKeepInputOrder() {
        let ordered = TranscriptCleaner.timeOrdered([
            line("- one", at: 5),
            line("- two", at: 5),
            line("- three", at: 5),
        ])
        XCTAssertEqual(ordered.map(\.text), ["- one", "- two", "- three"])
    }

    func testCleanIsDeterministic() {
        let input = [
            line("a", at: 1, source: "Call audio"),
            line("b", at: 1),
            line("- c", at: 1, source: "Call audio"),
            line("- d", at: 1),
        ]
        let first = TranscriptCleaner.clean(input)
        for _ in 0..<20 {
            XCTAssertEqual(TranscriptCleaner.clean(input), first)
        }
    }

    func testAllJunkInputYieldsEmpty() {
        let cleaned = TranscriptCleaner.clean([
            line("[", at: 0),
            line("static ]", at: 8),
            line("[BLANK_AUDIO]", at: 10, source: "Call audio"),
            line("[ Silence ]", at: 20, source: "Call audio"),
            line("", at: 30),
        ])
        XCTAssertTrue(cleaned.isEmpty)
    }

    // MARK: - AudioResampler.isEssentiallySilent

    func testEmptySamplesAreSilent() {
        XCTAssertTrue(AudioResampler.isEssentiallySilent([]))
    }

    func testZeroSamplesAreSilent() {
        XCTAssertTrue(AudioResampler.isEssentiallySilent([Float](repeating: 0, count: 16000)))
    }

    func testLoudSamplesAreNotSilent() {
        let loud = (0..<16000).map { Float(sin(Double($0) * 0.05)) * 0.5 }
        XCTAssertFalse(AudioResampler.isEssentiallySilent(loud))
    }

    func testQuietSpeechLevelIsNotSilent() {
        XCTAssertFalse(AudioResampler.isEssentiallySilent([Float](repeating: 0.01, count: 16000)))
    }
}
