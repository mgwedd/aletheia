import XCTest

/// What the test asks the app to start in. Encoded as the `ALETHEIA_FIXTURE`
/// launch environment value; the app builds this state before its first window.
struct Scenario: Encodable, Equatable {
    struct PatientSeed: Encodable, Equatable {
        var name: String
        var sessions: Int?
    }

    var run: String
    var patients: [PatientSeed] = []
    var fileVault: String?
    var tier: String?
    var aiReplies: [String]?
}

/// The facts the app publishes through its invisible `fixture-probe` element.
/// The shape is the contract with `FixtureProbe.Snapshot` in the app.
struct ProbeSnapshot: Decodable, Equatable {
    struct PatientFacts: Decodable, Equatable {
        var name: String
        var notes: String
        var clinicalHistory: String
        var medications: [String]
        var folderExists: Bool
        var sessions: Int
    }

    var files: [String]
    var patients: [PatientFacts]
    var aiRequests: [String]
}

/// Drives the real Debug app. The test owns the world through the scenario and
/// reads outcomes from the screen and the probe; it never opens the app's
/// container.
final class AppDriver {
    static let timeout: TimeInterval = 20

    let app = XCUIApplication()
    private(set) var scenario = Scenario(run: UUID().uuidString.lowercased())
    private var launched = false

    // MARK: Given (before launch)

    func seed(_ change: (inout Scenario) -> Void) {
        change(&scenario)
        // A scenario changed after launch takes effect on the next launch.
        if launched { relaunch() }
    }

    // MARK: Launch

    func ensureLaunched() {
        guard !launched else { return }
        launch()
    }

    private func launch() {
        let data = (try? JSONEncoder().encode(scenario)) ?? Data("{}".utf8)
        app.launchEnvironment["ALETHEIA_FIXTURE"] = String(decoding: data, as: UTF8.self)
        app.launch()
        launched = true
        XCTAssertTrue(probeElement.waitForExistence(timeout: Self.timeout), "the app did not come up in fixture mode")
    }

    /// Quits and opens the app again over the same data folder.
    func relaunch() {
        app.terminate()
        launched = false
        launch()
    }

    func shutDown() {
        if launched { app.terminate() }
        launched = false
    }

    // MARK: Probe

    /// Matched by identifier alone: the role SwiftUI reports for the probe is not part of the contract.
    private var probeElement: XCUIElement { app.descendants(matching: .any).matching(identifier: "fixture-probe").firstMatch }

    var probe: ProbeSnapshot {
        ensureLaunched()
        guard let json = probeElement.value as? String,
              let snapshot = try? JSONDecoder().decode(ProbeSnapshot.self, from: Data(json.utf8)) else {
            XCTFail("the fixture probe could not be read")
            return ProbeSnapshot(files: [], patients: [], aiRequests: [])
        }
        return snapshot
    }

    /// Waits until the probe satisfies `condition` and returns the last snapshot.
    @discardableResult
    func waitForProbe(_ condition: @escaping (ProbeSnapshot) -> Bool) -> ProbeSnapshot {
        ensureLaunched()
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { [unowned self] _, _ in condition(self.probe) }, object: nil)
        _ = XCTWaiter().wait(for: [expectation], timeout: Self.timeout)
        return probe
    }

    // MARK: Element helpers

    func button(_ title: String) -> XCUIElement { app.buttons[title].firstMatch }

    func tap(_ title: String) {
        let element = button(title)
        XCTAssertTrue(element.waitForExistence(timeout: Self.timeout), "no button \"\(title)\"")
        element.click()
    }

    func type(_ text: String, into field: String) {
        let element = app.textFields[field].firstMatch
        XCTAssertTrue(element.waitForExistence(timeout: Self.timeout), "no field \"\(field)\"")
        element.click()
        if let existing = element.value as? String, !existing.isEmpty, existing != field {
            element.typeKey("a", modifierFlags: .command)
            element.typeKey(.delete, modifierFlags: [])
        }
        if !text.isEmpty { element.typeText(text) }
    }

    func exists(_ element: XCUIElement) -> Bool { element.waitForExistence(timeout: Self.timeout) }

    func gone(_ element: XCUIElement) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: Self.timeout) == .completed
    }

    func becomesEnabled(_ element: XCUIElement, _ enabled: Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "isEnabled == %@", NSNumber(value: enabled)), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: Self.timeout) == .completed
    }
}
