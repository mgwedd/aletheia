import XCTest
@testable import Aletheia

final class SummaryLengthTests: XCTestCase {
    private let phrases = LongSessionNote.defaultRiskPhrases

    private func sentences(_ count: Int) -> String {
        (1...count).map { "Point \($0) was talked about." }.joined(separator: " ")
    }

    func testTextWithinTheCeilingIsUnchanged() {
        let text = sentences(3) + "\n\n" + sentences(2)
        XCTAssertEqual(SummaryLength.trimmed(text, ceiling: 25, phrases: phrases), text)
    }

    func testKeepsWholeSentencesWithinTheCeiling() {
        let trimmed = SummaryLength.trimmed(sentences(10), ceiling: 12, phrases: phrases)
        XCTAssertEqual(trimmed, "Point 1 was talked about. Point 2 was talked about.")
    }

    func testAKeptParagraphBreakStays() {
        let text = "Point 1 was talked about.\n\nPoint 2 was talked about. Point 3 was talked about."
        XCTAssertEqual(SummaryLength.trimmed(text, ceiling: 10, phrases: phrases),
                       "Point 1 was talked about.\n\nPoint 2 was talked about.")
    }

    func testARiskSentencePastTheCeilingStays() {
        let text = sentences(6) + " She said she had thought about suicide last month. " + sentences(2)
        XCTAssertEqual(SummaryLength.trimmed(text, ceiling: 10, phrases: phrases),
                       "Point 1 was talked about. Point 2 was talked about. She said she had thought about suicide last month.")
    }

    func testTheFirstSentenceStaysEvenOverTheCeiling() {
        let long = "One two three four five six seven eight. Nine ten."
        XCTAssertEqual(SummaryLength.trimmed(long, ceiling: 4, phrases: phrases), "One two three four five six seven eight.")
    }

    func testDecimalsAndClosingQuotesDoNotSplitWrongly() {
        let text = "She said \"I am tired.\" Sleep was 5.5 hours. Mood was low today."
        XCTAssertEqual(SummaryLength.trimmed(text, ceiling: 9, phrases: phrases),
                       "She said \"I am tired.\" Sleep was 5.5 hours.")
    }

    func testCeilingsFollowTheSummaryTargets() {
        XCTAssertEqual(AnswerDepth.allCases.map(\.summaryWordCeiling), [150, 300, 600])
        for depth in AnswerDepth.allCases {
            XCTAssertTrue(depth.target(for: .summary).contains("\(depth.summaryWordCeiling) words"))
        }
    }

    func testTheStreamTrimsEverySnapshot() async throws {
        let stream = AsyncThrowingStream<String, Error> { continuation in
            continuation.yield("Point 1 was talked about.")
            continuation.yield(self.sentences(5))
            continuation.finish()
        }
        var seen: [String] = []
        for try await text in SummaryLength.held(stream, ceiling: 10, phrases: phrases) { seen.append(text) }
        XCTAssertEqual(seen, ["Point 1 was talked about.", "Point 1 was talked about. Point 2 was talked about."])
    }
}
