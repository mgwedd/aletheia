import XCTest
import SQLite3
@testable import Aletheia

/// The copied Doctor report must be PHI-safe: no data-folder file names below the
/// root, home directory shown as `~`. Also pins the failure guidance's "never
/// destructive first" rule and the read-only database inspector.
final class DoctorReportTests: XCTestCase {
    private let home = "/Users/mike"
    private let root = "/Users/mike/Documents/Aletheia"

    // MARK: Redaction

    func testHomeDirectoryBecomesTilde() {
        let redactor = DoctorRedactor(homeDirectory: home, dataRoot: root)
        XCTAssertEqual(redactor.redact("Found at /Users/mike/Documents/Aletheia."), "Found at ~/Documents/Aletheia.")
    }

    func testOtherUsersHomeIsAlsoRedacted() {
        let redactor = DoctorRedactor(homeDirectory: home, dataRoot: nil)
        XCTAssertEqual(redactor.redact("copy in /Users/someoneelse/Desktop"), "copy in ~/Desktop")
    }

    func testHomeMatchRespectsNameBoundaries() {
        let redactor = DoctorRedactor(homeDirectory: home, dataRoot: nil)
        let out = redactor.redact("/Users/mike2/x and /Users/mike/y")
        XCTAssertFalse(out.contains("mike"))
        XCTAssertEqual(out, "~/x and ~/y")
    }

    func testNonStandardHomeDirectoryIsRedacted() {
        let redactor = DoctorRedactor(homeDirectory: "/var/root", dataRoot: nil)
        XCTAssertEqual(redactor.redact("at /var/root/Documents"), "at ~/Documents")
    }

    func testPathsBelowTheDataRootAreCollapsed() {
        let redactor = DoctorRedactor(homeDirectory: home, dataRoot: root)
        let out = redactor.redact("Couldn't read /Users/mike/Documents/Aletheia/Patients/Jane-Doe/2024-01-05_Session/session.json")
        XCTAssertFalse(out.contains("Jane"))
        XCTAssertFalse(out.contains("session.json"))
        XCTAssertFalse(out.contains("Patients"))
        XCTAssertTrue(out.contains("<data folder>/…"))
    }

    func testRedactionLeavesOtherLinesAlone() {
        let redactor = DoctorRedactor(homeDirectory: home, dataRoot: root)
        let out = redactor.redact("line one\n\(root)/Patients/Jane-Doe\nline three")
        XCTAssertEqual(out, "line one\n<data folder>/…\nline three")
    }

    // MARK: Report text

    private func report(checks: [DoctorCheck]) -> DoctorReport {
        DoctorReport(
            checks: checks,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            environment: DoctorEnvironment(
                appVersion: "2.22.0", buildTier: "production", macOSVersion: "Version 14.5 (Build 23F79)",
                supportedSchemaVersion: 1, homeDirectory: home, dataRoot: root)
        )
    }

    func testPlainTextHasVersionsCountsAndNoPathsBelowTheRoot() {
        let leaky = DoctorCheck(
            id: "x", category: .records, title: "Patient and session records", status: .failed,
            detail: "Couldn't read \(root)/Patients/Jane-Doe/patient.json",
            nextStep: "Copy \(home)/Documents/Aletheia aside.")
        let ok = DoctorCheck(id: "y", category: .database, title: "Database opens", status: .ok, detail: "Fine.")
        let text = report(checks: [leaky, ok]).plainText()

        XCTAssertTrue(text.contains("Aletheia 2.22.0 (production build)"))
        XCTAssertTrue(text.contains("macOS Version 14.5"))
        XCTAssertTrue(text.contains("1 problem(s), 0 warning(s), 1 OK"))
        XCTAssertTrue(text.contains("[Problem] Patient and session records"))
        XCTAssertFalse(text.contains("Jane"))
        XCTAssertFalse(text.contains("patient.json"))
        XCTAssertFalse(text.contains("/Users/mike"))
        XCTAssertTrue(text.contains("~/Documents/Aletheia aside."))
    }

