import XCTest
@testable import Aletheia

/// `DoctorRunner` against stub probes: no real disk, SQLite, keystore or model.
final class DoctorRunnerTests: XCTestCase {
    private struct StubProbes: DoctorProbing {
        var env = DoctorEnvironment(
            appVersion: "9.9.9", buildTier: "production", macOSVersion: "Version 14.5",
            supportedSchemaVersion: 1, homeDirectory: "/Users/tester", dataRoot: "/Users/tester/Aletheia")
        var date = Date(timeIntervalSince1970: 1_700_000_000)
        var folder = DataFolderProbe(
            path: "/Users/tester/Aletheia", exists: true, isDirectory: true,
            readable: true, writable: true, freeBytes: 50 * 1024 * 1024 * 1024)
        var db = DatabaseProbe(
            appFailure: nil,
            inspection: DatabaseInspection(fileExists: true, schemaVersion: 1, integrity: .ok, failure: nil))
        var keystoreProbe = KeystoreProbe.notInUse
        var snapshotProbe = SnapshotProbe()
        var unreadable = UnreadableEntriesProbe.notAvailable
        var whisperFile = WhisperModelFileProbe(modelName: "Small", exists: false, sizeBytes: nil, expectedMB: 488)
        var digest = WhisperDigestProbe.unavailable
        var tools: [ToolHealthCheck] = []
        var timeMachineExcluded: Bool? = false
        var sandboxed: Bool = true
        var appLockState: (enabled: Bool, canAuthenticate: Bool) = (true, true)
        var auditLogWritable: Bool = true

        func environment() -> DoctorEnvironment { env }
        func now() -> Date { date }
        func dataFolder() -> DataFolderProbe { folder }
        func database() -> DatabaseProbe { db }
        func keystore() -> KeystoreProbe { keystoreProbe }
        func snapshots() -> SnapshotProbe { snapshotProbe }
        func unreadableEntries() -> UnreadableEntriesProbe { unreadable }
        func whisperModelFile() -> WhisperModelFileProbe { whisperFile }
        func whisperModelDigest() -> WhisperDigestProbe { digest }
        func toolHealthChecks() async -> [ToolHealthCheck] { tools }
        func timeMachineExclusion() -> Bool? { timeMachineExcluded }
        func isSandboxed() -> Bool { sandboxed }
        func appLock() -> (enabled: Bool, canAuthenticate: Bool) { appLockState }
        func isAuditLogWritable() -> Bool { auditLogWritable }
    }

    private func run(_ probes: StubProbes) async -> DoctorReport {
        await DoctorRunner(probes: probes).run()
    }

    private func check(_ id: String, in report: DoctorReport) -> DoctorCheck? {
        report.checks.first { $0.id == id }
    }

    // MARK: Healthy baseline

    func testHealthyProbesGiveAnAllOKReport() async {
        let report = await run(StubProbes())
        XCTAssertEqual(report.overall, .ok)
        for id in ["dataFolder.present", "dataFolder.access", "dataFolder.space",
                   "database.open", "database.schema", "database.integrity", "backups.snapshots",
                   "backups.timeMachine", "encryption.appLock", "records.auditLog", "tools.sandbox"] {
            XCTAssertEqual(check(id, in: report)?.status, .ok, id)
        }
        XCTAssertNil(check("encryption.keystore", in: report), "skipped when encryption isn't in use")
        XCTAssertNil(check("records.unreadable", in: report), "skipped until the Store API exists")
    }

    // MARK: Data folder

    func testNoDataFolderFailsAndSkipsFolderDependentChecks() async {
        var probes = StubProbes()
        probes.folder = DataFolderProbe(path: nil)
        let report = await run(probes)
        XCTAssertEqual(check("dataFolder.present", in: report)?.status, .failed)
        XCTAssertNil(check("database.open", in: report))
        XCTAssertNil(check("dataFolder.space", in: report))
    }

    func testMissingFolderFails() async {
        var probes = StubProbes()
        probes.folder = DataFolderProbe(path: "/Volumes/Gone/Aletheia", exists: false)
        let report = await run(probes)
        XCTAssertEqual(check("dataFolder.present", in: report)?.status, .failed)
        XCTAssertNotNil(check("dataFolder.present", in: report)?.nextStep)
        XCTAssertNil(check("database.open", in: report))
    }

