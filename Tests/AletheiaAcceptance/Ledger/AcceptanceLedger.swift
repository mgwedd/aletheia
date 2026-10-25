import Foundation
import XCTest

/// Result of one check in a run.
enum CheckStatus: String, Codable {
    case passed, failed, pending
    /// Skipped by something other than `pending(_:)`.
    case skipped
    /// In the walkthrough but not part of this run (for example a docs-only shard).
    case notRun = "not run"
}

struct LedgerEntry: Codable, Equatable {
    let id: String
    var status: CheckStatus
    var sentence: String
    var message: String?
}

/// Turns entries into the files CI publishes. Pure, so it is unit-tested.
enum LedgerReport {
    static func accepted(_ entries: [LedgerEntry]) -> Int { entries.filter { $0.status == .passed }.count }

    static func json(_ entries: [LedgerEntry]) throws -> Data {
        struct Document: Encodable {
            let accepted: Int
            let total: Int
            let checks: [LedgerEntry]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Document(accepted: accepted(entries), total: entries.count, checks: entries))
    }

    static func markdown(_ entries: [LedgerEntry]) -> String {
        var out = "## Acceptance\n\n**Accepted: \(accepted(entries)) of \(entries.count) checks**\n\n"
        out += "A check is accepted only when its test passed in this run. Pending and failed checks are not.\n\n"
        for status in [CheckStatus.failed, .pending, .skipped, .notRun] {
            let ids = entries.filter { $0.status == status }.map(\.id)
            guard !ids.isEmpty else { continue }
            out += "- \(status.rawValue.prefix(1).uppercased() + status.rawValue.dropFirst()) (\(ids.count)): \(ids.joined(separator: ", "))\n"
        }
        let failures = entries.filter { $0.status == .failed }
        if !failures.isEmpty {
            out += "\n### Failures\n\n"
            for entry in failures {
                out += "- **\(entry.id)** \(entry.sentence)\n"
                if let message = entry.message { out += "  - \(oneLine(message))\n" }
            }
        }
        out += "\n### By journey\n\n| Journey | Checks | Passed | Failed | Pending | Other |\n|---|---:|---:|---:|---:|---:|\n"
        var order: [String] = []
        var groups: [String: [LedgerEntry]] = [:]
        for entry in entries {
            let journey = String(entry.id.prefix { $0 != "-" })
            if groups[journey] == nil { order.append(journey) }
            groups[journey, default: []].append(entry)
        }
        for journey in order {
            let rows = groups[journey] ?? []
            let count = { (status: CheckStatus) in rows.filter { $0.status == status }.count }
            let other = rows.count - count(.passed) - count(.failed) - count(.pending)
            out += "| \(journey) | \(rows.count) | \(count(.passed)) | \(count(.failed)) | \(count(.pending)) | \(other) |\n"
        }
        return out
    }

    private static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 300 ? String(flat.prefix(300)) + "…" : flat
    }
}

/// Watches the run and writes `acceptance-ledger.json` and `acceptance-ledger.md`
/// when the bundle finishes, into `ACCEPTANCE_LEDGER_DIR` (a temp folder if unset).
final class AcceptanceLedger: NSObject, XCTestObservation {
    static let shared = AcceptanceLedger()

    private let lock = NSLock()
    private var failures: [String: [String]] = [:]
    private var pendingReasons: [String: String] = [:]
    private var results: [String: LedgerEntry] = [:]

    /// Called by `AcceptanceCase.pending(_:)`; a skip counts as pending only when
    /// it came through here, which is the `pending:` message convention.
    func notePending(testName: String, reason: String) {
        lock.lock(); defer { lock.unlock() }
        pendingReasons[testName] = reason
    }

    func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
        lock.lock(); defer { lock.unlock() }
        failures[testCase.name, default: []].append(issue.compactDescription)
    }

    func testCaseDidFinish(_ testCase: XCTestCase) {
        guard let check = Check.from(testName: testCase.name) else { return }
        lock.lock(); defer { lock.unlock() }
        let run = testCase.testRun
        var entry = LedgerEntry(id: check.id, status: .passed, sentence: check.sentence, message: nil)
        if run?.hasBeenSkipped == true {
            if let reason = pendingReasons[testCase.name] {
                entry.status = .pending
                entry.message = reason
            } else {
                entry.status = .skipped
                entry.message = failures[testCase.name]?.joined(separator: "; ")
            }
        } else if run?.hasSucceeded == false || failures[testCase.name] != nil {
            entry.status = .failed
            entry.message = failures[testCase.name]?.joined(separator: "; ")
        }
        results[check.id] = entry
    }

    func testBundleDidFinish(_ testBundle: Bundle) {
        lock.lock(); let ran = results; lock.unlock()
        let entries = Self.entries(ran: ran, criteria: SpecDocs.loadCriteria())
        let dir = Self.outputDirectory()
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try LedgerReport.json(entries).write(to: dir.appendingPathComponent("acceptance-ledger.json"))
            try LedgerReport.markdown(entries).write(
                to: dir.appendingPathComponent("acceptance-ledger.md"), atomically: true, encoding: .utf8)
            print("Acceptance ledger written to \(dir.path)")
        } catch {
            print("Acceptance ledger could not be written to \(dir.path): \(error)")
        }
    }

    /// Every check in the walkthrough, in document order, with what this run did to it.
    static func entries(ran: [String: LedgerEntry], criteria: SpecDocs.Criteria) -> [LedgerEntry] {
        var entries = criteria.checks.map { check in
            ran[check.id] ?? LedgerEntry(id: check.id, status: .notRun, sentence: check.sentence, message: nil)
        }
        let known = criteria.ids
        entries += ran.values.filter { !known.contains($0.id) }.sorted { $0.id < $1.id }
        return entries
    }

    static func outputDirectory() -> URL {
        if let path = ProcessInfo.processInfo.environment["ACCEPTANCE_LEDGER_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("acceptance-ledger", isDirectory: true)
    }
}

/// The bundle's `NSPrincipalClass`: XCTest creates it when the bundle loads,
/// which is the moment to start observing.
@objc(AcceptanceLedgerPrincipal)
final class AcceptanceLedgerPrincipal: NSObject {
    override init() {
        super.init()
        XCTestObservationCenter.shared.addTestObserver(AcceptanceLedger.shared)
    }
}
