import CryptoKit
import XCTest
@testable import Aletheia

final class PrivateStagingTests: XCTestCase {
    private var sandbox: URL!
    private var originalRoot: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUpWithError() throws {
        sandbox = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateStagingTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
        originalRoot = PrivateStaging.root
        PrivateStaging.root = sandbox.appendingPathComponent("Scratch", isDirectory: true)
    }

    override func tearDownWithError() throws {
        PrivateStaging.root = originalRoot
        try? FileManager.default.removeItem(at: sandbox)
    }

    private func mode(_ url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    func testDefaultRootIsSeparateWhileHostingTests() {
        let real = PrivateStaging.defaultRoot(environment: [:])
        let test = PrivateStaging.defaultRoot(environment: ["XCTestConfigurationFilePath": "/x"])
        XCTAssertEqual(real.lastPathComponent, "Scratch")
        XCTAssertEqual(test.lastPathComponent, "ScratchTests")
        XCTAssertEqual(test.deletingLastPathComponent(), real.deletingLastPathComponent())
        XCTAssertEqual(originalRoot.lastPathComponent, "ScratchTests", "this process is hosting tests")
    }

    func testScratchAndStagingRootsAreExcludedFromBackup() throws {
        let staging = sandbox.appendingPathComponent("Staging", isDirectory: true)
        try PrivateStaging.ensureBackupExcludedRoot(staging)
        _ = try PrivateStaging.scratchFile(prefix: "t", ext: "bin")
        XCTAssertEqual(try mode(staging), 0o700)
        // The flag doesn't read back inside the App Sandbox container (see BackupExclusionTests).
        let sandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
            || NSHomeDirectory().contains("/Library/Containers/")
        try XCTSkipIf(sandboxed, "isExcludedFromBackup doesn't read back inside the App Sandbox container.")
        for dir in [staging, PrivateStaging.root] {
            var url = dir
            url.removeAllCachedResourceValues()
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true, dir.lastPathComponent)
        }
    }

    func testScratchFileIsOwnerOnlyInAnOwnerOnlyFolder() throws {
        let file = try PrivateStaging.scratchFile(prefix: "t", ext: "bin")
        XCTAssertEqual(file.deletingLastPathComponent().path, PrivateStaging.root.path)
        XCTAssertEqual(try mode(PrivateStaging.root), 0o700)
        XCTAssertEqual(try mode(file), 0o600)
    }

    func testLooseExistingFolderIsTightened() throws {
        try FileManager.default.createDirectory(at: PrivateStaging.root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        _ = try PrivateStaging.scratchFile(prefix: "t", ext: "bin")
        XCTAssertEqual(try mode(PrivateStaging.root), 0o700)
    }

    func testRemoveDeletesAndToleratesMissing() throws {
        let file = try PrivateStaging.scratchFile(prefix: "t", ext: "bin")
        PrivateStaging.remove(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        PrivateStaging.remove(file)
    }

    func testSweepRemovesOlderLeftoversButNotFilesInUse() throws {
        let stale = try PrivateStaging.scratchFile(prefix: "old", ext: "caf")
        let folder = PrivateStaging.root.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let past = Date(timeIntervalSinceNow: -3600)
        for url in [stale, folder] {
            try FileManager.default.setAttributes([.creationDate: past, .modificationDate: past], ofItemAtPath: url.path)
        }
        let live = try PrivateStaging.scratchFile(prefix: "live", ext: "caf")

        let removed = PrivateStaging.sweep(legacyTemporaryDirectory: sandbox.appendingPathComponent("none"))
        XCTAssertEqual(removed, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: live.path), "a file made by this run is left alone")
    }

    func testSweepClearsLegacySharedTempCopies() throws {
        let legacy = sandbox.appendingPathComponent("legacy", isDirectory: true)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let orphan = legacy.appendingPathComponent("aletheia-\(UUID().uuidString).caf")
        let other = legacy.appendingPathComponent("unrelated.txt")
        try Data("x".utf8).write(to: orphan)
        try Data("x".utf8).write(to: other)

        XCTAssertEqual(PrivateStaging.sweep(legacyTemporaryDirectory: legacy), 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: other.path))
    }

    func testDecryptedCopyLivesInPrivateStagingAndIsOwnerOnly() throws {
        let protector = FileProtector(key: key)
        let plain = sandbox.appendingPathComponent("plain.caf")
        let sealed = sandbox.appendingPathComponent("sealed.caf")
        try Data("audio".utf8).write(to: plain)
        try ChunkedCipher.seal(fileAt: plain, to: sealed, using: key)

        let (copy, isTemp) = try protector.decryptedCopyOfLargeFile(at: sealed)
        defer { PrivateStaging.remove(copy) }
        XCTAssertTrue(isTemp)
        XCTAssertEqual(copy.deletingLastPathComponent().path, PrivateStaging.root.path)
        XCTAssertEqual(try mode(copy), 0o600)
        XCTAssertEqual(try Data(contentsOf: copy), Data("audio".utf8))
    }

