import AppKit
import XCTest

/// What the test asks the app to start in: the app's own `FixtureScenario`
/// (compiled into this bundle too), encoded as the `ALETHEIA_FIXTURE` launch
/// environment value; the app builds this state before its first window.
typealias Scenario = FixtureScenario

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
        var consentPolicy: String?
    }

    var files: [String]
    var patients: [PatientFacts]
    var aiRequests: [String]
    /// Lines the transcript on screen is laid out in.
    var transcriptLines: Int
}

/// Drives the real Debug app. The test owns the world through the scenario and
/// reads outcomes from the screen and the probe; it never opens the app's
/// container.
///
/// Elements are found by accessibility identifier where the app gives one, with
/// typed queries; a wait that times out fails with what was on screen attached.
final class AppDriver {
    static let timeout: TimeInterval = 20
    /// Text longer than this is pasted rather than typed key by key.
    static let longText = 24

    let app = XCUIApplication()
    private(set) var scenario = Scenario(run: UUID().uuidString.lowercased(), patients: [])
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
        // A copy left running by an earlier test would answer this test's queries.
        if app.state != .notRunning { app.terminate() }
        let data = (try? JSONEncoder().encode(scenario)) ?? Data("{}".utf8)
        app.launchEnvironment["ALETHEIA_FIXTURE"] = String(decoding: data, as: UTF8.self)
        // No windows restored from an earlier run.
        app.launchArguments = ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        app.launch()
        launched = true
        lastProbe = nil
        if !probeElement.waitForExistence(timeout: Self.timeout) {
            fail("the app did not come up in fixture mode")
        }
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

    /// The last label read and what it decoded to, so an unchanged probe is not decoded again.
    private var lastProbe: (json: String, snapshot: ProbeSnapshot?)?

    private func readProbe() -> (json: String, snapshot: ProbeSnapshot?) {
        let json = probeElement.label
        if let lastProbe, lastProbe.json == json { return lastProbe }
        let snapshot = json.isEmpty ? nil : try? JSONDecoder().decode(ProbeSnapshot.self, from: Data(json.utf8))
        lastProbe = (json, snapshot)
        return (json, snapshot)
    }

    var probe: ProbeSnapshot {
        ensureLaunched()
        let read = readProbe()
        guard let snapshot = read.snapshot else {
            XCTFail("the fixture probe could not be read: \"\(read.json.prefix(200))\"")
            return ProbeSnapshot(files: [], patients: [], aiRequests: [], transcriptLines: 0)
        }
        return snapshot
    }