    func testOverallIsTheWorstStatus() {
        let ok = DoctorCheck(id: "a", category: .database, title: "a", status: .ok, detail: "")
        let warn = DoctorCheck(id: "b", category: .database, title: "b", status: .warning, detail: "")
        let fail = DoctorCheck(id: "c", category: .database, title: "c", status: .failed, detail: "")
        XCTAssertEqual(report(checks: []).overall, .ok)
        XCTAssertEqual(report(checks: [ok, warn]).overall, .warning)
        XCTAssertEqual(report(checks: [ok, warn, fail]).overall, .failed)
    }

    func testGroupedFollowsCategoryOrderAndDropsEmptyOnes() {
        let t = DoctorCheck(id: "t", category: .tools, title: "t", status: .ok, detail: "")
        let d = DoctorCheck(id: "d", category: .dataFolder, title: "d", status: .ok, detail: "")
        XCTAssertEqual(report(checks: [t, d]).grouped.map(\.category), [.dataFolder, .tools])
    }

    func testHeadlineCountsProblemsAndWarningsWithCorrectPlurals() {
        func check(_ id: String, _ status: DoctorStatus) -> DoctorCheck {
            DoctorCheck(id: id, category: .tools, title: id, status: status, detail: "")
        }
        XCTAssertEqual(report(checks: []).headline, "All checks passed")
        XCTAssertEqual(report(checks: [check("a", .ok)]).headline, "All checks passed")
        XCTAssertEqual(report(checks: [check("a", .failed), check("b", .warning), check("c", .warning)]).headline, "1 problem, 2 warnings")
        XCTAssertEqual(report(checks: [check("a", .failed), check("b", .failed), check("c", .warning)]).headline, "2 problems, 1 warning")
        XCTAssertEqual(report(checks: [check("a", .warning)]).headline, "1 warning")
        XCTAssertEqual(report(checks: [check("a", .failed), check("b", .ok)]).headline, "1 problem")
    }

    func testGroupedOnlyIssuesDropsOkChecksAndEmptyCategories() {
        let okTool = DoctorCheck(id: "t", category: .tools, title: "t", status: .ok, detail: "")
        let warnData = DoctorCheck(id: "d", category: .dataFolder, title: "d", status: .warning, detail: "")
        let okData = DoctorCheck(id: "d2", category: .dataFolder, title: "d2", status: .ok, detail: "")
        let groups = report(checks: [okTool, warnData, okData]).grouped(onlyIssues: true)
        XCTAssertEqual(groups.map(\.category), [.dataFolder])
        XCTAssertEqual(groups.first?.checks.map(\.id), ["d"])
        XCTAssertEqual(report(checks: [okTool, warnData, okData]).grouped(onlyIssues: false).count, 2)
    }

    func testCheckCountAndLastRunDescriptions() {
        let c = DoctorCheck(id: "a", category: .tools, title: "a", status: .ok, detail: "")
        XCTAssertEqual(report(checks: [c]).checkCountDescription, "1 check")
        XCTAssertEqual(report(checks: [c, c]).checkCountDescription, "2 checks")
        let r = report(checks: [c])
        XCTAssertEqual(r.lastRunDescription(now: r.generatedAt.addingTimeInterval(10)), "just now")
        XCTAssertNotEqual(r.lastRunDescription(now: r.generatedAt.addingTimeInterval(600)), "just now")
    }

    // MARK: Guidance: never destructive first

    func testEveryKindHasStepsAndNoneLeadWithADestructiveVerb() {
        let destructive = ["delete", "remove", "erase", "reset", "trash", "wipe", "re-create", "recreate"]
        for kind in DatabaseOpenFailure.Kind.allCases {
            let failure = DatabaseOpenFailure(kind: kind, reason: "r")
            let guidance = DatabaseFailureGuidance.guidance(for: failure, dataFolder: "/Users/mike/Aletheia")
            XCTAssertEqual(guidance.headline, "Notes and chat can't be saved right now")
            XCTAssertFalse(guidance.steps.isEmpty, "\(kind)")
            XCTAssertFalse(guidance.explanation.isEmpty, "\(kind)")
            for step in guidance.steps {
                let first = step.lowercased().split(separator: " ").first.map(String.init) ?? ""
                XCTAssertFalse(destructive.contains(first), "\(kind): step starts destructively: \(step)")
            }
        }
    }

