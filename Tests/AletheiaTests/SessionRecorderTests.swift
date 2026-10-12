import XCTest
@testable import Aletheia

@MainActor
final class SessionRecorderTests: XCTestCase {
    func testIdleRecorderHasNoActiveRecording() {
        let recorder = SessionRecorder()
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.isPaused)
        XCTAssertNil(recorder.active)
        XCTAssertNil(recorder.startedAt)
    }

    func testPauseAndResumeAreNoOpsWhenNotRecording() {
        let recorder = SessionRecorder()
        // Guard clauses must keep pause/resume harmless before any recording.
        recorder.pause()
        XCTAssertFalse(recorder.isPaused)
        recorder.resume()
        XCTAssertFalse(recorder.isPaused)
    }

    func testClockStopsWhilePausedAndContinuesAfterResume() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var clock = RecordingClock(startedAt: t0)
        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(30)), 30)

        clock.pause(at: t0.addingTimeInterval(30))
        // Frozen for as long as it stays paused.
        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(30)), 30)
        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(500)), 30)

        clock.resume(at: t0.addingTimeInterval(530))
        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(530)), 30)
        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(550)), 50)
    }

    func testClockHandlesRepeatedPausesAndStrayCalls() {
        let t0 = Date(timeIntervalSinceReferenceDate: 0)
        var clock = RecordingClock(startedAt: t0)
        clock.resume(at: t0.addingTimeInterval(5))  // not paused: ignored
        clock.pause(at: t0.addingTimeInterval(10))
        clock.pause(at: t0.addingTimeInterval(20))  // already paused: keeps the first
        clock.resume(at: t0.addingTimeInterval(40))
        clock.pause(at: t0.addingTimeInterval(50))
        clock.resume(at: t0.addingTimeInterval(60))
        // 70 s since start, minus paused 30 s and 10 s.
        XCTAssertEqual(clock.elapsed(at: t0.addingTimeInterval(70)), 30)
    }

    func testIdleRecorderReportsNoElapsedTime() {
        XCTAssertEqual(SessionRecorder().elapsed(), 0)
    }
}

final class CallAudioWatchTests: XCTestCase {
    private func listen(_ watch: inout CallAudioWatch, level: Float, seconds: Int, step: TimeInterval = 1) {
        for _ in 0..<Int(Double(seconds) / step) { watch.observe(level: level, dt: step) }
    }

    func testNotSilentBeforeTheGracePeriodEnds() {
        var watch = CallAudioWatch(grace: 90)
        listen(&watch, level: 0, seconds: 89)
        XCTAssertFalse(watch.isSilent)
    }

    func testSilentOnceTheWholeGracePeriodWasQuiet() {
        var watch = CallAudioWatch(grace: 90)
        listen(&watch, level: 0, seconds: 90)
        XCTAssertTrue(watch.isSilent)
    }

    func testAnySoundBeforeTheDeadlineClearsItForGood() {
        var watch = CallAudioWatch(grace: 90)
        listen(&watch, level: 0, seconds: 60)
        watch.observe(level: 0.4, dt: 1)
        listen(&watch, level: 0, seconds: 600)
        XCTAssertTrue(watch.heardSound)
        XCTAssertFalse(watch.isSilent)
    }

    func testSoundAfterTheWarningClearsIt() {
        var watch = CallAudioWatch(grace: 90)
        listen(&watch, level: 0, seconds: 120)
        XCTAssertTrue(watch.isSilent)
        watch.observe(level: 0.3, dt: 0.07)
        XCTAssertFalse(watch.isSilent)
    }

    func testAQuietPatientMidSessionNeverTripsIt() {
        var watch = CallAudioWatch(grace: 90)
        listen(&watch, level: 0.5, seconds: 5)
        listen(&watch, level: 0, seconds: 3_000)
        XCTAssertFalse(watch.isSilent)
    }

    func testNoiseFloorBelowTheThresholdCountsAsSilence() {
        var watch = CallAudioWatch(grace: 10)
        listen(&watch, level: CallAudioWatch.audibleLevel, seconds: 10)
        XCTAssertTrue(watch.isSilent)
    }

    func testPollSizedStepsAddUp() {
        var watch = CallAudioWatch(grace: 90)
        listen(&watch, level: 0, seconds: 90, step: 1.0 / 15.0)
        XCTAssertTrue(watch.isSilent)
    }

    func testBadInputIsIgnored() {
        var watch = CallAudioWatch(grace: 5)
        watch.observe(level: 0, dt: 0)
        watch.observe(level: 0, dt: -3)
        XCTAssertEqual(watch.listened, 0)
        watch.observe(level: .nan, dt: 5)
        XCTAssertFalse(watch.heardSound)
        XCTAssertTrue(watch.isSilent)
    }

    func testResetStartsOver() {
        var watch = CallAudioWatch(grace: 5)
        listen(&watch, level: 0, seconds: 5)
        watch.reset()
        XCTAssertFalse(watch.isSilent)
        XCTAssertEqual(watch.listened, 0)
        watch.observe(level: 0.5, dt: 1)
        watch.reset()
        XCTAssertFalse(watch.heardSound)
    }

    @MainActor
    func testIdleRecorderIsNotFlaggedSilent() {
        XCTAssertFalse(SessionRecorder().callAudioSilent)
    }
}