    /// Waits until the probe satisfies `condition` and returns that snapshot;
    /// fails, with the last snapshot and the screen attached, if it never does.
    @discardableResult
    func waitForProbe(timeout: TimeInterval = AppDriver.timeout, _ condition: @escaping (ProbeSnapshot) -> Bool) -> ProbeSnapshot {
        ensureLaunched()
        var met: ProbeSnapshot?
        var checkedJSON: String?
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { [unowned self] _, _ in
            let read = self.readProbe()
            // The same label was already checked and did not satisfy the condition.
            guard read.json != checkedJSON else { return false }
            checkedJSON = read.json
            guard let snapshot = read.snapshot, condition(snapshot) else { return false }
            met = snapshot
            return true
        }, object: nil)
        _ = XCTWaiter().wait(for: [expectation], timeout: timeout)
        if let met { return met }
        let json = readProbe().json
        fail("the probe never showed what the test waited for; it last read: \(json.prefix(600))")
        return readProbe().snapshot ?? ProbeSnapshot(files: [], patients: [], aiRequests: [], transcriptLines: 0)
    }

    // MARK: Element helpers

    /// The button titled `title`, including one that shows its shortcut beside
    /// the title (its label then reads "<title>, Shortcut: …").
    func button(_ title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label == %@ OR title == %@ OR label BEGINSWITH %@",
            title, title, title, "\(title), Shortcut:")).firstMatch
    }

    /// The element the app tagged with `identifier`, of any type.
    func element(id identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A status line (`ai.status`) whose words contain `words`.
    func status(containing words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "ai.status")
            .matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    func tap(_ title: String) {
        click(button(title), "button \"\(title)\"")
    }

    /// Clicks `element` once it is on screen and can take the click.
    func click(_ element: XCUIElement, _ what: String) {
        guard element.waitForExistence(timeout: Self.timeout) else { return fail("no \(what)") }
        guard wait(for: element, "isHittable == true", timeout: Self.timeout) else {
            return fail("the \(what) is there but cannot be clicked")
        }
        element.click()
    }

    func type(_ text: String, into field: String) {
        let element = app.textFields[field].firstMatch
        guard element.waitForExistence(timeout: Self.timeout) else { return fail("no field \"\(field)\"") }
        element.click()
        if let existing = element.value as? String, !existing.isEmpty, existing != field {
            element.typeKey("a", modifierFlags: .command)
            element.typeKey(.delete, modifierFlags: [])
        }
        enter(text, into: element)
    }

    /// Puts `text` in the focused `element`: typed when short, pasted when long.
    func enter(_ text: String, into element: XCUIElement) {
        guard !text.isEmpty else { return }
        guard text.count > Self.longText else { return element.typeText(text) }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        element.typeKey("v", modifierFlags: .command)
    }

    func exists(_ element: XCUIElement) -> Bool {
        element.waitForExistence(timeout: Self.timeout) || timedOut("waited for: \(element)")
    }

    func gone(_ element: XCUIElement) -> Bool {
        wait(for: element, "exists == false", timeout: Self.timeout) || timedOut("waited for this to go: \(element)")
    }

    func becomesEnabled(_ element: XCUIElement, _ enabled: Bool) -> Bool {
        wait(for: element, "isEnabled == \(enabled ? "true" : "false")", timeout: Self.timeout)
            || timedOut("waited for this to be \(enabled ? "enabled" : "disabled"): \(element)")
    }

    private func wait(for element: XCUIElement, _ predicate: String, timeout: TimeInterval) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: predicate), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }

    // MARK: Looking for text

    /// Static text whose words contain `words`.
    func text(containing words: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", words, words)).firstMatch
    }

    /// Any element whose label or value contains `words`, including a card
    /// whose children are combined into one element.
    func anything(containing words: String) -> XCUIElement {
        onScreen.matching(NSPredicate(
            format: "label CONTAINS %@ OR (elementType == %lu AND value CONTAINS %@)",
            words, XCUIElement.ElementType.staticText.rawValue, words)).firstMatch
    }

    /// Any element whose label contains `words` (status lines carry theirs as a label).
    func element(labelContaining words: String) -> XCUIElement {
        onScreen.matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    /// Every element but the invisible probe, whose label logs what the app
    /// sent the AI and so holds words the user no longer sees.
    private var onScreen: XCUIElementQuery {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier != %@", "fixture-probe"))
    }

    /// Any element whose label starts with `prefix`.
    func element(labelStarting prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func waitFor(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        element.waitForExistence(timeout: timeout) || timedOut("waited \(Int(timeout))s for: \(element)")
    }

    // MARK: Diagnostics

    /// Fails the test with `what`, the screen and the element tree attached.
    func fail(_ what: String, file: StaticString = #filePath, line: UInt = #line) {
        timedOut(what)
        XCTFail(what, file: file, line: line)
    }

    /// Attaches the screen and a trimmed element tree to the test, so a
    /// timeout on CI shows what was there instead. Returns false, for `||`.
    @discardableResult
    func timedOut(_ what: String) -> Bool {
        XCTContext.runActivity(named: "Timed out: \(what)") { activity in
            if launched, app.state == .runningForeground || app.state == .runningBackground {
                let screen = XCTAttachment(screenshot: app.screenshot())
                screen.name = "screen"
                screen.lifetime = .keepAlways
                activity.add(screen)
                let tree = XCTAttachment(string: String(app.debugDescription.prefix(40_000)))
                tree.name = "element tree (trimmed)"
                tree.lifetime = .keepAlways
                activity.add(tree)
            }
        }
        return false
    }
}
