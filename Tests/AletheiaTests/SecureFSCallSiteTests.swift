import CryptoKit
import XCTest
@testable import Aletheia

/// Each data-folder write path leaves owner-only modes, even under a permissive
/// umask.
final class SecureFSCallSiteTests: XCTestCase {
    private var tempRoot: URL!
    private var savedUmask: mode_t = 0
    private let iterations = 100_000

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecureFSCallSiteTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        savedUmask = umask(0o000)
    }

    override func tearDownWithError() throws {
        umask(savedUmask)
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testKeystoreFileAndFolderAreOwnerOnly() throws {
        let root = tempRoot.appendingPathComponent("new-data-folder", isDirectory: true)
        let (keystore, _) = try Keystore.create(passphrase: "pw", iterations: iterations)
        try keystore.write(to: root)
        XCTAssertEqual(try posixMode(root), 0o700)
        XCTAssertEqual(try posixMode(root.appendingPathComponent(Keystore.fileName)), 0o600)
    }

    func testKeystoreReplaceOnDiskIs0600() throws {
        let (keystore, dek) = try Keystore.create(passphrase: "pw", iterations: iterations)
        try keystore.write(to: tempRoot)
        try keystore.replaceOnDisk(at: tempRoot, verifyingPassphrase: "pw", expectedDEK: dek)
        XCTAssertEqual(try posixMode(tempRoot.appendingPathComponent(Keystore.fileName)), 0o600)
    }

    func testProtectedFilesAreOwnerOnly() throws {
        for protector in [FileProtector.passthrough, FileProtector(key: SymmetricKey(size: .bits256))] {
            let file = tempRoot.appendingPathComponent("p-\(protector.isEncrypting).txt")
            try protector.write("note", to: file)
            XCTAssertEqual(try posixMode(file), 0o600, "encrypting: \(protector.isEncrypting)")
        }
    }

    func testSealedLargeFileAndItsFolderAreOwnerOnly() throws {
        let protector = FileProtector(key: SymmetricKey(size: .bits256))
        let src = tempRoot.appendingPathComponent("raw.m4a")
        FileManager.default.createFile(atPath: src.path, contents: Data(count: 4096), attributes: [.posixPermissions: 0o644])
        let dstDir = tempRoot.appendingPathComponent("session", isDirectory: true)
        let dst = dstDir.appendingPathComponent("audio.m4a")
        try protector.sealLargeFile(from: src, to: dst)
        XCTAssertEqual(try posixMode(dstDir), 0o700)
        XCTAssertEqual(try posixMode(dst), 0o600)
    }

    func testEnablingEncryptionLeavesOnlyOwnerOnlyFiles() throws {
        let manager = EncryptionManager(dataRootProvider: { self.tempRoot })
        try manager.enable(passphrase: "recovery phrase", iterations: iterations)
        let names = try FileManager.default.contentsOfDirectory(atPath: tempRoot.path)
        XCTAssertGreaterThanOrEqual(names.count, 2, "keystore and marker")
        for name in names {
            XCTAssertEqual(try posixMode(tempRoot.appendingPathComponent(name)), 0o600, name)
        }
    }

    func testStoreFoldersAndFilesAreOwnerOnly() throws {
        let root = tempRoot.appendingPathComponent("store", isDirectory: true)
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Test Patient")
        let session = try store.createSession(for: patient)

        XCTAssertEqual(try posixMode(root), 0o700)
        XCTAssertEqual(try posixMode(root.appendingPathComponent("Patients")), 0o700)
        let sessionDir = store.sessionDir(for: patient, session: session)
        let patientDir = sessionDir.deletingLastPathComponent()
        XCTAssertEqual(try posixMode(patientDir), 0o700)
        XCTAssertEqual(try posixMode(sessionDir), 0o700)
        XCTAssertEqual(try posixMode(patientDir.appendingPathComponent("patient.json")), 0o600)
        XCTAssertEqual(try posixMode(root.appendingPathComponent(DataSchema.metadataFileName)), 0o600)
        let sessionFiles = try FileManager.default.contentsOfDirectory(atPath: sessionDir.path)
        XCTAssertFalse(sessionFiles.isEmpty, "session metadata is written")
        for name in sessionFiles {
            XCTAssertEqual(try posixMode(sessionDir.appendingPathComponent(name)), 0o600, name)
        }
    }

    func testDatabaseFolderAndFileAreOwnerOnly() throws {
        let dir = tempRoot.appendingPathComponent("db-folder", isDirectory: true)
        let url = dir.appendingPathComponent("comments.sqlite")
        _ = try SQLitePersistenceCore(opening: url)
        XCTAssertEqual(try posixMode(dir), 0o700)
        XCTAssertEqual(try posixMode(url), 0o600)
    }

    func testExistingWideDatabaseIsTightenedOnOpen() throws {
        let url = tempRoot.appendingPathComponent("old.sqlite")
        _ = try SQLitePersistenceCore(opening: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        _ = try SQLitePersistenceCore(opening: url)
        XCTAssertEqual(try posixMode(url), 0o600)
    }

    func testSnapshotFolderIs0700() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot))
        let snapshot = try XCTUnwrap(DatabaseSnapshotManager(root: tempRoot).makeSnapshot(of: store, reason: "test"))
        XCTAssertEqual(try posixMode(snapshot.deletingLastPathComponent()), 0o700)
    }

    func testInterruptedWorkLedgerIs0600() throws {
        let ledger = InterruptedWorkLedger(dataRoot: tempRoot)
        ledger.save([InterruptedWork(kind: .digest, patientID: UUID(), sessionFolder: "2026-10-19_Session")])
        XCTAssertEqual(try posixMode(ledger.url), 0o600)
    }

    func testLegalReceiptIs0600() throws {
        LegalReceipt.append(version: "1", at: Date(), root: tempRoot, appVersion: "1.0")
        XCTAssertEqual(try posixMode(tempRoot.appendingPathComponent(LegalReceipt.fileName)), 0o600)
    }
}