    func testCorruptGuidanceCopiesAsideAndRestoresByRenaming() {
        let failure = DatabaseOpenFailure(kind: .corrupt, reason: "r")
        let guidance = DatabaseFailureGuidance.guidance(for: failure, dataFolder: "/Users/mike/Aletheia")
        XCTAssertTrue(guidance.steps[0].lowercased().hasPrefix("do not delete"))
        XCTAssertTrue(guidance.steps[1].lowercased().contains("copy the whole data folder aside"))
        let joined = guidance.steps.joined(separator: "\n")
        XCTAssertTrue(joined.contains("/Users/mike/Aletheia"), "names where the data folder is")
        XCTAssertTrue(joined.contains(".backups/snapshots"))
        XCTAssertTrue(joined.contains(".backups/migrations"))
        XCTAssertTrue(joined.contains(".snapshots"), "mentions the legacy folder names")
        XCTAssertTrue(joined.contains("Backups"))
        XCTAssertTrue(joined.contains("rename"))
    }

    func testNewerSchemaGuidanceSaysUpdate() {
        let failure = DatabaseOpenFailure(kind: .schemaNewerThanApp, reason: "r")
        let guidance = DatabaseFailureGuidance.guidance(for: failure, dataFolder: nil)
        XCTAssertTrue(guidance.steps.joined().contains("Update Aletheia"))
    }

    func testDiskFullGuidanceSaysFreeSpaceAndCloseOtherApps() {
        let failure = DatabaseOpenFailure(kind: .lockedOrDiskFull, reason: "r")
        let text = DatabaseFailureGuidance.guidance(for: failure, dataFolder: nil).steps.joined(separator: " ").lowercased()
        XCTAssertTrue(text.contains("free up disk space"))
        XCTAssertTrue(text.contains("no other program"))
    }

    // MARK: Read-only inspector

    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("DoctorReportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testInspectorReportsMissingFile() {
        let result = DatabaseInspector.inspect(databaseAt: tempRoot.appendingPathComponent("nope.sqlite"))
        XCTAssertEqual(result, .missing)
    }

    func testInspectorReadsAHealthyDatabase() throws {
        let url = tempRoot.appendingPathComponent("ok.sqlite")
        do {
            let core = try XCTUnwrap(SQLitePersistenceCore(url: url))
            _ = core.schemaVersion
        }
        let result = DatabaseInspector.inspect(databaseAt: url)
        XCTAssertTrue(result.fileExists)
        XCTAssertEqual(result.schemaVersion, SchemaMigrator.latestVersion)
        XCTAssertEqual(result.integrity, .ok)
        XCTAssertNil(result.failure)
    }

    func testInspectorFlagsANewerSchema() throws {
        let url = tempRoot.appendingPathComponent("future.sqlite")
        var db: OpaquePointer?
        guard sqlite3_open(url.path, &db) == SQLITE_OK, let db else { throw XCTSkip("no raw sqlite") }
        sqlite3_exec(db, "PRAGMA user_version = \(SchemaMigrator.latestVersion + 1);", nil, nil, nil)
        sqlite3_close(db)

        let result = DatabaseInspector.inspect(databaseAt: url)
        XCTAssertEqual(result.failure?.kind, .schemaNewerThanApp)
        XCTAssertEqual(result.schemaVersion, SchemaMigrator.latestVersion + 1)
    }

    func testInspectorFlagsAGarbageFileAndNeverModifiesIt() throws {
        let url = tempRoot.appendingPathComponent("junk.sqlite")
        let bytes = Data(String(repeating: "not a database ", count: 500).utf8)
        try bytes.write(to: url)

        let result = DatabaseInspector.inspect(databaseAt: url)
        XCTAssertEqual(result.failure?.kind, .corrupt)
        XCTAssertEqual(result.integrity, .notRun)
        XCTAssertEqual(try Data(contentsOf: url), bytes, "read-only: the file is untouched")
    }
}
