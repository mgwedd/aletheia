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

    func testUUIDsAreRedacted() {
        let redactor = DoctorRedactor(homeDirectory: home, dataRoot: root)
        let out = redactor.redact("Patient 3F2504E0-4F89-41D3-9A0C-0305E82C3301 and 3f2504e0-4f89-41d3-9a0c-0305e82c3302 failed")
        XCTAssertEqual(out, "Patient <id> and <id> failed")
    }

    func testPatientAndSessionFolderNamesRedactedEvenOutsideTheDataRoot() {
        let redactor = DoctorRedactor(homeDirectory: home, dataRoot: root)
        let out = redactor.redact("see Patients/jane-doe-4f2a/notes.json and 2024-01-05_Intake-Jane for details")
        XCTAssertFalse(out.contains("jane"))
        XCTAssertFalse(out.contains("Jane"))
        XCTAssertFalse(out.contains("notes.json"))
        XCTAssertTrue(out.contains("<patient folder>"))
        XCTAssertTrue(out.contains("<session folder>"))
    }

    func testTimestampsAreNotMistakenForSessionFolders() {
        let redactor = DoctorRedactor(homeDirectory: home, dataRoot: root)
        XCTAssertEqual(redactor.redact("Generated: 2023-11-14T22:13:20Z"), "Generated: 2023-11-14T22:13:20Z")
    }

    func testKnownTermsAreRedactedByValueCaseInsensitively() {
        let redactor = DoctorRedactor(homeDirectory: home, dataRoot: nil, knownTerms: ["Jane Doe", "jane-doe", "mike", "  ", "x"])
        let out = redactor.redact("Error for JANE DOE (jane-doe) owned by Mike; x stays")
        XCTAssertEqual(out, "Error for <redacted> (<redacted>) owned by <redacted>; x stays")
    }

    private func patientTerms(_ name: String, slug: String = "jane-doe-4f2a") -> [String] {
        LiveDoctorProbes.knownTerms(for: [Patient(name: name, slug: slug)])
    }

    func testErrorStringContainingNameIsRedacted() {
        let redactor = DoctorRedactor(homeDirectory: home, dataRoot: root, knownTerms: patientTerms("Jane Smith"))
        let out = redactor.redact("Couldn't decrypt note for Jane Smith; Smith's file is damaged, ask Jane.")
        XCTAssertFalse(out.contains("Jane"))
        XCTAssertFalse(out.contains("Smith"))
        XCTAssertTrue(out.contains("is damaged"))
    }

    func testPatientSlugOutsideDataRootIsRedacted() {
        let redactor = DoctorRedactor(homeDirectory: home, dataRoot: root, knownTerms: patientTerms("Jane Doe"))
        let out = redactor.redact("Restore failed for jane-doe-4f2a (copy kept in /Volumes/Backup/jane-doe-4f2a/notes)")
        XCTAssertFalse(out.contains("jane-doe-4f2a"))
        XCTAssertFalse(out.contains("Volumes"))
    }

    func testNameMatchingIgnoresCaseAndDiacritics() {
        let redactor = DoctorRedactor(homeDirectory: home, dataRoot: nil, knownTerms: patientTerms("José Núñez", slug: "p1"))
        let out = redactor.redact("failed: JOSE NUNEZ, jose, José, núñez")
        XCTAssertEqual(out, "failed: <redacted>, <redacted>, <redacted>, <redacted>")
    }

    func testNamesWithRegexCharactersAreMatchedLiterally() {
        let redactor = DoctorRedactor(homeDirectory: home, dataRoot: nil, knownTerms: ["J.* (Jr)", "O'Brien+"])
        let out = redactor.redact("for J.* (Jr) and O'Brien+ but not Jx anything")
        XCTAssertEqual(out, "for <redacted> and <redacted> but not Jx anything")
    }

    func testShortNamePartsAndInitialsAreNotRedactedButFullNameIs() {
        let terms = patientTerms("Al Li Roe", slug: "xy")
        XCTAssertTrue(terms.contains("Al Li Roe"))
        XCTAssertFalse(terms.contains("Al"))
        XCTAssertFalse(terms.contains("Roe"))
        let redactor = DoctorRedactor(homeDirectory: home, dataRoot: nil, knownTerms: terms)
        XCTAssertEqual(redactor.redact("Al Li Roe: all rows ok"), "<redacted>: all rows ok")
    }

    func testNameDoesNotMangleLongerWords() {
        let redactor = DoctorRedactor(homeDirectory: home, dataRoot: nil, knownTerms: ["Ann"])
        XCTAssertEqual(redactor.redact("Annual check for Ann"), "Annual check for <redacted>")
    }

    func testEnvironmentDoesNotRedactTheSandboxContainerFolderName() {
        let env = DoctorEnvironment.current(dataRoot: nil)
        XCTAssertFalse(env.knownTerms.contains("Data"), "the container's `Data` folder would blank out \"Data folder\"")
        let check = DoctorCheck(id: "a", category: .dataFolder, title: "Data folder present", status: .ok, detail: "Found.")
        let text = DoctorReport(checks: [check], generatedAt: Date(), environment: env).plainText()
        XCTAssertTrue(text.contains("[OK] Data folder present"), text)
    }

    func testDoctorEnvironmentCarriesPatientNamesFromTheLiveProbes() {
        let patients = [Patient(name: "Jane Doe", slug: "jane-doe-4f2a")]
        let probes = LiveDoctorProbes(
            dataRoot: nil, appDatabaseFailure: nil, encryptionInUse: false, encryptionUnlocked: false,
            whisperModelPath: URL(fileURLWithPath: "/tmp/none"), whisperModelName: "Small",
            whisperExpectedMB: 1, whisperExpectedSHA256: "", toolHealthProvider: { [] },
            callAudioDiagnostics: nil, knownTerms: LiveDoctorProbes.knownTerms(for: patients))
        let env = probes.environment()
        XCTAssertTrue(env.knownTerms.contains("Jane Doe"))
        XCTAssertTrue(env.knownTerms.contains("jane-doe-4f2a"))

        let check = DoctorCheck(
            id: "z", category: .records, title: "Records", status: .failed,
            detail: "Couldn't open the record for Jane Doe")
        let text = DoctorReport(checks: [check], generatedAt: Date(), environment: env).plainText()
        XCTAssertFalse(text.contains("Jane"), text)
        XCTAssertTrue(text.contains("<redacted>"))
    }

    func testDataRootOutsideHomeIsRedactedEvenWithoutATrailingPath() {
        let redactor = DoctorRedactor(homeDirectory: home, dataRoot: "/Volumes/DrSmithPractice/Aletheia")
        let out = redactor.redact("Data folder is missing: /Volumes/DrSmithPractice/Aletheia.")
        XCTAssertEqual(out, "Data folder is missing: <data folder>.")
    }

    func testAnyRemainingAbsolutePathIsDropped() {
        let redactor = DoctorRedactor(homeDirectory: home, dataRoot: root)
        let out = redactor.redact("Moved to /Volumes/Backup Drive/Clinic and /tmp/x/y.sqlite ok; Settings > Data Folder, and/or more")
        XCTAssertFalse(out.contains("Volumes"))
        XCTAssertFalse(out.contains("tmp"))
        XCTAssertFalse(out.contains("y.sqlite"))
        XCTAssertTrue(out.contains("and/or more"))
        XCTAssertTrue(out.contains("Settings > Data Folder"))
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

    func testGoldenReportHasNoHomePathUUIDOrPatientName() {
        let uuid = "3F2504E0-4F89-41D3-9A0C-0305E82C3301"
        let checks = [
            DoctorCheck(id: "a", category: .records, title: "Records", status: .failed,
                        detail: "Couldn't read \(root)/Patients/\(uuid)/patient.json for Jane Doe",
                        nextStep: "Ask jane-doe's clinician; copy /Volumes/Other/Aletheia aside."),
            DoctorCheck(id: "b", category: .dataFolder, title: "Folder", status: .warning,
                        detail: "Owned by mike at \(home)/Library and 2024-01-05_Intake-Jane"),
        ]
        var r = report(checks: checks)
        r = DoctorReport(
            checks: r.checks, generatedAt: r.generatedAt,
            environment: DoctorEnvironment(
                appVersion: "2.22.0", buildTier: "production", macOSVersion: "Version 14.5 (Build 23F79)",
                supportedSchemaVersion: 1, homeDirectory: home, dataRoot: root,
                knownTerms: ["Jane Doe", "jane-doe", "Jane", "mike"]))
        let text = r.plainText()
        for banned in ["/Users", "/Volumes", uuid, "Jane", "jane", "mike", "patient.json", "Patients"] {
            XCTAssertFalse(text.contains(banned), "leaked \(banned):\n\(text)")
        }
        XCTAssertTrue(text.contains("Generated: 2023-11-14T22:13:20Z"))
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
