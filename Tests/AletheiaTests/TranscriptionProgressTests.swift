import XCTest
@testable import Aletheia

final class TranscriptionProgressTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000)

    // MARK: Overall progress mapping

    func testSingleTrackSpansWholeRange() {
        XCTAssertEqual(TranscriptionProgressMath.overall(trackIndex: 0, trackCount: 1, trackFraction: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(TranscriptionProgressMath.overall(trackIndex: 0, trackCount: 1, trackFraction: 0.72), 0.72, accuracy: 1e-9)
        XCTAssertEqual(TranscriptionProgressMath.overall(trackIndex: 0, trackCount: 1, trackFraction: 1), 1, accuracy: 1e-9)
    }

    func testTwoTracksEachOwnHalf() {
        XCTAssertEqual(TranscriptionProgressMath.overall(trackIndex: 0, trackCount: 2, trackFraction: 0.5), 0.25, accuracy: 1e-9)
        XCTAssertEqual(TranscriptionProgressMath.overall(trackIndex: 0, trackCount: 2, trackFraction: 1), 0.5, accuracy: 1e-9)
        XCTAssertEqual(TranscriptionProgressMath.overall(trackIndex: 1, trackCount: 2, trackFraction: 0), 0.5, accuracy: 1e-9)
        XCTAssertEqual(TranscriptionProgressMath.overall(trackIndex: 1, trackCount: 2, trackFraction: 1), 1, accuracy: 1e-9)
    }

    func testOverallClampsOutOfRangeInput() {
        XCTAssertEqual(TranscriptionProgressMath.overall(trackIndex: 0, trackCount: 1, trackFraction: 1.4), 1, accuracy: 1e-9)
        XCTAssertEqual(TranscriptionProgressMath.overall(trackIndex: 0, trackCount: 1, trackFraction: -0.2), 0, accuracy: 1e-9)
        XCTAssertEqual(TranscriptionProgressMath.overall(trackIndex: 0, trackCount: 0, trackFraction: 0.5), 0)
    }

    // MARK: Estimates

    func testNoEstimateBeforeEnoughData() {
        XCTAssertNil(TranscriptionProgressMath.remainingSeconds(elapsed: 5, fractionDone: 0.5))
        XCTAssertNil(TranscriptionProgressMath.remainingSeconds(elapsed: 30, fractionDone: 0))
        XCTAssertNil(TranscriptionProgressMath.remainingSeconds(elapsed: 30, fractionDone: 1))
    }

    func testEstimateExtrapolatesFromPace() throws {
        // 25% in 30 s -> 90 s to go.
        let remaining = try XCTUnwrap(TranscriptionProgressMath.remainingSeconds(elapsed: 30, fractionDone: 0.25))
        XCTAssertEqual(remaining, 90, accuracy: 1e-9)
    }

    func testRemainingText() {
        XCTAssertEqual(TranscriptionProgressMath.remainingText(seconds: 20), "less than a minute left")
        XCTAssertEqual(TranscriptionProgressMath.remainingText(seconds: 125), "about 2 min left")
    }

    func testStageTitles() {
        XCTAssertEqual(TranscriptionStage.preparing.title, "Preparing audio")
        XCTAssertEqual(TranscriptionStage.transcribingMic.title, "Transcribing mic")
        XCTAssertEqual(TranscriptionStage.transcribingCall.title, "Transcribing call audio")
        XCTAssertEqual(TranscriptionStage.saving.title, "Saving")
    }

    // MARK: Job state

    func testNewJobStartsPreparingAtZero() {
        let job = TranscriptionJob(startedAt: t0)
        XCTAssertEqual(job.progress, TranscriptionProgress(stage: .preparing, fraction: 0))
        XCTAssertFalse(job.isCancelling)
        XCTAssertTrue(job.canCancel)
        XCTAssertNil(job.remainingSeconds(now: t0.addingTimeInterval(60)))
    }

    func testProgressNeverMovesBackwards() {
        var job = TranscriptionJob(startedAt: t0)
        job.apply(.init(stage: .transcribingMic, fraction: 0.4), now: t0)
        job.apply(.init(stage: .transcribingMic, fraction: 0.3), now: t0)
        XCTAssertEqual(job.progress.fraction, 0.4, accuracy: 1e-9)
    }

    func testSavingIsFinalAndNotCancellable() {
        var job = TranscriptionJob(startedAt: t0)
        job.apply(.init(stage: .saving, fraction: 1), now: t0)
        // A straggling report from the transcriber must not undo it.
        job.apply(.init(stage: .transcribingCall, fraction: 0.9), now: t0)
        XCTAssertEqual(job.progress.stage, .saving)
        XCTAssertFalse(job.canCancel)
        XCTAssertFalse(job.requestCancel())
        XCTAssertFalse(job.isCancelling)
    }

    func testCancelFreezesJob() {
        var job = TranscriptionJob(startedAt: t0)
        job.apply(.init(stage: .transcribingMic, fraction: 0.2), now: t0)
        XCTAssertTrue(job.requestCancel())
        XCTAssertTrue(job.isCancelling)
        XCTAssertFalse(job.canCancel)
        XCTAssertFalse(job.requestCancel())
        job.apply(.init(stage: .transcribingMic, fraction: 0.8), now: t0)
        XCTAssertEqual(job.progress.fraction, 0.2, accuracy: 1e-9)
        XCTAssertNil(job.remainingSeconds(now: t0.addingTimeInterval(100)))
        XCTAssertEqual(job.statusLine, "Cancelling…")
    }

    func testEstimateMeasuredFromWhenTranscribingBegan() throws {
        var job = TranscriptionJob(startedAt: t0)
        // 60 s of decrypt/resample must not count against whisper's pace.
        job.apply(.init(stage: .preparing, fraction: 0), now: t0)
        let begin = t0.addingTimeInterval(60)
        job.apply(.init(stage: .transcribingMic, fraction: 0), now: begin)
        let now = begin.addingTimeInterval(30)
        job.apply(.init(stage: .transcribingMic, fraction: 0.25), now: now)
        let remaining = try XCTUnwrap(job.remainingSeconds(now: now))
        XCTAssertEqual(remaining, 90, accuracy: 1e-9)
    }

    func testNoEstimateWhilePreparing() {
        var job = TranscriptionJob(startedAt: t0)
        job.apply(.init(stage: .transcribingMic, fraction: 0.1), now: t0)
        job.apply(.init(stage: .preparing, fraction: 0.5), now: t0.addingTimeInterval(60))
        XCTAssertNil(job.remainingSeconds(now: t0.addingTimeInterval(120)))
    }

    func testStatusLine() {
        var job = TranscriptionJob(startedAt: t0)
        job.apply(.init(stage: .transcribingCall, fraction: 0.5), now: t0)
        XCTAssertEqual(job.statusLine, "Transcribing… 50%")
    }
}
