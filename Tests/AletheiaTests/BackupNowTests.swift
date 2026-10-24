import CryptoKit
import XCTest
@testable import Aletheia

private final class MemoryDeviceKeys: DeviceKeyStoring {
    var storage: [String: SymmetricKey] = [:]
    func save(_ key: SymmetricKey, for id: String) throws { storage[id] = key }
    func load(for id: String) -> SymmetricKey? { storage[id] }
    func delete(for id: String) { storage[id] = nil }
}

private struct NoopSpotlight: SpotlightIndexing {
    func replaceIndex(with entries: [SpotlightEntry]) {}
    func clear() {}
}

/// "Back up now": writes an encrypted archive to a user-chosen local folder,
/// refuses synced folders, and records the backup exactly once on success and
/// never otherwise. Everything runs in a temp folder with in-memory key storage.
final class BackupNowTests: XCTestCase {
    private var base: URL!
    private var dataRoot: URL!
    private var destination: URL!
    private var originalRoot: URL?
    private var originalFlag = false
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var originalScratch: URL!
    private var encryption: EncryptionManager!
    private var appModel: AppModel!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("BackupNowTests-\(UUID().uuidString)", isDirectory: true)
        dataRoot = base.appendingPathComponent("data", isDirectory: true)
        destination = base.appendingPathComponent("out", isDirectory: true)
        for dir in [dataRoot!, destination!] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        originalScratch = PrivateStaging.root
        PrivateStaging.root = base.appendingPathComponent("Scratch", isDirectory: true)
        suiteName = "BackupNowTests-\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let settings = AppSettings.shared
        originalRoot = settings.dataRootURL
        originalFlag = settings.localEncryptedBackupEnabled
        settings.dataRootURL = dataRoot
        settings.localEncryptedBackupEnabled = false
        let root = dataRoot!
        encryption = EncryptionManager(dataRootProvider: { root }, deviceKeys: MemoryDeviceKeys(), defaults: defaults)
        appModel = AppModel(settings: settings, encryption: encryption, spotlightIndexer: NoopSpotlight())
    }

    override func tearDownWithError() throws {
        appModel = nil
        encryption = nil
        AppSettings.shared.dataRootURL = originalRoot
        AppSettings.shared.localEncryptedBackupEnabled = originalFlag
        PrivateStaging.root = originalScratch
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: base)
    }

    private func enableEncryption() throws {
        _ = try encryption.enable(passphrase: "test-passphrase-1", iterations: 100_000)
        XCTAssertTrue(encryption.isUnlocked)
    }

    private func backupRuns() -> Int {
        (appModel.audit?.entries() ?? []).filter { $0.action == .backupRun }.count
    }

    private func archives(in folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == EncryptedBackupArchive.fileExtension }
    }

    func testSuccessWritesAnEncryptedArchiveAndRecordsOneBackupRun() async throws {
        try enableEncryption()
        let outcome = await appModel.backUpNow(to: destination)
        guard case let .success(archive) = outcome else { return XCTFail("expected success, got \(outcome)") }
        XCTAssertEqual(archive.deletingLastPathComponent().standardizedFileURL.path, destination.standardizedFileURL.path)
        XCTAssertTrue(EncryptedBackupArchive.isArchive(archive))
        XCTAssertEqual(backupRuns(), 1)
        XCTAssertTrue(AppSettings.shared.localEncryptedBackupEnabled)
        XCTAssertTrue(Keystore.exists(at: destination), "the wrapped key is kept beside the archive")
    }

    func testRepeatedSuccessfulBackupsRecordOneRunEach() async throws {
        try enableEncryption()
        _ = await appModel.backUpNow(to: destination)
        _ = await appModel.backUpNow(to: destination)
        XCTAssertEqual(backupRuns(), 2)
    }

    func testICloudFolderIsRefusedAndNothingIsWrittenOrRecorded() async throws {
        try enableEncryption()
        appModel.backupFolderVerdict = { _ in .iCloudDrive }
        let outcome = await appModel.backUpNow(to: destination)
        guard case .failed = outcome else { return XCTFail("expected a refusal, got \(outcome)") }
        XCTAssertTrue(archives(in: destination).isEmpty)
        XCTAssertEqual(backupRuns(), 0)
        XCTAssertFalse(AppSettings.shared.localEncryptedBackupEnabled)
    }

    func testOtherSyncedAndNetworkFoldersAreRefused() async throws {
        try enableEncryption()
        for verdict in [DataFolderPolicy.Verdict.thirdPartyCloud("Dropbox"), .networkVolume, .removableUnencrypted, .iCloudDesktopDocuments] {
            appModel.backupFolderVerdict = { _ in verdict }
            let outcome = await appModel.backUpNow(to: destination)
            guard case .failed = outcome else { return XCTFail("\(verdict) should be refused") }
        }
        XCTAssertEqual(backupRuns(), 0)
    }

    func testFolderInsideTheDataFolderIsRefused() async throws {
        try enableEncryption()
        let inside = dataRoot.appendingPathComponent("backups", isDirectory: true)
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let outcome = await appModel.backUpNow(to: inside)
        guard case .failed = outcome else { return XCTFail("expected a refusal, got \(outcome)") }
        XCTAssertEqual(backupRuns(), 0)
    }

    func testLockedOrUnencryptedFolderFailsWithoutRecording() async throws {
        let notEnabled = await appModel.backUpNow(to: destination)
        guard case .failed = notEnabled else { return XCTFail("expected failure without encryption") }
        try enableEncryption()
        encryption.lock()
        let locked = await appModel.backUpNow(to: destination)
        guard case .failed = locked else { return XCTFail("expected failure while locked") }
        XCTAssertTrue(archives(in: destination).isEmpty)
        XCTAssertEqual(backupRuns(), 0)
    }

    func testFailedWriteDoesNotRecordABackup() async throws {
        try enableEncryption()
        // A file where the destination folder should be makes the write fail.
        let blocker = base.appendingPathComponent("not-a-folder")
        try Data("x".utf8).write(to: blocker)
        let outcome = await appModel.backUpNow(to: blocker)
        guard case .failed = outcome else { return XCTFail("expected failure, got \(outcome)") }
        XCTAssertEqual(backupRuns(), 0)
        XCTAssertFalse(AppSettings.shared.localEncryptedBackupEnabled)
    }
}
