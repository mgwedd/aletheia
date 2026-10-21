import XCTest
@testable import Aletheia

@MainActor
final class NoteProgressTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    private func noteRun(read: String = "Reading the session", startedAt: Date? = nil) -> AIRunProgress {
        AIRunProgress(readTitle: read, writeTitle: "Writing the note", startedAt: startedAt ?? start)
    }

    func testTitleNamesTheFormat() {
        XCTAssertEqual(NoteProgress.title(for: .narrative), "Generating summary")
        XCTAssertEqual(NoteProgress.title(for: .soap), "Generating SOAP note")
        XCTAssertEqual(NoteProgress.title(for: .girp), "Generating GIRP note")
    }

    func testCreepRisesButNeverArrives() {
        XCTAssertEqual(NoteProgress.creep(0, scale: 30), 0)
        XCTAssertEqual(NoteProgress.creep(-5, scale: 30), 0)
        let early = NoteProgress.creep(10, scale: 30)
        let late = NoteProgress.creep(600, scale: 30)
        XCTAssertGreaterThan(early, 0)
        XCTAssertGreaterThan(late, early)
        XCTAssertLessThan(late, 0.95 + 1e-9)
    }

    func testReadingFillsTheFirstHalfByMeasuredSpeed() {
        var progress = noteRun()
        progress.estimatedPromptTokens = 1000
        // 100 tok/s: 10 s to read; 5 s in is halfway through reading.
        let mid = NoteProgress.callFraction(progress, now: start.addingTimeInterval(5), readTokensPerSecond: 100, expectedOutputTokens: nil)
        XCTAssertEqual(mid, 0.25, accuracy: 0.0001)
        let over = NoteProgress.callFraction(progress, now: start.addingTimeInterval(60), readTokensPerSecond: 100, expectedOutputTokens: nil)
        XCTAssertLessThan(over, 0.5)
    }

    func testReadingWithoutASpeedStillMoves() {
        let progress = noteRun()
        let a = NoteProgress.callFraction(progress, now: start.addingTimeInterval(5), readTokensPerSecond: nil, expectedOutputTokens: nil)
        let b = NoteProgress.callFraction(progress, now: start.addingTimeInterval(60), readTokensPerSecond: nil, expectedOutputTokens: nil)
        XCTAssertGreaterThan(a, 0)
        XCTAssertGreaterThan(b, a)
        XCTAssertLessThan(b, 0.5)
    }

    func testWritingFillsTheSecondHalf() {
        var progress = noteRun()
        progress.firstTokenAt = start.addingTimeInterval(10)
        progress.tokensWritten = 200
        let known = NoteProgress.callFraction(progress, now: start.addingTimeInterval(20), readTokensPerSecond: nil, expectedOutputTokens: 400)
        XCTAssertEqual(known, 0.75, accuracy: 0.0001)
        progress.tokensWritten = 5000
        let past = NoteProgress.callFraction(progress, now: start.addingTimeInterval(20), readTokensPerSecond: nil, expectedOutputTokens: 400)
        XCTAssertLessThan(past, 1)
        progress.tokensWritten = 0
        let unknown = NoteProgress.callFraction(progress, now: start.addingTimeInterval(20), readTokensPerSecond: nil, expectedOutputTokens: nil)
        XCTAssertEqual(unknown, 0.5, accuracy: 0.0001)
    }

    func testShortSessionUsesTheWholeDraftBand() {
        var progress = noteRun()
        progress.firstTokenAt = start
        progress.tokensWritten = 200
        let value = NoteProgress.fraction(progress, now: start, speed: ModelSpeed(outputs: ["note": 400]))
        XCTAssertEqual(value, NoteProgress.draftEnd * 0.75, accuracy: 0.0001)
    }

    func testDigestStaysInItsBandAndAdvancesBySteps() {
        var first = noteRun(read: "\(DigestBuilder.activityTitle) · Reading section 1 of 3")
        first.steps = AIRunSteps(done: 0, total: 4)
        var later = first
        later.steps = AIRunSteps(done: 3, total: 4)
        later.firstTokenAt = start
        later.tokensWritten = 10_000
        let a = NoteProgress.fraction(first, now: start, speed: nil)
        let b = NoteProgress.fraction(later, now: start, speed: nil)
        XCTAssertGreaterThanOrEqual(a, 0)
        XCTAssertGreaterThan(b, a)
        XCTAssertLessThan(b, NoteProgress.digestEnd)
    }

    func testDraftAfterADigestStartsWhereTheDigestEnded() {
        var progress = noteRun(read: "Reading passages")
        progress.steps = AIRunSteps(done: 3, total: 4)
        XCTAssertEqual(NoteProgress.fraction(progress, now: start, speed: nil), NoteProgress.digestEnd, accuracy: 0.0001)
        // A saved digest: no digest stage ran, so the draft starts from zero.
        XCTAssertEqual(NoteProgress.fraction(noteRun(read: "Reading passages"), now: start, speed: nil), 0, accuracy: 0.0001)
    }

    func testCheckComesAfterTheDraft() {
        var progress = noteRun(read: LongSessionNote.checkTitle)
        progress.firstTokenAt = start
        progress.tokensWritten = 100_000
        let value = NoteProgress.fraction(progress, now: start, speed: nil)
        XCTAssertGreaterThanOrEqual(value, NoteProgress.draftEnd)
        XCTAssertLessThan(value, 1)
    }

    func testPhasesNeverOverlap() {
        XCTAssertLessThan(NoteProgress.digestEnd, NoteProgress.draftEnd)
        XCTAssertLessThan(NoteProgress.draftEnd, NoteProgress.checkEnd)
        XCTAssertLessThan(NoteProgress.checkEnd, 1)
    }

    func testHighWaterNeverGoesBack() {
        let mark = ProgressHighWater()
        XCTAssertEqual(mark.clamp(0.3), 0.3)
        XCTAssertEqual(mark.clamp(0.1), 0.3)
        XCTAssertEqual(mark.clamp(0.5), 0.5)
    }
}
