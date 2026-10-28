import XCTest

/// What the test asks the app to start in. Encoded as the `ALETHEIA_FIXTURE`
/// launch environment value; the app builds this state before its first window.
struct Scenario: Encodable, Equatable {
    struct PatientSeed: Encodable, Equatable {
        var name: String
        var sessions: Int?
        var recordingConsent: Bool?
        /// A recorded consent for the first session.
        var consentRecorded: Bool?
        /// The first session's transcript, stored form: "[mm:ss] You: …" or "[mm:ss] Call audio: …".
        var transcript: String?
        var myNotes: String?
        /// The conversation already on the first session's Ask tab.
        var chat: [ChatSeed]?
    }

    struct ChatSeed: Encodable, Equatable {
        /// "user", "assistant" or "summary".
        var role: String
        var text: String
    }

    struct AIRule: Encodable, Equatable {
        var whenPromptContains: String
        var reply: String
    }

    var run: String
    var patients: [PatientSeed] = []
    var fileVault: String?
    var tier: String?
    /// "on" for a licensed app, "test" for a test license; unset is the unlicensed app.
    var license: String?
    var aiReplies: [String]?
    /// Replies given to any request whose prompt contains the text, ahead of `aiReplies`.
    var aiRules: [AIRule]?
    /// How long each AI stage lasts, so a test can watch the status line move.
    var aiStageMs: Int?
    /// Streamed requests report reading the prompt in this many parts.
    var aiParts: Int?
    /// The model's reading window in tokens, in place of the Mac's own.
    var contextTokens: Int?
    /// Transcription that never finishes, so its progress band stays up.
    var slowTranscription: Bool?
    /// "concise", "natural" or "detailed".
    var noteLength: String?
    /// "fast", "normal" or "focus", for notes and for Ask.
    var noteEffort: String?
    var chatEffort: String?
    /// What Import Audio… is handed instead of the open panel: "clip", "twoTracks", "threeFiles" or "notAudio".
    var importFile: String?
    /// The patient whose newest session is on screen at launch.
    var open: String?
    var consentPolicy: String?
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
        let json = probeElement.label
        guard !json.isEmpty,
              let snapshot = try? JSONDecoder().decode(ProbeSnapshot.self, from: Data(json.utf8)) else {
            XCTFail("the fixture probe could not be read: \"\(json.prefix(200))\"")
            return ProbeSnapshot(files: [], patients: [], aiRequests: [], transcriptLines: 0)
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

    // MARK: Looking for text

    /// Static text whose words contain `words`.
    func text(containing words: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", words, words)).firstMatch
    }

    /// Any element whose label contains `words` (status lines carry theirs as a label).
    func element(labelContaining words: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", words)).firstMatch
    }

    /// Any element whose label starts with `prefix`.
    func element(labelStarting prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    func waitFor(_ element: XCUIElement, timeout: TimeInterval) -> Bool {
        element.waitForExistence(timeout: timeout)
    }
}
