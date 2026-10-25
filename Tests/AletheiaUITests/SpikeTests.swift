import XCTest

final class SpikeTests: XCTestCase {
    func testLaunchesWithScenario() throws {
        let app = XCUIApplication()
        app.launchEnvironment["ALETHEIA_FIXTURE"] = #"{"run":"spike1","patients":[{"name":"Jane Doe","sessions":2}]}"#
        app.launch()
        let probe = app.descendants(matching: .any).matching(identifier: "fixture-probe").firstMatch
        if !probe.waitForExistence(timeout: 30) { print("TREE", app.debugDescription) }
        XCTAssertTrue(probe.exists)
        print("PROBE", probe.value as? String ?? "nil")
    }
}