    func testReadOnlyFolderFails() async {
        var probes = StubProbes()
        probes.folder.writable = false
        let report = await run(probes)
        XCTAssertEqual(check("dataFolder.access", in: report)?.status, .failed)
    }

    func testUnreadableFolderFails() async {
        var probes = StubProbes()
        probes.folder.readable = false
        probes.folder.writable = false
        let report = await run(probes)
        XCTAssertEqual(check("dataFolder.access", in: report)?.status, .failed)
    }

    func testFreeSpaceThresholds() {
        XCTAssertEqual(DoctorRunner.freeSpaceCheck(10 * 1024 * 1024).status, .failed)
        XCTAssertEqual(DoctorRunner.freeSpaceCheck(500 * 1024 * 1024).status, .warning)
        XCTAssertEqual(DoctorRunner.freeSpaceCheck(5 * 1024 * 1024 * 1024).status, .ok)
        XCTAssertEqual(DoctorRunner.freeSpaceCheck(nil).status, .warning)
    }

    // MARK: Database

    func testAppOpenFailureIsAProblemWithANextStep() async {
        var probes = StubProbes()
        probes.db.appFailure = DatabaseOpenFailure(kind: .corrupt, reason: "SQLite error 26: file is not a database")
        let report = await run(probes)
        let open = check("database.open", in: report)
        XCTAssertEqual(open?.status, .failed)
        XCTAssertNotNil(open?.nextStep)
        XCTAssertEqual(report.overall, .failed)
    }

    func testNewerSchemaIsAProblem() async {
        var probes = StubProbes()
        probes.db.inspection.schemaVersion = 7
        let report = await run(probes)
        XCTAssertEqual(check("database.schema", in: report)?.status, .failed)
    }

    func testOlderSchemaIsAWarning() async {
        var probes = StubProbes()
        probes.env.supportedSchemaVersion = 3
        probes.db.inspection.schemaVersion = 2
        let report = await run(probes)
        XCTAssertEqual(check("database.schema", in: report)?.status, .warning)
    }

    func testIntegrityProblemsAreReportedAsACountOnly() async {
        var probes = StubProbes()
        probes.db.inspection.integrity = .problems(count: 3)
        let report = await run(probes)
        let integrity = check("database.integrity", in: report)
        XCTAssertEqual(integrity?.status, .failed)
        XCTAssertTrue(integrity?.detail.contains("3 problems") == true)
        let first = integrity?.nextStep?.lowercased() ?? ""
        XCTAssertTrue(first.hasPrefix("don't delete"), "never lead with a destructive step")
    }

    func testMissingDatabaseFileIsAWarning() async {
        var probes = StubProbes()
        probes.db.inspection = .missing
        let report = await run(probes)
        XCTAssertEqual(check("database.open", in: report)?.status, .warning)
        XCTAssertNil(check("database.integrity", in: report))
    }

    // MARK: Keystore

    func testKeystoreStates() async {
        var probes = StubProbes()
        probes.keystoreProbe = .present(unlocked: true)
        var report = await run(probes)
        XCTAssertEqual(check("encryption.keystore", in: report)?.status, .ok)

        probes.keystoreProbe = .present(unlocked: false)
        report = await run(probes)
        XCTAssertEqual(check("encryption.keystore", in: report)?.status, .ok)

        probes.keystoreProbe = .unreadable
        report = await run(probes)
        XCTAssertEqual(check("encryption.keystore", in: report)?.status, .failed)
    }

    // MARK: Snapshots

    func testSnapshotAgeIsDescribed() async {
        var probes = StubProbes()
        let threeDaysAgo = probes.date.addingTimeInterval(-3 * 86_400 - 60)
        probes.snapshotProbe = SnapshotProbe(snapshotCount: 2, newestSnapshot: threeDaysAgo, preUpgradeCount: 1, newestPreUpgrade: nil)
        let report = await run(probes)
        let snapshots = check("backups.snapshots", in: report)
        XCTAssertEqual(snapshots?.status, .ok)
        XCTAssertTrue(snapshots?.detail.contains("3 snapshots") == true)
        XCTAssertTrue(snapshots?.detail.contains("3 days old") == true)
    }

