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

/// Base class of every journey spec. Gives each test a fresh in-process app over
/// a throwaway data folder, torn down afterwards, and the `given` / `when` /
/// `then` entry points. A failure reads as the QA line it broke.
@MainActor
class AcceptanceCase: XCTestCase {
    private(set) var app: InProcessDriver!
    private(set) var check = Check(id: "", sentence: "")

    var given: Given { Given(app: app) }
    var when: When { When(app: app) }

    func then<Subject>(_ subject: Subject, file: StaticString = #filePath, line: UInt = #line) -> Then<Subject> {
        Then(subject: subject, check: check, file: file, line: line)
    }

    override func setUp() async throws {
        try await super.setUp()
        // A failed expectation is recorded and the test runs on to its end, so
        // teardown always runs and an async test never hangs on a stopped check.
        continueAfterFailure = true
        check = Check.from(testName: name) ?? Check(id: "", sentence: "")
        app = try InProcessDriver()
    }

    override func tearDown() async throws {
        await app?.shutDown()
        app = nil
        try await super.tearDown()
    }

    /// Marks a check whose fitness function is not written yet. Shows as
    /// skipped; never as passed, never as an expected failure.
    func pending(_ reason: String) throws {
        AcceptanceLedger.shared.notePending(testName: name, reason: reason)
        throw XCTSkip("pending: \(reason)")
    }
}
