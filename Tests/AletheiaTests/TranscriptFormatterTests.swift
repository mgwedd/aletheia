import XCTest
@testable import Aletheia

final class TranscriptFormatterTests: XCTestCase {
    private func line(
        _ text: String,
        _ start: TimeInterval,
        _ end: TimeInterval,
        _ source: String = "Therapist"
    ) -> TranscribedLine {
        TranscribedLine(source: source, startTime: start, endTime: end, text: text)
    }

    private func printed(_ lines: [TranscribedLine]) -> [String] {
        TranscriptFormatter.format(lines).components(separatedBy: "\n")
    }

    func testNoLinesYieldsEmptyString() {
        XCTAssertEqual(TranscriptFormatter.format([]), "")
    }

    func testPlainLinesUseTimestampAndLabel() {
        let out = printed([
            line("How are you?", 3, 5),
            line("Fine.", 8, 9, "Call audio"),
        ])
        XCTAssertEqual(out, [
            "[00:03] Therapist: How are you?",
            "[00:08] Call audio: Fine.",
        ])
    }

    func testBothSidesOfAnOverlapAreMarked() {
        let out = printed([
            line("Let me finish.", 10, 16),
            line("But I think", 12, 15, "Call audio"),
            line("Go on.", 30, 31),
        ])
        XCTAssertEqual(out, [
            "[00:10] Therapist (overlapping): Let me finish.",
            "[00:12] Call audio (overlapping): But I think",
            "[00:30] Therapist: Go on.",
        ])
    }

    func testTouchingWithinToleranceIsNotAnOverlap() {
        // Call starts 0.2s before the therapist's line ends: a normal hand-off.
        let out = printed([
            line("Question?", 10, 12.2),
            line("Answer.", 12, 14, "Call audio"),
        ])
        XCTAssertEqual(out, [
            "[00:10] Therapist: Question?",
            "[00:12] Call audio: Answer.",
        ])
    }

    func testExactlyAdjacentLinesAreNotAnOverlap() {
        let out = printed([
            line("A", 10, 12),
            line("B", 12, 14, "Call audio"),
        ])
        XCTAssertFalse(out.contains { $0.contains("(overlapping)") })
    }

    func testHalfSecondIntersectionIsNotAnOverlap() {
        let out = printed([
            line("A", 10, 12.5),
            line("B", 12, 14, "Call audio"),
        ])
        XCTAssertFalse(out.contains { $0.contains("(overlapping)") })
    }

    func testSustainedTalkOverMarksBothSides() {
        let out = printed([
            line("A", 10, 14),
            line("B", 12, 15, "Call audio"),
        ])
        XCTAssertEqual(out.filter { $0.contains("(overlapping)") }.count, 2)
    }

    func testBackchannelUnderALongTurnMarksNothing() {
        let out = printed([
            line("A long sentence of mine", 18, 30),
            line("uh-huh", 21, 21.6, "Call audio"),
            line("right", 25, 25.4, "Call audio"),
        ])
        XCTAssertFalse(out.contains { $0.contains("(overlapping)") })
    }

    func testManySmallInterruptionsAddUpOnTheLongTurn() {
        // Three 1.5s interjections cover 4.5s of a 10s turn: 45% of it.
        let out = printed([
            line("Turn", 0, 10),
            line("one", 1, 2.5, "Call audio"),
            line("two", 4, 5.5, "Call audio"),
            line("three", 7, 8.5, "Call audio"),
        ])
        XCTAssertEqual(out.filter { $0.contains("(overlapping)") }.count, 4)
    }

    func testSameSourceLinesNeverOverlapEachOther() {
        let out = printed([
            line("One", 10, 20),
            line("Two", 12, 18),
        ])
        XCTAssertFalse(out.contains { $0.contains("(overlapping)") })
    }

    func testAsideMarksItselfButNotTheLongTurnAroundIt() {
        let out = printed([
            line("Long turn", 0, 30),
            line("Quick aside", 5, 7, "Call audio"),
            line("Later", 40, 41, "Call audio"),
        ])
        XCTAssertEqual(out, [
            "[00:00] Therapist: Long turn",
            "[00:05] Call audio (overlapping): Quick aside",
            "[00:40] Call audio: Later",
        ])
    }

    func testOverlapDetectedAcrossIntermediateLines() {
        // The line between the two overlapping ones must not stop the scan.
        let out = printed([
            line("Turn", 0, 10),
            line("Middle", 1, 2),
            line("Talk-over", 3, 10, "Call audio"),
        ])
        XCTAssertEqual(out, [
            "[00:00] Therapist (overlapping): Turn",
            "[00:01] Therapist: Middle",
            "[00:03] Call audio (overlapping): Talk-over",
        ])
    }

    func testLinesArePrintedInStartOrderWithStableTies() {
        let out = printed([
            line("Third", 9, 10),
            line("First", 1, 2),
            line("Second a", 5, 5.1),
            line("Second b", 5, 5.1, "Call audio"),
        ])
        XCTAssertEqual(out.map { String($0.prefix(7)) }, ["[00:01]", "[00:05]", "[00:05]", "[00:09]"])
        XCTAssertTrue(out[1].hasSuffix("Second a"))
        XCTAssertTrue(out[2].hasSuffix("Second b"))
    }

    func testTimestampFormatting() {
        let out = printed([
            line("a", 0, 1),
            line("b", 59.9, 60),
            line("c", 61, 62),
            line("d", 75 * 60 + 12, 75 * 60 + 13),
            line("e", 3723, 3724),
        ])
        // Printed in time order, whatever order the lines come in.
        XCTAssertEqual(out.map { String($0.prefix(7)) }, ["[00:00]", "[00:59]", "[01:01]", "[62:03]", "[75:12]"])
    }

    func testTextIsTrimmedOfSurroundingSpaces() {
        XCTAssertEqual(
            TranscriptFormatter.format([line("  padded  ", 1, 2)]),
            "[00:01] Therapist: padded"
        )
    }

    func testCleanThenFormatShowsBackchannelInPlaceUnmarked() {
        let cleaned = TranscriptCleaner.clean([
            line("I was saying", 10, 11),
            line("that it got hard", 11.5, 13),
            line("Mm-hm.", 12, 12.4, "Call audio"),
            line("and then more.", 13.2, 15),
        ])
        XCTAssertEqual(printed(cleaned), [
            "[00:10] Therapist: I was saying that it got hard",
            "[00:12] Call audio: Mm-hm.",
            "[00:13] Therapist: and then more.",
        ])
    }

    func testPrintedLinesStillParseAsTimestamped() {
        let out = printed([
            line("Over", 125, 130),
            line("Talk", 127, 129, "Call audio"),
        ])
        XCTAssertEqual(out.compactMap { TranscriptTimeline.leadingSeconds(of: $0) }, [125, 127])
    }
}
