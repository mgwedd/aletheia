import XCTest
@testable import Aletheia

final class CallAudioStartPolicyTests: XCTestCase {
    func testFirstRecordTriesEvenWithoutPreflight() {
        XCTAssertTrue(CallAudioStartPolicy().shouldAttempt(preflight: false))
    }

    func testGrantedPreflightAlwaysAttempts() {
        var policy = CallAudioStartPolicy()
        policy.recordAttempt(succeeded: false)
        XCTAssertTrue(policy.shouldAttempt(preflight: true))
    }

    func testAfterAFailedAttemptWithoutPreflightItStopsAsking() {
        var policy = CallAudioStartPolicy()
        policy.recordAttempt(succeeded: false)
        XCTAssertFalse(policy.shouldAttempt(preflight: false))
        XCTAssertFalse(policy.shouldAttempt(preflight: false))
    }

    func testASuccessfulAttemptKeepsWorkingEvenThoughPreflightIsStale() {
        var policy = CallAudioStartPolicy()
        policy.recordAttempt(succeeded: true)
        XCTAssertTrue(policy.shouldAttempt(preflight: false))
        policy.recordAttempt(succeeded: false)
        XCTAssertTrue(policy.shouldAttempt(preflight: false), "one later hiccup doesn't disable call audio")
    }

    func testSkippedMessageSaysHowToFixIt() {
        XCTAssertTrue(CallAudioStartPolicy.skippedMessage.contains("System Settings"))
        XCTAssertTrue(CallAudioStartPolicy.skippedMessage.contains("reopen"))
    }
}