    func testFailedDecryptLeavesNoScratchFile() throws {
        let protector = FileProtector(key: key)
        let plain = sandbox.appendingPathComponent("plain.caf")
        let sealed = sandbox.appendingPathComponent("sealed.caf")
        try Data("audio".utf8).write(to: plain)
        try ChunkedCipher.seal(fileAt: plain, to: sealed, using: SymmetricKey(size: .bits256))

        XCTAssertThrowsError(try protector.decryptedCopyOfLargeFile(at: sealed))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: PrivateStaging.root.path), [])
    }

    func testChunkedOpenOutputIsOwnerOnly() throws {
        let plain = sandbox.appendingPathComponent("p.bin")
        let sealed = sandbox.appendingPathComponent("s.bin")
        let out = sandbox.appendingPathComponent("o.bin")
        try Data("secret".utf8).write(to: plain)
        try ChunkedCipher.seal(fileAt: plain, to: sealed, using: key)
        try ChunkedCipher.open(fileAt: sealed, to: out, using: key)
        XCTAssertEqual(try mode(out), 0o600)
    }

    func testBackupAndRestoreLeaveNothingInScratch() throws {
        let db = sandbox.appendingPathComponent("db.sqlite")
        let archive = sandbox.appendingPathComponent("a.\(EncryptedBackupArchive.fileExtension)")
        let restored = sandbox.appendingPathComponent("restored.sqlite")
        try Data("rows".utf8).write(to: db)

        try EncryptedBackupArchive.create(from: db, to: archive, using: key)
        try EncryptedBackupArchive.restore(from: archive, to: restored, using: key)
        XCTAssertEqual(try Data(contentsOf: restored), Data("rows".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: PrivateStaging.root.path), [])

        XCTAssertThrowsError(try EncryptedBackupArchive.restore(from: archive, to: restored, using: SymmetricKey(size: .bits256)))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: PrivateStaging.root.path), [])
    }

    func testSnapshotRestoreLeavesNothingInScratch() throws {
        let snapshot = sandbox.appendingPathComponent("snap.sqlite")
        let live = sandbox.appendingPathComponent("live.sqlite")
        try Data("snap".utf8).write(to: snapshot)
        try Data("old".utf8).write(to: live)

        XCTAssertTrue(DatabaseSnapshotManager(root: sandbox).restore(snapshot, to: live))
        XCTAssertEqual(try Data(contentsOf: live), Data("snap".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: PrivateStaging.root.path), [])
    }
}

/// Decrypted or patient-derived temporary files go through `PrivateStaging`;
/// nothing else may use the shared temporary directory.
final class PrivateStagingUsageTests: XCTestCase {
    /// Files with no patient data that may use the shared temporary directory.
    private let allowlist: Set<String> = []
    private let component = "Sources/App/Services/Crypto/PrivateStaging.swift"

    private var repo: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    func testNoSharedTemporaryDirectoryOutsideTheComponent() throws {
        let root = repo.appendingPathComponent("Sources/App")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        var scanned = 0
        for case let url as URL in files where url.pathExtension == "swift" {
            let path = url.path.replacingOccurrences(of: repo.path + "/", with: "")
            scanned += 1
            if path == component || allowlist.contains(path) { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains(".temporaryDirectory") || code.contains("NSTemporaryDirectory")
                || code.contains("mkstemp") || code.contains("createTemporaryFile") { offenders.append(path) }
        }
        XCTAssertGreaterThan(scanned, 50, "the scan should see the app sources")
        XCTAssertTrue(offenders.isEmpty, "use PrivateStaging instead of the shared temporary directory: \(offenders)")
    }

    /// The recorder marks its staging root when it creates it, so live audio stays out of backups.
    func testTheRecorderKeepsItsStagingRootOutOfBackups() throws {
        let text = try String(contentsOf: repo.appendingPathComponent("Sources/App/Services/SessionRecorder.swift"), encoding: .utf8)
        XCTAssertTrue(text.contains("PrivateStaging.ensureBackupExcludedRoot(stagingDirectoryURL)"))
    }

    func testBackupFlagIsOnlySetThroughBackupExclusion() throws {
        let root = repo.appendingPathComponent("Sources/App")
        let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var offenders: [String] = []
        for case let url as URL in files where url.pathExtension == "swift" {
            if url.lastPathComponent == "BackupExclusion.swift" { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = text.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .joined(separator: "\n")
            if code.contains("isExcludedFromBackup =") { offenders.append(url.lastPathComponent) }
        }
        XCTAssertTrue(offenders.isEmpty, "use BackupExclusion to set the backup flag: \(offenders)")
    }

    func testTheComponentItselfExists() {
        XCTAssertTrue(FileManager.default.fileExists(atPath: repo.appendingPathComponent(component).path))
    }
}
