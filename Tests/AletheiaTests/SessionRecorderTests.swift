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
}
