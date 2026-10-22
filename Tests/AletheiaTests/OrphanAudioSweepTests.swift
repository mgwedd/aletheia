import CryptoKit
import XCTest
@testable import Aletheia

final class OrphanAudioSweepTests: XCTestCase {
    private var tempDir: URL!
    private var storeRoot: URL!
    private var stagingRoot: URL!
    private var tempCafDir: URL!
    private var key: SymmetricKey!
    private var protector: FileProtector!
    private var store: Store!
    private var auditLog: AuditLog!

    override func setUpWithError() throws {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("OrphanSweepTests-\(UUID().uuidString)", isDirectory: true)
        storeRoot = tempDir.appendingPathComponent("Store", isDirectory: true)
        stagingRoot = tempDir.appendingPathComponent("Staging", isDirectory: true)
        tempCafDir = tempDir.appendingPathComponent("TempCaf", isDirectory: true)

        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempCafDir, withIntermediateDirectories: true)

        key = SymmetricKey(size: .bits256)
        protector = FileProtector(key: key)
        store = Store(root: storeRoot, protector: protector)
        auditLog = AuditLog(root: storeRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    func testStagedFileIsSealedIntoTheRightSession() throws {
        let patient = try store.createPatient(name: "Test Patient")
        let session = try store.createSession(for: patient)

        let sessionStagingDir = stagingRoot.appendingPathComponent(session.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionStagingDir, withIntermediateDirectories: true)
        let stagedMic = sessionStagingDir.appendingPathComponent("mic.caf")
        let sampleData = Data("Fake CAF Audio Sample Data for Testing".utf8)
        try sampleData.write(to: stagedMic)

        let destMic = store.micRecordingURL(for: patient, session: session)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destMic.path))

        let result = OrphanAudioSweep.sweep(
            store: store,
            protector: protector,
            audit: auditLog,
            stagingRoot: stagingRoot,
            temporaryDirectory: tempCafDir
        )

