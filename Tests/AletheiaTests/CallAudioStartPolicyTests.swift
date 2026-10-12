import XCTest
@testable import Aletheia

final class CallAudioStartPolicyTests: XCTestCase {
    func testFirstRecordOfALaunchAttemptsEvenWhenNothingSaysAccessIsGranted() {
        XCTAssertTrue(CallAudioStartPolicy().shouldAttempt(preflight: false, confirmedBefore: false))
    }

    func testAFailedAttemptIsNotRepeatedThisLaunch() {
        var policy = CallAudioStartPolicy()
        policy.recordAttempt(succeeded: false)
        XCTAssertFalse(policy.shouldAttempt(preflight: false, confirmedBefore: false))
    }

    func testKnownGoodAccessStillAttemptsAfterAFailure() {
        var policy = CallAudioStartPolicy()
        policy.recordAttempt(succeeded: false)
        XCTAssertTrue(policy.shouldAttempt(preflight: true, confirmedBefore: false))
        XCTAssertTrue(policy.shouldAttempt(preflight: false, confirmedBefore: true))
    }

    func testGrantedPreflightAttempts() {
        XCTAssertTrue(CallAudioStartPolicy().shouldAttempt(preflight: true, confirmedBefore: false))
    }

    func testAConfirmationFromAnEarlierSessionAttemptsEvenThoughPreflightIsStale() {
        XCTAssertTrue(CallAudioStartPolicy().shouldAttempt(preflight: false, confirmedBefore: true))
    }

    func testASuccessThisLaunchKeepsWorking() {
        var policy = CallAudioStartPolicy()
        policy.recordAttempt(succeeded: true)
        XCTAssertTrue(policy.shouldAttempt(preflight: false, confirmedBefore: false))
    }

    func testSkippedMessagePointsAtSetup() {
        XCTAssertTrue(CallAudioStartPolicy.skippedMessage.contains("Setup Assistant"))
    }
}

final class CallAudioGrantStoreTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "CallAudioGrantStoreTests-\(UUID().uuidString)")
    }

    func testNotConfirmedByDefault() {
        XCTAssertFalse(CallAudioGrantStore(defaults: defaults, build: "1.0+1").isConfirmed)
    }

    func testConfirmSurvivesANewStoreForTheSameBuild() {
        CallAudioGrantStore(defaults: defaults, build: "1.0+1").confirm()
        XCTAssertTrue(CallAudioGrantStore(defaults: defaults, build: "1.0+1").isConfirmed)
    }

    func testANewBuildNeedsConfirmingAgain() {
        CallAudioGrantStore(defaults: defaults, build: "1.0+1").confirm()
        XCTAssertFalse(CallAudioGrantStore(defaults: defaults, build: "1.0+2").isConfirmed)
    }

    func testClearForgetsTheConfirmation() {
        let store = CallAudioGrantStore(defaults: defaults, build: "1.0+1")
        store.confirm()
        store.clear()
        XCTAssertFalse(store.isConfirmed)
    }
}
