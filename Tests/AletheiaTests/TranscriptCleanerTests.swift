import XCTest
@testable import Aletheia

final class TranscriptCleanerTests: XCTestCase {
    private func line(_ text: String, at start: TimeInterval, source: String = "Therapist") -> TranscribedLine {
        TranscribedLine(source: source, startTime: start, text: text)
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
