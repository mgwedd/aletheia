import XCTest

/// The check a test belongs to: its ID and the QA line from
/// docs/spec/ACCEPTANCE-CRITERIA.md.
struct Check {
    let id: String
    let sentence: String

    /// "PATIENT-03 Type "Jane Doe" and click Add → her page opens ..."
    var headline: String { sentence.isEmpty ? id : "\(id) \(sentence)" }

    static func from(testName: String) -> Check? {
        guard let match = testName.range(of: #"test_([A-Z]+)_(\d{2})"#, options: .regularExpression) else { return nil }
        let id = testName[match].dropFirst("test_".count).replacingOccurrences(of: "_", with: "-")
        return Check(id: id, sentence: QALines.sentence(for: id))
    }
}

/// Reads check sentences from the walkthrough, found relative to this file so
/// it works from a checkout, a worktree or CI.
enum QALines {
    private static let lines: [String: String] = {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let doc = repo.appendingPathComponent("docs/spec/ACCEPTANCE-CRITERIA.md")
        guard let text = try? String(contentsOf: doc, encoding: .utf8) else { return [:] }
        var found: [String: String] = [:]
        for line in text.split(separator: "\n") where line.hasPrefix("- **") {
            guard let close = line.range(of: "** ") else { continue }
            let id = String(line[line.index(line.startIndex, offsetBy: 4)..<close.lowerBound])
            found[id] = String(line[close.upperBound...])
        }
        return found
    }()

    static func sentence(for id: String) -> String { lines[id] ?? "" }
}

/// Base class of every journey spec. Each test gets its own world: a fresh
/// scenario over a fresh data folder, launched when the first step needs the
/// app and quit afterwards. A failure reads as the QA line it broke.
class AcceptanceCase: XCTestCase {
    private(set) var app = AppDriver()
    private(set) var check = Check(id: "", sentence: "")

    var given: Given { Given(app: app) }
    var when: When { When(app: app) }

    func then<Subject>(_ subject: Subject, file: StaticString = #filePath, line: UInt = #line) -> Then<Subject> {
        Then(subject: subject, check: check, file: file, line: line)
    }

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        // The real app runs each AI stage at the fixture's pace; a whole build
        // or note can take over the default minute.
        executionTimeAllowance = 120
        check = Check.from(testName: name) ?? Check(id: "", sentence: "")
        app = AppDriver()
    }

    override func tearDown() {
        app.shutDown()
        super.tearDown()
    }

    /// Marks a check whose fitness function is not written yet, or whose feature
    /// is not on this branch. Shows as skipped; never as passed, never as an
    /// expected failure.
    func pending(_ reason: String) throws {
        throw XCTSkip("pending: \(reason)")
    }
}

/// Sets the scene. Core verbs live here; each journey adds its own in
/// `<Journey>/<Journey>DSL.swift` with `extension Given { ... }`. Everything
/// here goes into the launch scenario, so the app starts in that state.
struct Given {
    let app: AppDriver

    func fileVaultIsOn() { app.seed { $0.fileVault = "on" } }
    func fileVaultIsOff() { app.seed { $0.fileVault = "off" } }
    func fileVaultCannotBeRead() { app.seed { $0.fileVault = "unknown" } }

    /// The app as this build.
    func buildIs(_ build: AppBuild) { app.seed { $0.tier = build.tier } }

    /// Quits and opens the app again over the same data.
    func appRelaunched() { app.relaunch() }
}

/// Does what the user does, through the real window. Core verbs live here;
/// each journey adds its own in `<Journey>/<Journey>DSL.swift`.
struct When {
    let app: AppDriver
}

/// Which build of the app a check runs against.
enum AppBuild {
    /// The shipped Release build.
    case release
    /// A Debug or developer build.
    case dev

    var tier: String { self == .release ? "production" : "dev" }
}

/// An expectation about `subject`. Journeys add expectations for their own
/// subjects with `extension Then where Subject == X`, and report through
/// `fail`, which puts the check's QA line in front of the message.
struct Then<Subject> {
    let subject: Subject
    let check: Check
    let file: StaticString
    let line: UInt

    func fail(_ message: String) {
        XCTFail("\(check.headline)\n\(message)", file: file, line: line)
    }

    func expect(_ condition: Bool, _ message: @autoclosure () -> String) {
        if !condition { fail(message()) }
    }

    func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ what: String) {
        if actual != expected { fail("expected \(what) to be \(expected), found \(actual)") }
    }
}

/// On-screen wording, one place per string. Each journey adds its own in
/// `<Journey>/<Journey>Copy.swift` with `extension Copy { ... }`.
enum Copy {}
