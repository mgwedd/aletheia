import CryptoKit
import XCTest
@testable import Aletheia

/// Each security event records exactly one activity-log entry, with fixed
/// wording and no names, paths or text.
final class AuditWiringTests: XCTestCase {
    private struct NoopSpotlightIndexer: SpotlightIndexing {
        func replaceIndex(with entries: [SpotlightEntry]) {}
        func clear() {}
    }

    private struct FixedDisk: DiskEncryptionProbing {
        func isDataVolumeEncrypted(_ url: URL) -> Bool? { true }
    }

    /// In-memory stand-in for the keychain.
    private final class MemoryDeviceKeys: DeviceKeyStoring {
        private var keys: [String: SymmetricKey] = [:]
        func save(_ key: SymmetricKey, for id: String) throws { keys[id] = key }
        func load(for id: String) -> SymmetricKey? { keys[id] }
        func delete(for id: String) { keys[id] = nil }
    }

    private var tempRoot: URL!
    private var originalDataRoot: URL?
    private var appModel: AppModel!
    private var encryption: EncryptionManager!
    private var extraRoots: [URL] = []
    private let iterations = 100_000

    override func setUpWithError() throws {
        tempRoot = try makeFolder()
        originalDataRoot = AppSettings.shared.dataRootURL
    }

    override func tearDownWithError() throws {
        appModel = nil
        AppSettings.shared.dataRootURL = originalDataRoot
        for url in [tempRoot!] + extraRoots { try? FileManager.default.removeItem(at: url) }
    }

    private func makeFolder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func isolatedDefaults() -> UserDefaults {
        let name = "AuditWiringTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return defaults
    }

    private func makeModel(deviceKeys: DeviceKeyStoring = MemoryDeviceKeys()) {
        let settings = AppSettings.shared
        settings.dataRootURL = tempRoot
        let root = tempRoot!
        encryption = EncryptionManager(dataRootProvider: { root }, deviceKeys: deviceKeys, defaults: isolatedDefaults())
        appModel = AppModel(settings: settings, encryption: encryption, spotlightIndexer: NoopSpotlightIndexer())
        appModel.diskProbe = FixedDisk()
    }

    private func entries(_ action: AuditAction? = nil) -> [AuditEvent] {
        let all = appModel.audit?.entries() ?? []
        return action.map { wanted in all.filter { $0.action == wanted } } ?? all
    }

    // MARK: - Deletions

