import XCTest
@testable import Aletheia

#if DEBUG
final class TestHostFixtureTests: XCTestCase {
    private let xctest = ["XCTestConfigurationFilePath": "/x"]

    @MainActor func testFixtureScenarioKeepsTheAppInTheForeground() {
        let env = xctest.merging([FixtureMode.environmentKey: "{}"]) { $1 }
        XCTAssertFalse(TestHost.runsInBackground(environment: env))
        XCTAssertNil(TestHost.activationPolicy(environment: env))
        let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: true)
        TestHost.conceal(window, environment: env)
        XCTAssertEqual(window.alphaValue, 1)
        XCTAssertFalse(window.ignoresMouseEvents)
    }

    func testUnitTestHostWithoutScenarioStillRunsInTheBackground() {
        XCTAssertTrue(TestHost.runsInBackground(environment: xctest))
        XCTAssertEqual(TestHost.activationPolicy(environment: xctest), .prohibited)
    }

    func testBackgroundTestHostLeavesTheMainWindowEmpty() {
        XCTAssertFalse(TestHost.showsMainWindow(environment: xctest))
        XCTAssertTrue(TestHost.showsMainWindow(environment: [:]))
        XCTAssertTrue(TestHost.showsMainWindow(environment: xctest.merging(["ALETHEIA_FOREGROUND_TESTS": "1"]) { $1 }))
        XCTAssertTrue(TestHost.showsMainWindow(environment: xctest.merging([FixtureMode.environmentKey: "{}"]) { $1 }))
    }
}
#endif
