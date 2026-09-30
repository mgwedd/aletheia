import CryptoKit
import XCTest
@testable import Aletheia

/// End-to-end-encrypted backup: that the archive is opaque at rest and round-
/// trips, that a wrong key can't open it, and that the local destination writes,
/// retains, and restores — while the iCloud destination reports itself
/// unconfigured until Apple setup lands.
final class BackupTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BackupTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    /// Writes a stand-in "database" file with known contents.
    private func writeSource(_ text: String, name: String = "Aletheia.sqlite") throws -> URL {
        let url = tempRoot.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: - Archive

    func testArchiveRoundTripsAndIsOpaqueAtRest() throws {
        let key = SymmetricKey(size: .bits256)
        let source = try writeSource("PHI: patient reports insomnia")
        let archive = tempRoot.appendingPathComponent("out.\(EncryptedBackupArchive.fileExtension)")

        try EncryptedBackupArchive.create(from: source, to: archive, using: key)
        XCTAssertTrue(EncryptedBackupArchive.isArchive(archive))
        let bytes = try Data(contentsOf: archive)
        XCTAssertNil(bytes.range(of: Data("insomnia".utf8)), "archive must not contain plaintext PHI")

        let restored = tempRoot.appendingPathComponent("restored.sqlite")
        try EncryptedBackupArchive.restore(from: archive, to: restored, using: key)
        XCTAssertEqual(try Data(contentsOf: restored), try Data(contentsOf: source))
    }

    func testWrongKeyCannotRestore() throws {
        let source = try writeSource("secret")
        let archive = tempRoot.appendingPathComponent("out.\(EncryptedBackupArchive.fileExtension)")
        try EncryptedBackupArchive.create(from: source, to: archive, using: SymmetricKey(size: .bits256))

        XCTAssertThrowsError(
            try EncryptedBackupArchive.restore(
                from: archive,
                to: tempRoot.appendingPathComponent("nope.sqlite"),
                using: SymmetricKey(size: .bits256) // different key
            )
        )
    }

    /// A failed restore must not strand a (partly) plaintext database copy in the
    /// temp folder.
    func testFailedRestoreLeavesNoTempDatabaseBehind() throws {
        let source = try writeSource(String(repeating: "PHI row. ", count: 200))
        let archive = tempRoot.appendingPathComponent("out.\(EncryptedBackupArchive.fileExtension)")
        try EncryptedBackupArchive.create(from: source, to: archive, using: SymmetricKey(size: .bits256))

        func tempRestores() -> Set<String> {
            let names = (try? FileManager.default.contentsOfDirectory(
                atPath: FileManager.default.temporaryDirectory.path)) ?? []
            return Set(names.filter { $0.hasPrefix("restore-") && $0.hasSuffix(".sqlite") })
        }
        let before = tempRestores()
        XCTAssertThrowsError(
            try EncryptedBackupArchive.restore(
                from: archive,
                to: tempRoot.appendingPathComponent("nope.sqlite"),
                using: SymmetricKey(size: .bits256) // different key
            )
        )
        XCTAssertTrue(tempRestores().subtracting(before).isEmpty, "temp restore file left behind")
    }

    func testRestoreRejectsNonArchive() throws {
        let plain = try writeSource("not encrypted", name: "plain.txt")
        XCTAssertThrowsError(
            try EncryptedBackupArchive.restore(from: plain, to: tempRoot.appendingPathComponent("x"), using: SymmetricKey(size: .bits256))
        ) { error in
            XCTAssertEqual(error as? EncryptedBackupArchive.ArchiveError, .notAnArchive)
        }
    }

    // MARK: - Local destination

    func testLocalBackupWritesAndRestoresLatest() async throws {
        let key = SymmetricKey(size: .bits256)
        let db = try writeSource("original db")
        let service = LocalEncryptedBackupService(root: tempRoot, key: key)

        guard case let .success(archive) = await service.backUp(databaseURL: db, reason: "manual") else {
            return XCTFail("backup should succeed")
        }
        XCTAssertTrue(EncryptedBackupArchive.isArchive(archive))

        // Mutate the live DB, then restore the backup over it.
        try Data("corrupted".utf8).write(to: db)
        guard case .success = await service.restoreLatest(to: db) else {
            return XCTFail("restore should succeed")
        }
        XCTAssertEqual(String(decoding: try Data(contentsOf: db), as: UTF8.self), "original db")
    }

    func testLocalBackupLivesInTheBackupsArchivesFolder() async throws {
        let db = try writeSource("db")
        let service = LocalEncryptedBackupService(root: tempRoot, key: SymmetricKey(size: .bits256))
        guard case let .success(archive) = await service.backUp(databaseURL: db, reason: "manual") else {
            return XCTFail("backup should succeed")
        }
        XCTAssertEqual(archive.deletingLastPathComponent().path,
                       tempRoot.appendingPathComponent(".backups/archives").path)
    }

    /// Archive retention only ever counts archives, never the snapshots or
    /// migration pre-images that share `.backups/`.
    func testArchivePruneLeavesOtherKindsAlone() async throws {
        let fm = FileManager.default
        let snapshots = BackupLayout.directory(.snapshots, dataRoot: tempRoot)
        let migrations = BackupLayout.directory(.migrations, dataRoot: tempRoot)
        try fm.createDirectory(at: snapshots, withIntermediateDirectories: true)
        try fm.createDirectory(at: migrations, withIntermediateDirectories: true)
        let snap = snapshots.appendingPathComponent("20000101-000000-old.sqlite")
        let pre = migrations.appendingPathComponent("Aletheia-pre-v1-20000101T000000Z.sqlite")
        for url in [snap, pre] { try Data("keep".utf8).write(to: url) }

        let db = try writeSource("db")
        var service = LocalEncryptedBackupService(root: tempRoot, key: SymmetricKey(size: .bits256))
        service.keep = 1
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<3 {
            _ = await service.backUp(databaseURL: db, reason: "r\(i)", at: base.addingTimeInterval(Double(i) * 60))
        }

        XCTAssertEqual(service.archives().count, 1)
        XCTAssertTrue(fm.fileExists(atPath: snap.path))
        XCTAssertTrue(fm.fileExists(atPath: pre.path))
    }

    func testLocalBackupRetainsNewestN() async throws {
        let db = try writeSource("db")
        var service = LocalEncryptedBackupService(root: tempRoot, key: SymmetricKey(size: .bits256))
        service.keep = 2

        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0..<4 {
            _ = await service.backUp(databaseURL: db, reason: "r\(i)", at: base.addingTimeInterval(Double(i) * 60))
        }

        let names = service.archives().map(\.lastPathComponent)
        XCTAssertEqual(names.count, 2, "retention keeps only `keep`")
        XCTAssertTrue(names.allSatisfy { $0.contains("-r2") || $0.contains("-r3") }, "newest survive: \(names)")
    }

    // MARK: - iCloud destination (staged)

    func testICloudDestinationReportsUnconfigured() async {
        let service = ICloudEncryptedBackupService(key: SymmetricKey(size: .bits256))
        XCTAssertFalse(service.isConfigured)
        let out = await service.backUp(databaseURL: tempRoot.appendingPathComponent("db"), reason: "manual")
        XCTAssertEqual(out, .notConfigured)
        let restore = await service.restoreLatest(to: tempRoot.appendingPathComponent("db"))
        XCTAssertEqual(restore, .notConfigured)
    }

    // MARK: - Settings persistence

    func testBackupSettingsPersist() {
        let suiteName = "BackupTests-\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: "localEncryptedBackupEnabled")
        defaults.set(true, forKey: "iCloudEncryptedBackupEnabled")
        XCTAssertTrue(defaults.bool(forKey: "localEncryptedBackupEnabled"))
        XCTAssertTrue(defaults.bool(forKey: "iCloudEncryptedBackupEnabled"))
    }
}
