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

/// Restoring an encrypted folder backup: round trip, never over existing data,
/// fail closed on a wrong key or an altered archive.
final class BackupRestoreTests: XCTestCase {
    private var base: URL!
    private var originalScratch: URL!
    private let passphrase = "test-passphrase-1"

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory.appendingPathComponent("BackupRestoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        originalScratch = PrivateStaging.root
        PrivateStaging.root = base.appendingPathComponent("Scratch", isDirectory: true)
    }

    override func tearDownWithError() throws {
        PrivateStaging.root = originalScratch
        try? FileManager.default.removeItem(at: base)
    }

    private func dir(_ name: String) throws -> URL {
        let url = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func sampleFolder() throws -> URL {
        let root = try dir("data")
        try write("notes one", "patients/abc/notes.json", in: root)
        try write(String(repeating: "audio", count: 500_000), "patients/abc/sessions/s1/mic.caf", in: root)
        try write("ledger", "audit/ledger.log", in: root)
        try write("hidden", ".hidden-file", in: root)
        try write("skip", ".backups/archives/old.aletheiabackup", in: root)
        try write("skip", "search.sqlite", in: root)
        return root
    }

    private func snapshot(_ text: String = "db snapshot") throws -> URL {
        let url = base.appendingPathComponent("snap-\(UUID().uuidString).sqlite")
        try Data(text.utf8).write(to: url)
        return url
    }

    private func makeArchive(root: URL, key: SymmetricKey) throws -> URL {
        let archive = base.appendingPathComponent("out-\(UUID().uuidString).aletheiabackup")
        try FolderBackupArchive.create(folder: root, databaseSnapshot: try snapshot(), to: archive, using: key)
        return archive
    }

    private func files(under root: URL) -> [String: Data] {
        var result: [String: Data] = [:]
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isRegularFileKey]) else { return result }
        for case let url as URL in walker {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                result[String(url.path.dropFirst(base.path.count + 1))] = try? Data(contentsOf: url)
            }
        }
        return result
    }

    // MARK: - Archive

    func testRestoreRoundTripsWholeFolder() throws {
        let root = try sampleFolder()
        let key = SymmetricKey(size: .bits256)
        let archive = try makeArchive(root: root, key: key)
        XCTAssertTrue(EncryptedBackupArchive.isArchive(archive))

        let target = base.appendingPathComponent("restored")
        try FolderBackupArchive.restore(archive: archive, to: target, using: key)

        var expected = files(under: root)
        expected = expected.filter { !$0.key.hasPrefix(".backups") && $0.key != "search.sqlite" }
        expected["Aletheia.sqlite"] = Data("db snapshot".utf8)
        XCTAssertEqual(files(under: target), expected)
    }

    func testRestoreIntoAnExistingEmptyFolderWorks() throws {
        let root = try sampleFolder()
        let key = SymmetricKey(size: .bits256)
        let archive = try makeArchive(root: root, key: key)
        let target = try dir("empty")
        try FolderBackupArchive.restore(archive: archive, to: target, using: key)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("patients/abc/notes.json")), Data("notes one".utf8))
    }

    func testNonEmptyDestinationIsRefusedAndUntouched() throws {
        let root = try sampleFolder()
        let key = SymmetricKey(size: .bits256)
        let archive = try makeArchive(root: root, key: key)
        let target = try dir("busy")
        try write("keep me", "existing.txt", in: target)
        XCTAssertThrowsError(try FolderBackupArchive.restore(archive: archive, to: target, using: key)) {
            XCTAssertEqual($0 as? FolderBackupArchive.RestoreError, .destinationNotEmpty)
        }
        XCTAssertEqual(files(under: target), ["existing.txt": Data("keep me".utf8)])
        // A file sitting where the folder should be is refused too.
        let file = base.appendingPathComponent("a-file")
        try Data("x".utf8).write(to: file)
        XCTAssertThrowsError(try FolderBackupArchive.restore(archive: archive, to: file, using: key))
        XCTAssertEqual(try Data(contentsOf: file), Data("x".utf8))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasPrefix(".aletheia-restore") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testWrongKeyIsRefusedAndWritesNothing() throws {
        let root = try sampleFolder()
        let archive = try makeArchive(root: root, key: SymmetricKey(size: .bits256))
        let target = base.appendingPathComponent("never")
        XCTAssertThrowsError(try FolderBackupArchive.restore(archive: archive, to: target, using: SymmetricKey(size: .bits256))) {
            XCTAssertEqual($0 as? FolderBackupArchive.RestoreError, .damaged)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: base.path).filter { $0.hasPrefix(".aletheia-restore") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testTamperedArchiveIsRefusedAnywhereInTheFile() throws {
        let root = try sampleFolder()
        let key = SymmetricKey(size: .bits256)
        let archive = try makeArchive(root: root, key: key)
        let original = try Data(contentsOf: archive)
        for offset in [20, original.count / 2, original.count - 5] {
            var bytes = original
            bytes[offset] ^= 0x01
            try bytes.write(to: archive)
            let target = base.appendingPathComponent("t-\(offset)")
            XCTAssertThrowsError(try FolderBackupArchive.restore(archive: archive, to: target, using: key), "offset \(offset)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        }
        // Truncation is refused too.
        try original.dropLast(40).write(to: archive)
        let target = base.appendingPathComponent("trunc")
        XCTAssertThrowsError(try FolderBackupArchive.restore(archive: archive, to: target, using: key))
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    func testNonArchiveIsRefused() throws {
        let plain = base.appendingPathComponent("plain.aletheiabackup")
        try Data("not an archive".utf8).write(to: plain)
        XCTAssertThrowsError(try FolderBackupArchive.restore(archive: plain, to: base.appendingPathComponent("x"), using: SymmetricKey(size: .bits256))) {
            XCTAssertEqual($0 as? FolderBackupArchive.RestoreError, .notAnArchive)
        }
    }

    func testUnsafePathsAreRejected() {
        for bad in ["../x", "/abs", "a/../b", "a//b", "", ".", "a/./b"] {
            XCTAssertFalse(FolderBackupArchive.isSafe(bad), bad)
        }
        XCTAssertTrue(FolderBackupArchive.isSafe("patients/abc/notes.json"))
        XCTAssertTrue(FolderBackupArchive.isSafe(".aletheia-keystore.json"))
    }

    // MARK: - Passphrase / key file

    func testPassphraseRestoreAndWrongPassphrase() throws {
        let root = try sampleFolder()
        let (keystore, dek) = try Keystore.create(passphrase: passphrase, iterations: 100_000)
        let out = try dir("out")
        try keystore.write(to: out)
        let archive = out.appendingPathComponent("a.aletheiabackup")
        try FolderBackupArchive.create(folder: root, databaseSnapshot: try snapshot(), to: archive, using: dek)

        let target = base.appendingPathComponent("restored")
        XCTAssertThrowsError(try BackupRestore.restore(archive: archive, passphrase: "wrong-passphrase-9", into: target, fallbackKeystoreRoot: nil)) {
            XCTAssertEqual($0 as? BackupRestore.Failure, .wrongPassphrase)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))

        try BackupRestore.restore(archive: archive, passphrase: passphrase, into: target, fallbackKeystoreRoot: nil)
        XCTAssertEqual(try Data(contentsOf: target.appendingPathComponent("Aletheia.sqlite")), Data("db snapshot".utf8))
    }

    func testMissingKeyFileAndRefusedFolder() throws {
        let root = try sampleFolder()
        let archive = try makeArchive(root: root, key: SymmetricKey(size: .bits256))
        XCTAssertThrowsError(try BackupRestore.restore(archive: archive, passphrase: passphrase, into: base.appendingPathComponent("r"), fallbackKeystoreRoot: nil)) {
            XCTAssertEqual($0 as? BackupRestore.Failure, .keyFileMissing)
        }
        XCTAssertThrowsError(try BackupRestore.restore(
            archive: archive, passphrase: passphrase, into: base.appendingPathComponent("r"),
            fallbackKeystoreRoot: nil, verdict: { _ in .iCloudDrive }
        )) {
            guard case .folderNotAllowed = $0 as? BackupRestore.Failure else { return XCTFail("\($0)") }
        }
    }

    // MARK: - App model

    func testBackUpThenRestoreThroughTheAppModelRecordsOneRestore() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "BackupRestoreTests-\(UUID().uuidString)"))
        let dataRoot = try sampleFolder()
        let settings = AppSettings.shared
        let originalRoot = settings.dataRootURL
        defer { settings.dataRootURL = originalRoot }
        settings.dataRootURL = dataRoot
        let encryption = EncryptionManager(dataRootProvider: { settings.dataRootURL }, deviceKeys: MemoryDeviceKeys(), defaults: defaults)
        let model = AppModel(settings: settings, encryption: encryption, spotlightIndexer: NoopSpotlight())
        _ = try encryption.enable(passphrase: passphrase, iterations: 100_000)

        let out = try dir("out")
        let made = await model.backUpNow(to: out)
        guard case let .success(archive) = made else { return XCTFail("backup failed: \(made)") }

        let restoredFolder = base.appendingPathComponent("restored")
        let wrong = await model.restoreBackup(archive: archive, passphrase: "wrong-passphrase-9", into: restoredFolder)
        guard case .failed = wrong else { return XCTFail("wrong passphrase must fail") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: restoredFolder.path))
        XCTAssertEqual(settings.dataRootURL?.standardizedFileURL, dataRoot.standardizedFileURL)

        let busy = try dir("busy")
        try write("x", "keep.txt", in: busy)
        let refused = await model.restoreBackup(archive: archive, passphrase: passphrase, into: busy)
        guard case .failed = refused else { return XCTFail("non-empty folder must fail") }
        XCTAssertEqual(files(under: busy), ["keep.txt": Data("x".utf8)])

        let restored = await model.restoreBackup(archive: archive, passphrase: passphrase, into: restoredFolder)
        guard case .success = restored else { return XCTFail("restore failed: \(restored)") }
        XCTAssertEqual(try Data(contentsOf: restoredFolder.appendingPathComponent("patients/abc/notes.json")), Data("notes one".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: restoredFolder.appendingPathComponent(Keystore.fileName).path))
        let entries = model.audit?.entries() ?? []
        XCTAssertEqual(entries.filter { $0.action == .backupRestored }.count, 1)
    }
}
