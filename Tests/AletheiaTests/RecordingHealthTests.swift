import XCTest
@testable import Aletheia

/// `RecordingHealth` is the pure, thread-safe tally that turns a silent audio
/// write failure into something the app can surface. The AVAudioEngine wiring
/// that feeds it can only be exercised on a real device, but this — the
/// first-failure detection, the counters, and the snapshot — is where the logic
/// lives, so it's pinned here.
final class RecordingHealthTests: XCTestCase {
    func testStartsHealthy() {
        let snap = RecordingHealth().snapshot
        XCTAssertTrue(snap.isHealthy)
        XCTAssertEqual(snap.writeFailures, 0)
        XCTAssertEqual(snap.configurationChanges, 0)
        XCTAssertNil(snap.firstFailure)
    }

    func testFirstWriteFailureReportsOnceAndSticks() {
        let health = RecordingHealth()

        XCTAssertTrue(health.recordWriteFailure("disk full"),
                      "the first failure should report true so it can be surfaced once")
        XCTAssertFalse(health.recordWriteFailure("io error"),
                       "later failures should report false to avoid re-surfacing")
        XCTAssertFalse(health.recordWriteFailure("io error again"))

        let snap = health.snapshot
        XCTAssertEqual(snap.writeFailures, 3, "every failure is still counted")
        XCTAssertEqual(snap.firstFailure, "disk full", "the first message is kept, not overwritten")
        XCTAssertFalse(snap.isHealthy)
    }

    func testConfigurationChangeMakesUnhealthy() {
        let health = RecordingHealth()
        health.recordConfigurationChange()
        health.recordConfigurationChange()

        let snap = health.snapshot
        XCTAssertEqual(snap.configurationChanges, 2)
        XCTAssertEqual(snap.writeFailures, 0)
        XCTAssertNil(snap.firstFailure)
        XCTAssertFalse(snap.isHealthy, "an input-config change alone is enough to flag disruption")
    }

    func testResetClearsEverything() {
        let health = RecordingHealth()
        health.recordWriteFailure("disk full")
        health.recordConfigurationChange()

        health.reset()

        XCTAssertEqual(health.snapshot, RecordingHealth.Snapshot(
            writeFailures: 0, configurationChanges: 0, firstFailure: nil))
        XCTAssertTrue(health.snapshot.isHealthy)
        XCTAssertTrue(health.recordWriteFailure("first again"),
                      "after reset the next failure is the first one again")
    }

    func testSnapshotIsAnImmutableCopy() {
        let health = RecordingHealth()
        health.recordWriteFailure("one")
        let before = health.snapshot

        health.recordWriteFailure("two")
        health.recordConfigurationChange()

        XCTAssertEqual(before.writeFailures, 1, "an earlier snapshot must not change under later writes")
        XCTAssertEqual(before.configurationChanges, 0)
    }

    /// The counters are written from the real-time audio thread and read from the
    /// main actor, so concurrent access must not corrupt them.
    func testConcurrentRecordingIsCountedAccurately() {
        let health = RecordingHealth()
        let iterations = 1_000

        DispatchQueue.concurrentPerform(iterations: iterations) { _ in
            health.recordWriteFailure("boom")
            health.recordConfigurationChange()
        }

        let snap = health.snapshot
        XCTAssertEqual(snap.writeFailures, iterations)
        XCTAssertEqual(snap.configurationChanges, iterations)
        XCTAssertNotNil(snap.firstFailure)
    }
}
