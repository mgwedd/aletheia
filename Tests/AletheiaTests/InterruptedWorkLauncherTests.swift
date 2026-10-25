import XCTest
@testable import Aletheia

/// What the next launch does about work the last run left unfinished: audio a
/// crash left in staging is recovered into its session, transcriptions that were
/// cut short start again, scratch copies of decrypted audio are cleaned up, and
/// nothing is touched while an encrypted folder is still locked.
@MainActor
final class InterruptedWorkLauncherTests: XCTestCase {
    private struct NoopSpotlightIndexer: SpotlightIndexing {
        func replaceIndex(with entries: [SpotlightEntry]) {}
        func clear() {}
    }

    private var root: URL!
    private var stagingRoot: URL!
    private var scratchRoot: URL!
    private var tempDir: URL!
    private var originalDataRoot: URL?
    private var defaultsName: String!
    private var encryption: EncryptionManager!
    private var appModel: AppModel!
    private var launcher: InterruptedWorkLauncher!
    private var transcribed: [String] = []
    private var summarized: [String] = []

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("InterruptedWorkLauncherTests-\(UUID().uuidString)", isDirectory: true)
        root = base.appendingPathComponent("Data", isDirectory: true)
        stagingRoot = base.appendingPathComponent("Staging", isDirectory: true)
        scratchRoot = base.appendingPathComponent("Scratch", isDirectory: true)
        tempDir = base.appendingPathComponent("Temp", isDirectory: true)
        for dir in [root!, stagingRoot!, scratchRoot!, tempDir!] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        let settings = AppSettings.shared
        originalDataRoot = settings.dataRootURL
        settings.dataRootURL = root
        defaultsName = "InterruptedWorkLauncherTests-\(UUID().uuidString)"
        let root = self.root!
        encryption = EncryptionManager(dataRootProvider: { root }, defaults: UserDefaults(suiteName: defaultsName)!)
        appModel = AppModel(settings: settings, encryption: encryption, spotlightIndexer: NoopSpotlightIndexer())
        appModel.diskProbe = FixedDisk()
        launcher = InterruptedWorkLauncher()
    }

    override func tearDownWithError() throws {
        launcher = nil
        appModel = nil
        UserDefaults(suiteName: defaultsName)?.removePersistentDomain(forName: defaultsName)
        SessionSearch.index = SearchIndex()
        AppSettings.shared.dataRootURL = originalDataRoot
        try? FileManager.default.removeItem(at: root.deletingLastPathComponent())
    }

    private struct FixedDisk: DiskEncryptionProbing {
        func isDataVolumeEncrypted(_ url: URL) -> Bool? { true }
    }

    private var ledger: InterruptedWorkLedger { InterruptedWorkLedger(dataRoot: root) }

    private func start(transcribesAfterRecording: Bool = true, stagingSession: UUID? = nil) {
        let root = self.root!
        launcher.start(
            appModel: appModel,
            ledger: { InterruptedWorkLedger(dataRoot: root) },
            stagingSessionID: { stagingSession },
            transcribesAfterRecording: { transcribesAfterRecording },
            stagingRoot: stagingRoot,
            scratchRoot: scratchRoot,
            temporaryDirectory: tempDir,
            transcribe: { self.transcribed.append($0.session.folderName) },
            summarize: { self.summarized.append($0.session.folderName) }
        )
    }

    /// Waits for `done` (up to a second); with no condition, long enough for the
    /// launcher's pass to have run, so "nothing happened" is a real observation.
    private func settle(until done: (() -> Bool)? = nil) async {
        for _ in 0..<(done == nil ? 5 : 100) where !(done?() ?? false) { try? await Task.sleep(nanoseconds: 10_000_000) }
        try? await Task.sleep(nanoseconds: 50_000_000)
    }

    private func session(withRecording: Bool = true) throws -> (Patient, SessionRecord) {
        let store = try XCTUnwrap(appModel.store)
        let patient = try store.createPatient(name: "Test Patient")
        let session = try store.createSession(for: patient)
        if withRecording {
            try Data("audio".utf8).write(to: store.micRecordingURL(for: patient, session: session))
        }
        appModel.refreshPatients()
        return (patient, session)
    }

    private func stage(_ data: Data, for sessionID: UUID) throws -> URL {
        let dir = stagingRoot.appendingPathComponent(sessionID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let mic = dir.appendingPathComponent("mic.caf")
        try data.write(to: mic)
        return dir
    }

    // MARK: - Resumes

    func testInterruptedTranscriptionAndSummaryStartAgainAndTheListIsCleared() async throws {
        let (patient, recorded) = try session()
        let store = try XCTUnwrap(appModel.store)
        let other = try store.createSession(for: patient, on: Date(timeIntervalSinceNow: -86_400 * 3))
        appModel.refreshPatients()
        ledger.record([
            InterruptedWork(kind: .transcription, patientID: patient.id, sessionFolder: recorded.folderName),
            InterruptedWork(kind: .digest, patientID: patient.id, sessionFolder: other.folderName),
        ])

        start()
        await settle { !FileManager.default.fileExists(atPath: self.ledger.url.path) }

        XCTAssertEqual(transcribed, [recorded.folderName])
        XCTAssertEqual(summarized, [other.folderName])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.url.path), "nothing is left to pick up")
    }

    func testAudioACrashLeftInStagingIsRecoveredIntoItsSessionAndTranscribed() async throws {
        let (patient, recording) = try session(withRecording: false)
        let store = try XCTUnwrap(appModel.store)
        let staged = try stage(Data("crash audio".utf8), for: recording.id)

        start()
        await settle { !self.transcribed.isEmpty }

        let mic = store.micRecordingURL(for: patient, session: recording)
        XCTAssertTrue(FileManager.default.fileExists(atPath: mic.path), "the recording is back in its session")
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "and no longer staged")
        XCTAssertEqual(transcribed, [recording.folderName])
    }

    func testRecoveredAudioIsNotTranscribedWhenAutomaticTranscriptionIsOff() async throws {
        let (patient, recording) = try session(withRecording: false)
        let store = try XCTUnwrap(appModel.store)
        _ = try stage(Data("crash audio".utf8), for: recording.id)

        start(transcribesAfterRecording: false)
        await settle { FileManager.default.fileExists(atPath: store.micRecordingURL(for: patient, session: recording).path) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.micRecordingURL(for: patient, session: recording).path))
        XCTAssertEqual(transcribed, [])
    }

    func testTheRecordingInProgressIsNotSweptUp() async throws {
        let (_, recording) = try session(withRecording: false)
        let staged = try stage(Data("live".utf8), for: recording.id)

        start(stagingSession: recording.id)
        await settle()

        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.appendingPathComponent("mic.caf").path))
        XCTAssertEqual(transcribed, [])
    }

    func testAudioForASessionThatCannotBeFoundIsSetAsideNotDeleted() async throws {
        _ = try session()
        let unknown = UUID()
        let staged = try stage(Data("someone else's".utf8), for: unknown)

        start()
        await settle()

        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path))
        let kept = OrphanAudioSweep.quarantineDirectory(stagingRoot: stagingRoot)
            .appendingPathComponent(unknown.uuidString).appendingPathComponent("mic.caf")
        XCTAssertEqual(try Data(contentsOf: kept), Data("someone else's".utf8))
    }

    func testAnAbortedTranscriptionsDecryptedScratchAudioIsCleanedUp() async throws {
        let (patient, recorded) = try session()
        let leftover = scratchRoot.appendingPathComponent("transcribe-\(UUID().uuidString).caf")
        try Data("decrypted audio".utf8).write(to: leftover)
        let past = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.creationDate: past, .modificationDate: past], ofItemAtPath: leftover.path)
        ledger.record([InterruptedWork(kind: .transcription, patientID: patient.id, sessionFolder: recorded.folderName)])

        start()
        await settle { !self.transcribed.isEmpty }

        XCTAssertFalse(FileManager.default.fileExists(atPath: leftover.path), "no decrypted copy outlives the crash")
        XCTAssertEqual(transcribed, [recorded.folderName], "and the transcription runs again")
    }

    func testWorkForADeletedPatientIsDroppedAndTheListIsCleared() async throws {
        _ = try session()
        ledger.record([InterruptedWork(kind: .transcription, patientID: UUID(), sessionFolder: "gone")])

        start()
        await settle { !FileManager.default.fileExists(atPath: self.ledger.url.path) }

        XCTAssertEqual(transcribed, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.url.path))
    }

    func testADamagedListDoesNotStopTheLaunchOrLoseAudioAndIsKept() async throws {
        let (patient, recording) = try session(withRecording: false)
        let store = try XCTUnwrap(appModel.store)
        _ = try stage(Data("crash audio".utf8), for: recording.id)
        let damaged = Data("[{broken".utf8)
        try damaged.write(to: ledger.url)

        start()
        await settle { FileManager.default.fileExists(atPath: store.micRecordingURL(for: patient, session: recording).path) }

        XCTAssertTrue(FileManager.default.fileExists(atPath: store.micRecordingURL(for: patient, session: recording).path),
                      "the sweep still recovers the audio")
        XCTAssertEqual(transcribed, [recording.folderName], "and its transcription is listed afresh")
        XCTAssertEqual(try Data(contentsOf: ledger.unreadableCopyURL), damaged, "the damaged list is kept")
    }

    // MARK: - Locked folder

    func testNothingIsTouchedWhileTheEncryptedFolderIsLockedAndItResumesOnceUnlocked() async throws {
        try encryption.enable(passphrase: "test-passphrase-1", iterations: 100_000)
        let (patient, recorded) = try session()
        let staged = try stage(Data("staged".utf8), for: recorded.id)
        ledger.record([InterruptedWork(kind: .transcription, patientID: patient.id, sessionFolder: recorded.folderName)])
        encryption.lock()

        start()
        await settle()

        XCTAssertEqual(transcribed, [], "sessions can't be read yet")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path), "staged audio waits for the key")
        XCTAssertEqual(ledger.load().count, 1, "the work is still listed")

        try encryption.unlock(passphrase: "test-passphrase-1")
        await settle { !self.transcribed.isEmpty }

        XCTAssertEqual(transcribed, [recorded.folderName])
        XCTAssertFalse(FileManager.default.fileExists(atPath: staged.path), "recovered once unlocked")
    }
}
