import CryptoKit
import XCTest
@testable import Aletheia

final class PatientFolderMigrationTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("PatientFolderMigration-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    @discardableResult
    private func legacy(_ name: String, id: UUID = UUID()) throws -> Patient {
        let patient = Patient(id: id, name: name, slug: name)
        let folder = root.appendingPathComponent("Patients/\(name)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try JSONEncoder.aletheia.encode(patient).write(to: folder.appendingPathComponent("patient.json"))
        let session = folder.appendingPathComponent("2026-01-02_Session")
        try fm.createDirectory(at: session, withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: session.appendingPathComponent("mic.caf"))
        return patient
    }

    private func read(_ url: URL) throws -> Patient {
        try JSONDecoder.aletheia.decode(Patient.self, from: Data(contentsOf: url.appendingPathComponent("patient.json")))
    }

    func testRenameKeepsIDsAndSessionFilesAndRetainsPreimage() throws {
        let old = try legacy("Alice")
        let backup = try XCTUnwrap(PatientFolderMigration.run(root: root, protector: .passthrough).backup)
        let target = root.appendingPathComponent("Patients/\(old.id.uuidString)")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Patients/Alice").path))
        XCTAssertEqual(try read(target).id, old.id)
        XCTAssertEqual(try read(target).slug, old.id.uuidString)
        XCTAssertEqual(try String(contentsOf: target.appendingPathComponent("2026-01-02_Session/mic.caf"), encoding: .utf8), "audio")
        XCTAssertEqual(try read(backup.appendingPathComponent("Patients/Alice")).slug, "Alice")
    }

    func testSecondRunIsIdempotent() throws {
        let old = try legacy("Alice")
        let first = try XCTUnwrap(PatientFolderMigration.run(root: root, protector: .passthrough).backup)
        XCTAssertNil(try PatientFolderMigration.run(root: root, protector: .passthrough).backup)
        XCTAssertEqual(try read(root.appendingPathComponent("Patients/\(old.id.uuidString)")).id, old.id)
        XCTAssertTrue(fm.fileExists(atPath: first.path))
    }

    func testCollisionLeavesSourceUntouched() throws {
        let id = UUID()
        _ = try legacy("Alice", id: id)
        _ = try legacy(id.uuidString)
        XCTAssertThrowsError(try PatientFolderMigration.run(root: root, protector: .passthrough))
        XCTAssertEqual(try read(root.appendingPathComponent("Patients/Alice")).slug, "Alice")
    }

    func testFailedRewriteRollsBackMoveAndOriginalJSON() throws {
        let old = try legacy("Alice")
        enum Injected: Error { case failure }
        XCTAssertThrowsError(try PatientFolderMigration.run(
            root: root, protector: .passthrough, beforeRewrite: { _ in throw Injected.failure }))
        XCTAssertEqual(try read(root.appendingPathComponent("Patients/Alice")).id, old.id)
        XCTAssertEqual(try read(root.appendingPathComponent("Patients/Alice")).slug, "Alice")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Patients/\(old.id.uuidString)").path))
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("Patients/Alice/2026-01-02_Session/mic.caf"), encoding: .utf8), "audio")
    }

    func testV1StoreMigratesBeforeStampAndCanReopen() throws {
        let old = try legacy("Alice")
        let metadata = StoreMetadata(schemaVersion: 1, lastWrittenBy: "test")
        try JSONEncoder().encode(metadata).write(to: root.appendingPathComponent(DataSchema.metadataFileName))
        let store = Store(root: root)
        XCTAssertEqual(store.schemaCompatibility, .upgraded(fromVersion: 1))
        XCTAssertEqual(try store.listPatients().first?.id, old.id)
        XCTAssertEqual(try store.listPatients().first?.slug, old.id.uuidString)
        let stamp = try JSONDecoder().decode(StoreMetadata.self, from: Data(contentsOf: root.appendingPathComponent(DataSchema.metadataFileName)))
        XCTAssertEqual(stamp.schemaVersion, 2)
        XCTAssertEqual(Store(root: root).schemaCompatibility, .ok)
    }

    func testEncryptedPatientMetadataRemainsSealedAfterMove() throws {
        let old = try legacy("Alice")
        let source = root.appendingPathComponent("Patients/Alice/patient.json")
        let protector = FileProtector(key: SymmetricKey(size: .bits256))
        try protector.write(try Data(contentsOf: source), to: source)

        _ = try PatientFolderMigration.run(root: root, protector: protector)
        let target = root.appendingPathComponent("Patients/\(old.id.uuidString)/patient.json")
        XCTAssertTrue(DataCipher.isEnvelope(try Data(contentsOf: target)))
        let decoded = try JSONDecoder.aletheia.decode(Patient.self, from: protector.data(contentsOf: target))
        XCTAssertEqual(decoded.id, old.id)
        XCTAssertEqual(decoded.slug, old.id.uuidString)
    }

    func testCollisionKeepsV1StampAndBlocksNewPatients() throws {
        let id = UUID()
        _ = try legacy("Alice", id: id)
        _ = try legacy(id.uuidString)
        let metaURL = root.appendingPathComponent(DataSchema.metadataFileName)
        try JSONEncoder().encode(StoreMetadata(schemaVersion: 1, lastWrittenBy: "test")).write(to: metaURL)

        let store = Store(root: root)
        XCTAssertEqual(store.schemaCompatibility, .migrationFailed)
        let meta = try JSONDecoder().decode(StoreMetadata.self, from: Data(contentsOf: metaURL))
        XCTAssertEqual(meta.schemaVersion, 1)
        XCTAssertThrowsError(try store.createPatient(name: "New patient"))
    }

    private func stamp(_ version: Int) throws {
        try JSONEncoder().encode(StoreMetadata(schemaVersion: version, lastWrittenBy: "test"))
            .write(to: root.appendingPathComponent(DataSchema.metadataFileName))
    }

    private func stampedVersion() throws -> Int {
        try JSONDecoder().decode(StoreMetadata.self, from: Data(contentsOf: root.appendingPathComponent(DataSchema.metadataFileName))).schemaVersion
    }

    private func damaged(_ name: String) throws -> URL {
        let folder = root.appendingPathComponent("Patients/\(name)")
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: folder.appendingPathComponent("patient.json"))
        return folder
    }

    func testDamagedRecordIsLeftAloneWhileOthersMigrate() throws {
        let alice = try legacy("Alice")
        let bob = try damaged("Bob")
        let outcome = try PatientFolderMigration.run(root: root, protector: .passthrough)
        XCTAssertEqual(outcome.skippedUnreadable, 1)
        XCTAssertNotNil(outcome.backup)
        XCTAssertEqual(try read(root.appendingPathComponent("Patients/\(alice.id.uuidString)")).id, alice.id)
        XCTAssertEqual(try Data(contentsOf: bob.appendingPathComponent("patient.json")), Data("not json".utf8))
    }

    func testDamagedRecordKeepsOldStampButAllowsEditing() throws {
        let alice = try legacy("Alice")
        let bob = try damaged("Bob")
        try stamp(1)

        let store = Store(root: root)
        XCTAssertEqual(store.schemaCompatibility, .ok)
        XCTAssertEqual(try stampedVersion(), 1, "retried on the next open")
        XCTAssertEqual(try store.listPatients().map(\.id), [alice.id])
        XCTAssertNoThrow(try store.createPatient(name: "New patient"))

        try fm.removeItem(at: bob)
        XCTAssertEqual(Store(root: root).schemaCompatibility, .upgraded(fromVersion: 1))
        XCTAssertEqual(try stampedVersion(), 2)
    }

    func testUnstampedFolderWithDamagedRecordIsStampedAsOldVersion() throws {
        _ = try legacy("Alice")
        _ = try damaged("Bob")
        XCTAssertEqual(Store(root: root).schemaCompatibility, .ok)
        XCTAssertEqual(try stampedVersion(), 1)
    }

    func testLockedRecordStopsBeforeMovingAnything() throws {
        _ = try legacy("Alice")
        let bob = try legacy("Bob")
        let sealed = root.appendingPathComponent("Patients/Bob/patient.json")
        try FileProtector(key: SymmetricKey(size: .bits256)).write(try Data(contentsOf: sealed), to: sealed)

        XCTAssertThrowsError(try PatientFolderMigration.run(root: root, protector: .passthrough)) { error in
            XCTAssertEqual(error as? FileProtector.ProtectorError, .locked)
        }
        XCTAssertEqual(try read(root.appendingPathComponent("Patients/Alice")).slug, "Alice")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Patients/\(bob.id.uuidString)").path))
        XCTAssertFalse(fm.fileExists(atPath: BackupLayout.directory(.migrations, dataRoot: root).path))
    }

    func testRollbackRestoresRecordsAlreadyRewritten() throws {
        let alice = try legacy("Alice")
        let bob = try legacy("Bob")
        enum Injected: Error { case failure }
        var calls = 0
        XCTAssertThrowsError(try PatientFolderMigration.run(
            root: root, protector: .passthrough,
            beforeRewrite: { _ in calls += 1; if calls == 2 { throw Injected.failure } }))
        XCTAssertEqual(try read(root.appendingPathComponent("Patients/Alice")).slug, "Alice")
        XCTAssertEqual(try read(root.appendingPathComponent("Patients/Bob")).slug, "Bob")
        for id in [alice.id, bob.id] {
            XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Patients/\(id.uuidString)").path))
        }
        let leftovers = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Patients/Alice").path)
        XCTAssertFalse(leftovers.contains { $0.contains("restore") })
    }

    func testInterruptedMoveStillListsSessionsFromTheMovedFolder() throws {
        // A crash between the move and the record rewrite leaves the folder
        // under its UUID with the old slug inside.
        let alice = try legacy("Alice")
        try fm.moveItem(at: root.appendingPathComponent("Patients/Alice"),
                        to: root.appendingPathComponent("Patients/\(alice.id.uuidString)"))
        try stamp(2)

        let store = Store(root: root)
        let listed = try XCTUnwrap(store.listPatients().first)
        XCTAssertEqual(listed.slug, alice.id.uuidString)
        XCTAssertEqual(try store.listSessions(for: listed).count, 1)
        _ = try store.createSession(for: listed)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("Patients/Alice").path))
    }

    func testConcurrentOpensMigrateOnce() throws {
        let alice = try legacy("Alice")
        try stamp(1)
        let lock = NSLock()
        var results: [SchemaCompatibility] = []
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            let result = Store(root: root).schemaCompatibility
            lock.lock(); results.append(result); lock.unlock()
        }
        XCTAssertFalse(results.contains(.migrationFailed))
        XCTAssertEqual(results.filter { $0 == .upgraded(fromVersion: 1) }.count, 1)
        let folders = try fm.contentsOfDirectory(atPath: root.appendingPathComponent("Patients").path)
            .filter { !$0.hasPrefix(".") }
        XCTAssertEqual(folders, [alice.id.uuidString])
    }
}
