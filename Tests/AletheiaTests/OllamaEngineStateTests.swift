import XCTest
@testable import Aletheia

/// Pins the pure engine-readiness state machine behind the #111 fix: given the
/// same fresh-install sequence a clinician hits (download the app, run the
/// wizard, quit, come back later), the checklist must be able to tell "never
/// installed" apart from "installed but the server isn't up" so it offers the
/// right one-click fix instead of just reopening the download page forever.
final class OllamaEngineStateTests: XCTestCase {
    func testNotInstalledWinsOverEverythingElse() {
        // Even if somehow "reachable" or "launching" were also true, not being
        // installed is the terminal fact — there's nothing to launch.
        XCTAssertEqual(
            OllamaEngineState.classify(installed: false, isLaunching: true, reachable: true, hasModel: true),
            .notInstalled
        )
    }

    func testInstalledButUnreachableAndNotLaunchingIsInstalledNotRunning() {
        XCTAssertEqual(
            OllamaEngineState.classify(installed: true, isLaunching: false, reachable: false, hasModel: nil),
            .installedNotRunning
        )
    }

    func testLaunchingReportsStartingEvenBeforeReachable() {
        XCTAssertEqual(
            OllamaEngineState.classify(installed: true, isLaunching: true, reachable: false, hasModel: nil),
            .starting
        )
    }

    func testReachableWithUnknownModelStatusIsRunning() {
        XCTAssertEqual(
            OllamaEngineState.classify(installed: true, isLaunching: false, reachable: true, hasModel: nil),
            .running
        )
    }

    func testReachableWithoutModelIsModelMissing() {
        XCTAssertEqual(
            OllamaEngineState.classify(installed: true, isLaunching: false, reachable: true, hasModel: false),
            .modelMissing
        )
    }

    func testReachableWithModelIsReady() {
        XCTAssertEqual(
            OllamaEngineState.classify(installed: true, isLaunching: false, reachable: true, hasModel: true),
            .ready
        )
    }

    // MARK: needsAction

    func testStatesThatBlockAIHaveAnAction() {
        for state: OllamaEngineState in [.notInstalled, .installedNotRunning, .modelMissing] {
            XCTAssertTrue(state.needsAction, "\(state) should prompt a one-click fix")
        }
    }

    func testTransientAndReadyStatesHaveNoAction() {
        for state: OllamaEngineState in [.starting, .running, .ready] {
            XCTAssertFalse(state.needsAction, "\(state) shouldn't prompt a fix — nothing to click")
        }
    }
}
