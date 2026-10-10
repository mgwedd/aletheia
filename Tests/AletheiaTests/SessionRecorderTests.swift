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