    func testDeletingRecordingsRecordsOneEntry() throws {
        makeModel()
        let patient = try XCTUnwrap(appModel.addPatient(name: "Jane Doe"))
        let session = try XCTUnwrap(appModel.startNewSession(for: patient))
        let store = try XCTUnwrap(appModel.store)

        try store.deleteRecordings(for: patient, session: session)
        XCTAssertTrue(entries(.recordDeleted).isEmpty, "nothing was on disk, so nothing was deleted")

        let mic = store.micRecordingURL(for: patient, session: session)
        try Data("audio".utf8).write(to: mic)
        try store.deleteRecordings(for: patient, session: session)

        let recorded = entries(.recordDeleted)
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.subjectID, session.id.uuidString)
        XCTAssertEqual(recorded.first?.detail, "audio recording")
    }

    func testDeletingAChatThreadRecordsOneEntry() throws {
        makeModel()
        let patient = try XCTUnwrap(appModel.addPatient(name: "Jane Doe"))
        let store = try XCTUnwrap(appModel.store)
        let thread = ChatThread(title: "Private question")
        try store.saveChatThread(thread, for: patient)
        XCTAssertTrue(entries(.recordDeleted).isEmpty)

        try store.deleteChatThread(id: thread.id, for: patient)

        let recorded = entries(.recordDeleted)
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.subjectID, thread.id.uuidString)
        XCTAssertEqual(recorded.first?.detail, "chat thread")
    }

    func testDeletingACommentRecordsOneEntryWithoutItsText() throws {
        makeModel()
        let comments = try XCTUnwrap(appModel.commentStore)
        let sessionID = UUID()
        let comment = try XCTUnwrap(comments.addComment(sessionID: sessionID, quotedText: "secret quote", body: "secret body"))

        XCTAssertTrue(comments.deleteComment(id: comment.id))

        let recorded = entries(.recordDeleted)
        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.subjectID, sessionID.uuidString)
        XCTAssertEqual(recorded.first?.detail, "comment")
        XCTAssertFalse(String(describing: recorded).contains("secret"))
    }

    // MARK: - Data folder

    func testChangingTheDataFolderRecordsInBothLogs() throws {
        makeModel()
        XCTAssertTrue(entries(.dataFolderChanged).isEmpty, "launch is a baseline, not a change")
        appModel.rebuildStore()
        XCTAssertTrue(entries(.dataFolderChanged).isEmpty, "rebuilding the same folder isn't a change")

        let newRoot = try makeFolder()
        extraRoots.append(newRoot)
        AppSettings.shared.dataRootURL = newRoot
        appModel.rebuildStore()

        XCTAssertEqual(entries(.dataFolderChanged).map(\.detail), ["Opened this folder"])
        let oldLog = AuditLog(root: tempRoot)
        XCTAssertEqual(oldLog.entries().filter { $0.action == .dataFolderChanged }.map(\.detail), ["Moved away from this folder"])
        let paths = (oldLog.entries() + entries()).compactMap(\.detail)
        XCTAssertFalse(paths.contains { $0.contains(newRoot.lastPathComponent) || $0.contains("/") })
    }

    // MARK: - Settings

    func testSecuritySettingChangesRecordOncePerChange() throws {
        makeModel()
        let settings = AppSettings(defaults: isolatedDefaults())
        settings.appLockEnabled = true
        settings.spotlightIndexingEnabled = false
        settings.idleAutoLockMinutes = 15
        settings.lockWhenHidden = false
        settings.hideFromScreenSharing = false
        let model = appModel!
        settings.onAuditedChange = { model.recordAudit(.securitySettingChanged, detail: $0) }

        settings.appLockEnabled = true   // unchanged
        settings.appLockEnabled = false
        settings.idleAutoLockMinutes = 0
        settings.spotlightIndexingEnabled = true
        settings.lockWhenHidden = true
        settings.hideFromScreenSharing = true

        XCTAssertEqual(entries(.securitySettingChanged).compactMap(\.detail), [
            "App lock: off",
            "Idle lock timeout: never",
            "Spotlight indexing: on",
            "Lock when hidden: on",
            "Hide from screen sharing: on",
        ])
    }

    func testRememberingTheKeyOnThisMacRecordsEachChangeOnce() throws {
        makeModel()
        try encryption.enable(passphrase: "test-passphrase-1", iterations: iterations)
        XCTAssertEqual(entries(.encryptionEnabled).count, 1)

        try encryption.rememberOnDevice()
        try encryption.rememberOnDevice()   // already remembered
        encryption.forgetOnDevice()
        encryption.forgetOnDevice()         // already forgotten

        XCTAssertEqual(entries(.securitySettingChanged).compactMap(\.detail), [
            "Unlock automatically on this Mac: on",
            "Unlock automatically on this Mac: off",
        ])
    }

    func testDisablingEncryptionIsOneEntryEvenWhenTheKeyWasRemembered() throws {
        makeModel()
        try encryption.enable(passphrase: "test-passphrase-1", iterations: iterations)
        try encryption.rememberOnDevice()
        let before = entries(.securitySettingChanged).count

        try encryption.disable()

        XCTAssertEqual(entries(.encryptionDisabled).count, 1)
        XCTAssertEqual(entries(.securitySettingChanged).count, before)
    }

    func testRecoveryKeyAndPassphraseChangesRecordOneEntryEach() throws {
        makeModel()
        try encryption.enable(passphrase: "test-passphrase-1", recoveryKey: RecoveryKey.generate(), iterations: iterations)

        _ = try encryption.replaceRecoveryKey(iterations: iterations)
        XCTAssertEqual(entries(.encryptionKeyChanged).compactMap(\.detail), ["Recovery key replaced"])

        try encryption.addRecoveryPassphrase("another-passphrase-2", iterations: iterations)
        XCTAssertEqual(entries(.encryptionKeyChanged).compactMap(\.detail), [
            "Recovery key replaced", "Recovery passphrase added",
        ])
    }

    // MARK: - Alerts

    func testRecordingProblemsShowAsDismissibleAlerts() {
        makeModel()
        appModel.noteRecordingProblem(.recordingEncryptionDeferred)
        appModel.noteRecordingProblem(.microphoneRestartFailed)
        appModel.noteRecordingProblem(.microphoneRestartFailed)
        XCTAssertEqual(appModel.securityAlerts, [.recordingEncryptionDeferred, .microphoneRestartFailed])
        appModel.dismissSecurityAlert(.recordingEncryptionDeferred)
        XCTAssertEqual(appModel.securityAlerts, [.microphoneRestartFailed])
    }

    func testThreeFailedUnlocksRaisesAlertAndOneEntry() {
        makeModel()
        let start = Date()
        appModel.noteUnlockFailure("Authentication failed", now: start)
        appModel.noteUnlockFailure("Authentication failed", now: start.addingTimeInterval(30))
        XCTAssertTrue(appModel.securityAlerts.isEmpty)
        XCTAssertTrue(entries(.repeatedUnlockFailures).isEmpty)

        appModel.noteUnlockFailure("Authentication failed", now: start.addingTimeInterval(60))

        XCTAssertEqual(appModel.securityAlerts, [.repeatedUnlockFailures(attempts: 3, minutes: 5)])
        XCTAssertEqual(entries(.appUnlockFailed).count, 3)
        XCTAssertEqual(entries(.repeatedUnlockFailures).count, 1)

        appModel.dismissSecurityAlert(appModel.securityAlerts[0])
        XCTAssertTrue(appModel.securityAlerts.isEmpty)
    }

    func testASuccessfulUnlockStartsTheCountOver() {
        makeModel()
        let start = Date()
        appModel.noteUnlockFailure("x", now: start)
        appModel.noteUnlockFailure("x", now: start.addingTimeInterval(10))
        appModel.noteUnlockSuccess()
        appModel.noteUnlockFailure("x", now: start.addingTimeInterval(20))
        XCTAssertTrue(appModel.securityAlerts.isEmpty)
    }

    func testAuditWriteFailureIsShownByTheModel() throws {
        makeModel()
        let log = try XCTUnwrap(appModel.audit)
        XCTAssertFalse(appModel.auditWriteFailed)

        try log.core?.executeRaw("CREATE TRIGGER block_insert BEFORE INSERT ON audit_events BEGIN SELECT RAISE(ABORT, 'blocked'); END;")
        appModel.recordAudit(.appLocked)
        XCTAssertTrue(appModel.auditWriteFailed)

        try log.core?.executeRaw("DROP TRIGGER block_insert;")
        appModel.recordAudit(.appLocked)
        XCTAssertFalse(appModel.auditWriteFailed)
    }

    private func tamperedLogFolder() throws {
        let key = SymmetricKey(size: .bits256)
        let log = AuditLog(root: tempRoot, keyProvider: { key })
        try log.record(.appUnlocked)
        try log.record(.appLocked)
        try log.record(.appUnlocked)
        try log.core?.executeRaw("DROP TRIGGER IF EXISTS audit_no_update;")
        try log.core?.executeRaw("UPDATE audit_events SET detail = 'tampered' WHERE seq = 2;")
    }

    private func waitForAlerts(_ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(10)
        while !condition(), Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }

    func testBrokenChainRaisesAlertOnLaunch() throws {
        try tamperedLogFolder()
        makeModel()   // launch: verifies the chain in the background
        waitForAlerts { !self.appModel.securityAlerts.isEmpty }

        guard case .auditLogBroken(let entry)? = appModel.securityAlerts.first else { return XCTFail("no alert") }
        XCTAssertEqual(appModel.securityAlerts.count, 1)
        XCTAssertEqual(entries(.integrityCheckFailed).compactMap(\.detail), ["Chain broken at entry #\(entry)"])

        // The same break again (the Verify button, or the next launch) is neither re-recorded nor duplicated.
        appModel.applyIntegrityResult(appModel.audit!.verifyIntegrity())
        XCTAssertEqual(appModel.securityAlerts.count, 1)
        XCTAssertEqual(entries(.integrityCheckFailed).count, 1)
    }

    func testIntactChainRaisesNoAlertOnLaunch() throws {
        makeModel()
        waitForAlerts { false }   // let the background check finish
        let deadline = Date().addingTimeInterval(0.5)
        while Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(appModel.securityAlerts.isEmpty)
        XCTAssertTrue(entries(.integrityCheckFailed).isEmpty)
    }

    // MARK: - Exports

    private struct SilentNotifier: AppNotifying {
        func requestAuthorization() async {}
        func post(_ content: AppNotificationContent) async {}
    }

    @MainActor
    func testAFailedExportJobReportsOnFailed() async throws {
        struct Boom: Error {}
        let center = ExportJobCenter(notifier: SilentNotifier())
        var failures = 0
        var successes = 0
        center.start(
            destination: tempRoot.appendingPathComponent("out"),
            onFinished: { _ in successes += 1 },
            onFailed: { failures += 1 },
            work: { _, _ in throw Boom() }
        )
        for _ in 0..<600 where center.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(failures, 1)
        XCTAssertEqual(successes, 0)
    }
}