    func testAgeWording() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertEqual(DoctorRunner.age(of: now, now: now), "less than a day old")
        XCTAssertEqual(DoctorRunner.age(of: now.addingTimeInterval(-86_400), now: now), "1 day old")
        XCTAssertEqual(DoctorRunner.age(of: now.addingTimeInterval(-10 * 86_400), now: now), "10 days old")
    }

    // MARK: Unreadable entries (stubbed until the Store API lands)

    func testUnreadableEntriesCounts() async {
        var probes = StubProbes()
        probes.unreadable = .count(0)
        var report = await run(probes)
        XCTAssertEqual(check("records.unreadable", in: report)?.status, .ok)

        probes.unreadable = .count(2)
        report = await run(probes)
        XCTAssertEqual(check("records.unreadable", in: report)?.status, .failed)
    }

    // MARK: Transcription model

    func testWhisperFileSizeSanity() async {
        var probes = StubProbes()
        let mb: Int64 = 1_048_576
        probes.whisperFile = WhisperModelFileProbe(modelName: "Small", exists: true, sizeBytes: 488 * mb, expectedMB: 488)
        var report = await run(probes)
        XCTAssertEqual(check("tools.whisperFile", in: report)?.status, .ok)

        probes.whisperFile.sizeBytes = 0
        report = await run(probes)
        XCTAssertEqual(check("tools.whisperFile", in: report)?.status, .failed)

        probes.whisperFile.sizeBytes = 100 * mb
        report = await run(probes)
        XCTAssertEqual(check("tools.whisperFile", in: report)?.status, .failed)

        probes.whisperFile.sizeBytes = 2_000 * mb
        report = await run(probes)
        XCTAssertEqual(check("tools.whisperFile", in: report)?.status, .warning)
    }

    func testMissingWhisperFileAddsNoCheckOfItsOwn() async {
        let report = await run(StubProbes())
        XCTAssertNil(check("tools.whisperFile", in: report), "the reused ToolHealth row reports a missing model")
    }

    func testWhisperDigestOnlyAppearsWhenAvailable() async {
        var probes = StubProbes()
        probes.whisperFile = WhisperModelFileProbe(modelName: "Small", exists: true, sizeBytes: 488 * 1_048_576, expectedMB: 488)
        var report = await run(probes)
        XCTAssertNil(check("tools.whisperDigest", in: report))

        probes.digest = .matches
        report = await run(probes)
        XCTAssertEqual(check("tools.whisperDigest", in: report)?.status, .ok)

        probes.digest = .mismatch
        report = await run(probes)
        XCTAssertEqual(check("tools.whisperDigest", in: report)?.status, .failed)
    }

    // MARK: Reused ToolHealth rows

    func testToolHealthRowsAreReusedAndTheDataFolderRowIsDropped() async {
        var probes = StubProbes()
        probes.tools = [
            ToolHealthCheck(kind: .dataFolder, title: "Data folder", status: .ok, detail: "/Users/tester/Aletheia"),
            ToolHealthCheck(kind: .microphone, title: "Microphone access", status: .failed, detail: "Turn this on in System Settings."),
            ToolHealthCheck(kind: .builtInModel, title: "AI summaries & chat", status: .warning, detail: "model missing"),
            ToolHealthCheck(kind: .screenRecording, title: "Call audio capture", status: .ok, detail: "ok")
        ]
        let report = await run(probes)
        XCTAssertNil(check("tools.dataFolder", in: report))
        XCTAssertEqual(check("tools.microphone", in: report)?.status, .failed)
        XCTAssertNotNil(check("tools.microphone", in: report)?.nextStep)
        XCTAssertEqual(check("tools.builtInModel", in: report)?.status, .warning)
        XCTAssertEqual(check("tools.screenRecording", in: report)?.status, .ok)
        XCTAssertNil(check("tools.screenRecording", in: report)?.nextStep)
    }

    // MARK: Time Machine Exclusion

    func testTimeMachineExclusionChecks() async {
        var probes = StubProbes()
        probes.timeMachineExcluded = false
        var report = await run(probes)
        let included = check("backups.timeMachine", in: report)
        XCTAssertEqual(included?.status, .ok)
        XCTAssertNil(included?.action)

        probes.timeMachineExcluded = true
        report = await run(probes)
        let excluded = check("backups.timeMachine", in: report)
        XCTAssertEqual(excluded?.status, .warning)
        XCTAssertEqual(excluded?.action, .openSettings)
        XCTAssertNotNil(excluded?.nextStep)
    }

    // MARK: Audit Log

    func testAuditLogChecks() async {
        var probes = StubProbes()
        probes.auditLogWritable = true
        var report = await run(probes)
        let writable = check("records.auditLog", in: report)
        XCTAssertEqual(writable?.status, .ok)
        XCTAssertNil(writable?.action)

        probes.auditLogWritable = false
        report = await run(probes)
        let unwritable = check("records.auditLog", in: report)
        XCTAssertEqual(unwritable?.status, .failed)
        XCTAssertEqual(unwritable?.action, .openSettings)
        XCTAssertNotNil(unwritable?.nextStep)
    }

    // MARK: App Lock

    func testAppLockChecks() async {
        var probes = StubProbes()
        probes.appLockState = (enabled: true, canAuthenticate: true)
        var report = await run(probes)
        let active = check("encryption.appLock", in: report)
        XCTAssertEqual(active?.status, .ok)
        XCTAssertNil(active?.action)

        probes.appLockState = (enabled: true, canAuthenticate: false)
        report = await run(probes)
        let cannotAuth = check("encryption.appLock", in: report)
        XCTAssertEqual(cannotAuth?.status, .warning)
        XCTAssertEqual(cannotAuth?.action, .openSystemSettings)

        probes.appLockState = (enabled: false, canAuthenticate: true)
        report = await run(probes)
        let disabled = check("encryption.appLock", in: report)
        XCTAssertEqual(disabled?.status, .warning)
        XCTAssertEqual(disabled?.action, .openSettings)
    }

    // MARK: App Sandbox

    func testSandboxChecks() async {
        var probes = StubProbes()
        probes.sandboxed = true
        var report = await run(probes)
        let confined = check("tools.sandbox", in: report)
        XCTAssertEqual(confined?.status, .ok)

        probes.sandboxed = false
        report = await run(probes)
        let unconfined = check("tools.sandbox", in: report)
        XCTAssertEqual(unconfined?.status, .warning)
    }

    // MARK: Doctor Actions on Checks

    func testDoctorActionsAttachedToTroubledChecks() async {
        var probes = StubProbes()
        probes.folder.path = nil
        var report = await run(probes)
        XCTAssertEqual(check("dataFolder.present", in: report)?.action, .openSettings)

        probes = StubProbes()
        probes.unreadable = .count(2)
        report = await run(probes)
        XCTAssertEqual(check("records.unreadable", in: report)?.action, .reviewRecords)

        probes = StubProbes()
        probes.db.inspection.schemaVersion = 99
        report = await run(probes)
        XCTAssertEqual(check("database.schema", in: report)?.action, .checkForUpdates)

        probes = StubProbes()
        probes.tools = [
            ToolHealthCheck(kind: .microphone, title: "Microphone", status: .failed, detail: "denied"),
            ToolHealthCheck(kind: .builtInModel, title: "AI model", status: .warning, detail: "missing")
        ]
        report = await run(probes)
        XCTAssertEqual(check("tools.microphone", in: report)?.action, .openSystemSettings)
        XCTAssertEqual(check("tools.builtInModel", in: report)?.action, .setupAssistant)
    }

    // MARK: Module

    func testDoctorModuleIsProductionTier() {
        XCTAssertEqual(DoctorFeatureModule().tier, .production)
        XCTAssertTrue(FeatureRegistry.compose(tier: .production, from: FeatureRegistry.allModules)
            .contains(id: DoctorFeatureModule.id))
    }
}
