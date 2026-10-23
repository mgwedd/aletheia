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
    private var originalScratchRoot: URL!

    override func setUpWithError() throws {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("OrphanSweepTests-\(UUID().uuidString)", isDirectory: true)
        storeRoot = tempDir.appendingPathComponent("Store", isDirectory: true)
        stagingRoot = tempDir.appendingPathComponent("Staging", isDirectory: true)
        tempCafDir = tempDir.appendingPathComponent("TempCaf", isDirectory: true)

        try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tempCafDir, withIntermediateDirectories: true)

        originalScratchRoot = PrivateStaging.root
        PrivateStaging.root = tempDir.appendingPathComponent("DefaultScratch", isDirectory: true)

        key = SymmetricKey(size: .bits256)
        protector = FileProtector(key: key)
        store = Store(root: storeRoot, protector: protector)
        auditLog = AuditLog(root: storeRoot)
    }

    override func tearDownWithError() throws {
        PrivateStaging.root = originalScratchRoot
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

    func testPurgesScratchLeftoversFromEarlierRuns() throws {
        let scratch = tempDir.appendingPathComponent("Scratch", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let leftover = scratch.appendingPathComponent("restore-1.sqlite")
        try Data("db".utf8).write(to: leftover)
        let past = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.creationDate: past, .modificationDate: past], ofItemAtPath: leftover.path)

        let result = OrphanAudioSweep.sweep(
            store: store, protector: protector, audit: auditLog,
            stagingRoot: stagingRoot, scratchRoot: scratch, temporaryDirectory: tempCafDir)

        XCTAssertEqual(result.temporaryFilesPurged, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path))
    }

    // MARK: - Live recordings, locked folders and failures

    private func stage(_ data: Data, for id: UUID, in root: URL? = nil) throws -> URL {
        let dir = (root ?? stagingRoot).appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mic = dir.appendingPathComponent("mic.caf")
        try data.write(to: mic)
        return mic
    }

    @discardableResult
    private func runSweep(
        protector: FileProtector? = nil,
        ledger: InterruptedWorkLedger? = nil,
        activeSessionID: UUID? = nil,
        queuesTranscription: Bool = true
    ) -> OrphanAudioSweep.Result {
        OrphanAudioSweep.sweep(
            store: store, protector: protector ?? self.protector, audit: auditLog, ledger: ledger,
            activeSessionID: activeSessionID, queuesTranscription: queuesTranscription,
            stagingRoot: stagingRoot, temporaryDirectory: tempCafDir)
    }

    func testTheRecordingInProgressIsLeftAlone() throws {
        let patient = try store.createPatient(name: "Live Patient")
        let session = try store.createSession(for: patient)
        let staged = try stage(Data("still recording".utf8), for: session.id)

        let result = runSweep(activeSessionID: session.id)

        XCTAssertEqual(result.stagedSessionsRecovered, 0)
        XCTAssertEqual(try Data(contentsOf: staged), Data("still recording".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.micRecordingURL(for: patient, session: session).path))
    }

    func testALockedFolderIsNotSweptAndNothingMoves() throws {
        let staged = try stage(Data("audio".utf8), for: UUID())
        let tempCaf = tempCafDir.appendingPathComponent("aletheia-1.caf")
        try Data("x".utf8).write(to: tempCaf)

        XCTAssertFalse(OrphanAudioSweep.canRun(with: .locked))
        let result = runSweep(protector: .locked)

        XCTAssertTrue(result.skippedLocked)
        XCTAssertEqual(result.quarantinedUnknownDirs, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path), "Not quarantined while sessions can't be read")
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempCaf.path))
        XCTAssertTrue(OrphanAudioSweep.canRun(with: .passthrough))
        XCTAssertTrue(OrphanAudioSweep.canRun(with: protector))
    }

    func testAQuarantinedRecordingIsRecoveredOnceItsSessionIsFound() throws {
        let patient = try store.createPatient(name: "Later Patient")
        let session = try store.createSession(for: patient)
        let quarantine = stagingRoot.appendingPathComponent("quarantine", isDirectory: true)
        let staged = try stage(Data("quarantined audio".utf8), for: session.id, in: quarantine)

        let result = runSweep()

        XCTAssertEqual(result.stagedSessionsRecovered, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        let dest = store.micRecordingURL(for: patient, session: session)
        XCTAssertTrue(ChunkedCipher.isEnvelope(fileAt: dest))
        let (plain, isTemp) = try protector.decryptedCopyOfLargeFile(at: dest)
        defer { if isTemp { try? FileManager.default.removeItem(at: plain) } }
        XCTAssertEqual(try Data(contentsOf: plain), Data("quarantined audio".utf8))
    }

    func testQuarantiningAgainKeepsTheEarlierCopy() throws {
        let id = UUID()
        let quarantine = stagingRoot.appendingPathComponent("quarantine", isDirectory: true)
        let earlier = try stage(Data("earlier".utf8), for: id, in: quarantine)
        _ = try stage(Data("later".utf8), for: id)

        let result = runSweep()

        XCTAssertEqual(result.quarantinedUnknownDirs, 1)
        XCTAssertEqual(try Data(contentsOf: earlier), Data("earlier".utf8))
        let copies = try FileManager.default.contentsOfDirectory(atPath: quarantine.path)
        XCTAssertEqual(copies.count, 2)
    }

    func testARecordingThatCannotBeSealedStaysStagedAndNoPlaintextReachesTheSession() throws {
        let patient = try store.createPatient(name: "Read-only Patient")
        let session = try store.createSession(for: patient)
        let staged = try stage(Data("keep me".utf8), for: session.id)
        let sessionDir = store.sessionDir(for: patient, session: session)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: sessionDir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: sessionDir.path) }

        let result = runSweep()

        XCTAssertEqual(result.stagedSessionsRecovered, 0)
        XCTAssertEqual(try Data(contentsOf: staged), Data("keep me".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.micRecordingURL(for: patient, session: session).path))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: sessionDir.path).filter { $0.hasSuffix(".tmp") }
        XCTAssertEqual(leftovers, [])
    }

    func testRecoveredSessionIsQueuedForTranscriptionOnlyWhenThatIsOn() throws {
        let patient = try store.createPatient(name: "Queue Patient")
        let ledger = InterruptedWorkLedger(dataRoot: storeRoot)

        let off = try store.createSession(for: patient)
        _ = try stage(Data("a".utf8), for: off.id)
        runSweep(ledger: ledger, queuesTranscription: false)
        XCTAssertTrue(ledger.load().isEmpty)

        let on = try store.createSession(for: patient)
        _ = try stage(Data("b".utf8), for: on.id)
        runSweep(ledger: ledger, queuesTranscription: true)
        XCTAssertEqual(ledger.load().map(\.sessionFolder), [on.folderName])
    }

    func testSealLargeFileRefusesWhileLockedAndLeavesTheSource() throws {
        let src = tempDir.appendingPathComponent("src.caf")
        let dst = tempDir.appendingPathComponent("dst.caf")
        try Data("plain".utf8).write(to: src)

        XCTAssertThrowsError(try FileProtector.locked.sealLargeFile(from: src, to: dst)) {
            XCTAssertEqual($0 as? FileProtector.ProtectorError, .locked)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: dst.path))
    }
}