final class FailedUnlockMonitorTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    func testRaisesOnTheThirdFailureWithinTheWindow() {
        var monitor = FailedUnlockMonitor(threshold: 3, window: 300)
        XCTAssertFalse(monitor.recordFailure(at: t0))
        XCTAssertFalse(monitor.recordFailure(at: t0.addingTimeInterval(100)))
        XCTAssertTrue(monitor.recordFailure(at: t0.addingTimeInterval(200)))
    }

    func testFailuresOutsideTheWindowDoNotCount() {
        var monitor = FailedUnlockMonitor(threshold: 3, window: 300)
        XCTAssertFalse(monitor.recordFailure(at: t0))
        XCTAssertFalse(monitor.recordFailure(at: t0.addingTimeInterval(200)))
        XCTAssertFalse(monitor.recordFailure(at: t0.addingTimeInterval(400)), "the first one has aged out")
    }

    func testRaisesOncePerRunThenStartsOver() {
        var monitor = FailedUnlockMonitor(threshold: 3, window: 300)
        let raised = (0..<6).map { monitor.recordFailure(at: t0.addingTimeInterval(Double($0))) }
        XCTAssertEqual(raised, [false, false, true, false, false, true])
    }

    func testSuccessClearsTheCount() {
        var monitor = FailedUnlockMonitor(threshold: 3, window: 300)
        _ = monitor.recordFailure(at: t0)
        _ = monitor.recordFailure(at: t0.addingTimeInterval(1))
        monitor.recordSuccess()
        XCTAssertFalse(monitor.recordFailure(at: t0.addingTimeInterval(2)))
    }
}