        XCTAssertEqual(result.stagedSessionsRecovered, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: stagedMic.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionStagingDir.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destMic.path))
        XCTAssertTrue(ChunkedCipher.isEnvelope(fileAt: destMic))

        let (decryptedURL, isTemp) = try protector.decryptedCopyOfLargeFile(at: destMic)
        defer { if isTemp { try? FileManager.default.removeItem(at: decryptedURL) } }
        let decryptedData = try Data(contentsOf: decryptedURL)
        XCTAssertEqual(decryptedData, sampleData)

        let entries = auditLog.entries()
        XCTAssertTrue(entries.contains { $0.action == .recordingRecovered && $0.subjectID == session.id.uuidString && $0.detail == "staged" })
    }

    func testUnknownUUIDIsQuarantinedNotDeleted() throws {
        let unknownUUID = UUID()
        let unknownStagingDir = stagingRoot.appendingPathComponent(unknownUUID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: unknownStagingDir, withIntermediateDirectories: true)
        let unknownMic = unknownStagingDir.appendingPathComponent("mic.caf")
        let sampleData = Data("Orphaned audio from deleted or unknown session".utf8)
        try sampleData.write(to: unknownMic)

        let result = OrphanAudioSweep.sweep(
            store: store,
            protector: protector,
            audit: auditLog,
            stagingRoot: stagingRoot,
            temporaryDirectory: tempCafDir
        )

        XCTAssertEqual(result.quarantinedUnknownDirs, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unknownStagingDir.path))

        let quarantinedDir = stagingRoot.appendingPathComponent("quarantine", isDirectory: true).appendingPathComponent(unknownUUID.uuidString, isDirectory: true)
        let quarantinedMic = quarantinedDir.appendingPathComponent("mic.caf")
        XCTAssertTrue(FileManager.default.fileExists(atPath: quarantinedMic.path))
        XCTAssertEqual(try Data(contentsOf: quarantinedMic), sampleData)

        let entries = auditLog.entries()
        XCTAssertFalse(entries.contains { $0.subjectID == unknownUUID.uuidString })
    }

    func testPlaintextCafInEncryptedRootIsSealed() throws {
        let patient = try store.createPatient(name: "Legacy Patient")
        let session = try store.createSession(for: patient)

        let micURL = store.micRecordingURL(for: patient, session: session)
        let sampleData = Data("Legacy Plaintext Recording Before Encryption".utf8)
        try sampleData.write(to: micURL)
        XCTAssertFalse(ChunkedCipher.isEnvelope(fileAt: micURL))

        let result = OrphanAudioSweep.sweep(
            store: store,
            protector: protector,
            audit: auditLog,
            stagingRoot: stagingRoot,
            temporaryDirectory: tempCafDir
        )

        XCTAssertEqual(result.legacySessionsSealed, 1)
        XCTAssertTrue(ChunkedCipher.isEnvelope(fileAt: micURL))

        let (decryptedURL, isTemp) = try protector.decryptedCopyOfLargeFile(at: micURL)
        defer { if isTemp { try? FileManager.default.removeItem(at: decryptedURL) } }
        let decryptedData = try Data(contentsOf: decryptedURL)
        XCTAssertEqual(decryptedData, sampleData)

        let entries = auditLog.entries()
        XCTAssertTrue(entries.contains { $0.action == .recordingRecovered && $0.subjectID == session.id.uuidString && $0.detail == "legacy plaintext" })
    }

    func testAlreadySealedFileIsUntouched() throws {
        let patient = try store.createPatient(name: "Sealed Patient")
        let session = try store.createSession(for: patient)

        let micURL = store.micRecordingURL(for: patient, session: session)
        let sampleData = Data("Already sealed audio content".utf8)
        let tempPlain = tempDir.appendingPathComponent("plain.caf")
        try sampleData.write(to: tempPlain)
        try ChunkedCipher.seal(fileAt: tempPlain, to: micURL, using: key)
        XCTAssertTrue(ChunkedCipher.isEnvelope(fileAt: micURL))

        let attrBefore = try FileManager.default.attributesOfItem(atPath: micURL.path)
        let modBefore = attrBefore[.modificationDate] as? Date

        let result = OrphanAudioSweep.sweep(
            store: store,
            protector: protector,
            audit: auditLog,
            stagingRoot: stagingRoot,
            temporaryDirectory: tempCafDir
        )

        XCTAssertEqual(result.legacySessionsSealed, 0)
        XCTAssertTrue(ChunkedCipher.isEnvelope(fileAt: micURL))

        let attrAfter = try FileManager.default.attributesOfItem(atPath: micURL.path)
        let modAfter = attrAfter[.modificationDate] as? Date
        XCTAssertEqual(modBefore, modAfter)

        let entries = auditLog.entries()
        XCTAssertFalse(entries.contains { $0.subjectID == session.id.uuidString })
    }

    func testSweepIsIdempotent() throws {
        let patient = try store.createPatient(name: "Idempotent Patient")
        let session = try store.createSession(for: patient)

        let sessionStagingDir = stagingRoot.appendingPathComponent(session.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: sessionStagingDir, withIntermediateDirectories: true)
        let stagedMic = sessionStagingDir.appendingPathComponent("mic.caf")
        try Data("Audio bytes".utf8).write(to: stagedMic)

        let tempCaf = tempCafDir.appendingPathComponent("aletheia-\(UUID().uuidString).caf")
        try Data("Temp caf bytes".utf8).write(to: tempCaf)

        let unknownUUID = UUID()
        let unknownDir = stagingRoot.appendingPathComponent(unknownUUID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: unknownDir, withIntermediateDirectories: true)
        try Data("Unknown bytes".utf8).write(to: unknownDir.appendingPathComponent("mic.caf"))

        let result1 = OrphanAudioSweep.sweep(
            store: store,
            protector: protector,
            audit: auditLog,
            stagingRoot: stagingRoot,
            temporaryDirectory: tempCafDir
        )
        XCTAssertEqual(result1.stagedSessionsRecovered, 1)
        XCTAssertEqual(result1.quarantinedUnknownDirs, 1)
        XCTAssertEqual(result1.temporaryFilesPurged, 1)

        let auditCountAfterFirst = auditLog.entries().count

        let result2 = OrphanAudioSweep.sweep(
            store: store,
            protector: protector,
            audit: auditLog,
            stagingRoot: stagingRoot,
            temporaryDirectory: tempCafDir
        )
        XCTAssertEqual(result2.stagedSessionsRecovered, 0)
        XCTAssertEqual(result2.legacySessionsSealed, 0)
        XCTAssertEqual(result2.quarantinedUnknownDirs, 0)
        XCTAssertEqual(result2.temporaryFilesPurged, 0)
        XCTAssertEqual(auditLog.entries().count, auditCountAfterFirst)
    }

    func testPurgesTemporaryAletheiaCafFiles() throws {
        let temp1 = tempCafDir.appendingPathComponent("aletheia-123.caf")
        let temp2 = tempCafDir.appendingPathComponent("aletheia-abc.caf")
        let keep1 = tempCafDir.appendingPathComponent("other.caf")
        let keep2 = tempCafDir.appendingPathComponent("aletheia-notcaf.txt")

        for file in [temp1, temp2, keep1, keep2] {
            try Data("test bytes".utf8).write(to: file)
        }

        let result = OrphanAudioSweep.sweep(
            store: store,
            protector: protector,
            audit: auditLog,
            stagingRoot: stagingRoot,
            temporaryDirectory: tempCafDir
        )

        XCTAssertEqual(result.temporaryFilesPurged, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp1.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: temp2.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: keep2.path))
    }
}
