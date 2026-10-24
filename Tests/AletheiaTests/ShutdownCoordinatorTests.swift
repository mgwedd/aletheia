import XCTest
@testable import Aletheia

/// A job that winds down at once (or after `delay`), reporting what it was doing.
@MainActor
private final class QuickJob: ShutdownJob {
    var work: [InterruptedWork]
    var delay: TimeInterval
    private(set) var shutDownCalls = 0
    private(set) var finished = false

    init(work: [InterruptedWork] = [], delay: TimeInterval = 0) {
        self.work = work
        self.delay = delay
    }

    func interruptedWork() -> [InterruptedWork] { work }

    func shutDown() async {
        shutDownCalls += 1
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        finished = true
    }
}

/// A job that ignores cancellation and takes far longer than any deadline: it
/// waits on a detached task, which a cancelled caller doesn't cancel.
@MainActor
private final class StubbornJob: ShutdownJob {
    var work: [InterruptedWork]
    private(set) var started = false
    private(set) var finished = false

    init(work: [InterruptedWork] = []) { self.work = work }

    func interruptedWork() -> [InterruptedWork] { work }

    func shutDown() async {
        started = true
        await Task.detached { try? await Task.sleep(nanoseconds: 30_000_000_000) }.value
        finished = true
    }
}

@MainActor
final class ShutdownCoordinatorTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShutdownCoordinatorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        SessionSearch.index = SearchIndex()   // AppModel pointed it at this test's folder
        try? FileManager.default.removeItem(at: root)
    }

    private var ledger: InterruptedWorkLedger { InterruptedWorkLedger(dataRoot: root) }

    private func coordinator(_ jobs: [ShutdownJob]) -> ShutdownCoordinator {
        let root = self.root!
        let coordinator = ShutdownCoordinator(ledger: { InterruptedWorkLedger(dataRoot: root) })
        jobs.forEach(coordinator.register)
        return coordinator
    }

    private func transcription(_ folder: String, patient: UUID = UUID()) -> InterruptedWork {
        InterruptedWork(kind: .transcription, patientID: patient, sessionFolder: folder)
    }

    // MARK: - Deadline

    func testAJobThatIgnoresCancellationCannotHoldUpTheQuit() async {
        let stubborn = StubbornJob()
        let quick = QuickJob()
        let coordinator = coordinator([stubborn, quick])

        let start = Date()
        let report = await coordinator.shutDown(deadline: 0.3)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertTrue(report.timedOut)
        XCTAssertEqual(report.unfinished, [0])
        XCTAssertGreaterThanOrEqual(elapsed, 0.25)
        XCTAssertLessThan(elapsed, 2, "the quit must go ahead at the deadline")
        XCTAssertTrue(stubborn.started)
        XCTAssertFalse(stubborn.finished)
        XCTAssertTrue(quick.finished)
    }

    func testFinishesAsSoonAsEveryJobIsDoneWithoutWaitingForTheDeadline() async {
        let jobs = [QuickJob(), QuickJob(delay: 0.05)]
        let coordinator = coordinator(jobs)

        let start = Date()
        let report = await coordinator.shutDown(deadline: 5)

        XCTAssertFalse(report.timedOut)
        XCTAssertEqual(report.unfinished, [])
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
        XCTAssertEqual(jobs.map(\.shutDownCalls), [1, 1])
        XCTAssertTrue(coordinator.isShuttingDown)
    }

    func testNoJobsQuitsAtOnce() async {
        let report = await coordinator([]).shutDown(deadline: 5)
        XCTAssertFalse(report.timedOut)
        XCTAssertEqual(report.saved, [])
    }

    // MARK: - Interrupted work is saved

    func testInterruptedWorkIsSavedEvenWhenAJobRunsPastTheDeadline() async {
        let patient = UUID()
        let running = transcription("2026-10-20_Session", patient: patient)
        let waiting = transcription("2026-10-21_Session", patient: patient)
        let digest = InterruptedWork(kind: .digest, patientID: patient, sessionFolder: "2026-10-19_Session")
        let coordinator = coordinator([
            StubbornJob(work: [running, waiting]),
            QuickJob(work: [digest, running]),   // listed twice, saved once
        ])

        let report = await coordinator.shutDown(deadline: 0.2)

        XCTAssertTrue(report.timedOut)
        XCTAssertEqual(report.saved, [running, waiting, digest])
        XCTAssertEqual(ledger.load(), [running, waiting, digest])
    }

    func testNothingInterruptedLeavesNoFile() async {
        await coordinator([QuickJob()]).shutDown(deadline: 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.url.path))
    }

    func testLedgerKeepsWorkAnEarlierLaunchCouldNotResumeYet() {
        let old = transcription("old")
        let new = transcription("new")
        ledger.record([old])
        ledger.record([new, old])
        XCTAssertEqual(ledger.load(), [old, new])

        ledger.save([])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ledger.url.path))
        XCTAssertEqual(ledger.load(), [])
    }

    func testLedgerLivesInTheDataFolder() {
        XCTAssertEqual(ledger.url.deletingLastPathComponent().standardizedFileURL, root.standardizedFileURL)
    }

    // MARK: - Re-queued on launch

    func testInterruptedWorkIsRequeuedAtLaunch() {
        let patient = Patient(name: "A", slug: "a")
        let recorded = SessionRecord(patientId: patient.id, folderName: "s1", hasRecording: true)
        let summarized = SessionRecord(patientId: patient.id, folderName: "s2", hasTranscript: true)
        var transcribed: [String] = []
        var summarizedFolders: [String] = []

        let left = InterruptedWorkResumer.resume(
            [
                InterruptedWork(kind: .transcription, patientID: patient.id, sessionFolder: "s1"),
                InterruptedWork(kind: .digest, patientID: patient.id, sessionFolder: "s2"),
            ],
            patients: [patient],
            sessions: { _ in [recorded, summarized] },
            transcribe: { transcribed.append($0.session.folderName) },
            summarize: { summarizedFolders.append($0.session.folderName) }
        )

        XCTAssertEqual(left, [])
        XCTAssertEqual(transcribed, ["s1"])
        XCTAssertEqual(summarizedFolders, ["s2"])
    }

    func testWorkWaitsWhileTheFolderCannotBeReadYet() {
        let item = transcription("s1")
        var calls = 0

        // An encrypted folder before its passphrase: no patients load.
        let locked = InterruptedWorkResumer.resume(
            [item], patients: [], sessions: { _ in [] },
            transcribe: { _ in calls += 1 }, summarize: { _ in calls += 1 })
        // The patient loads but its sessions can't be listed.
        let patient = Patient(id: item.patientID, name: "A", slug: "a")
        let unlisted = InterruptedWorkResumer.resume(
            [item], patients: [patient], sessions: { _ in nil },
            transcribe: { _ in calls += 1 }, summarize: { _ in calls += 1 })

        XCTAssertEqual(locked, [item])
        XCTAssertEqual(unlisted, [item])
        XCTAssertEqual(calls, 0)
    }

    func testWorkForDeletedPatientsSessionsOrRecordingsIsDropped() {
        let patient = Patient(name: "A", slug: "a")
        let noAudio = SessionRecord(patientId: patient.id, folderName: "no-audio", hasRecording: false)
        var calls = 0

        let left = InterruptedWorkResumer.resume(
            [
                transcription("s1"),                                   // patient deleted
                transcription("gone", patient: patient.id),            // session deleted
                transcription("no-audio", patient: patient.id),        // recording deleted
            ],
            patients: [patient],
            sessions: { _ in [noAudio] },
            transcribe: { _ in calls += 1 },
            summarize: { _ in calls += 1 }
        )

        XCTAssertEqual(left, [])
        XCTAssertEqual(calls, 0)
    }

    // MARK: - Jobs

    func testInferenceQueueShutDownCancelsTheRunningJobAndDropsTheRest() async {
        let queue = InferenceQueue()
        var ran: [String] = []
        var cancelled = false
        queue.enqueue(kind: .note, label: "running") {
            ran.append("running")
            do { try await Task.sleep(nanoseconds: 30_000_000_000) } catch { cancelled = true }
        }
        queue.enqueue(kind: .digest, label: "waiting") { ran.append("waiting") }
        for _ in 0..<200 where ran.isEmpty { try? await Task.sleep(nanoseconds: 2_000_000) }

        await queue.shutDown()
        queue.enqueue(kind: .sessionChat, label: "late") { ran.append("late") }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(cancelled)
        XCTAssertEqual(ran, ["running"])
        XCTAssertNil(queue.running)
        XCTAssertEqual(queue.waiting, [])
    }

    func testRecordingJobHasNothingToDoWhenIdle() async {
        let job = RecordingShutdownJob(recorder: SessionRecorder(), transcribesAfterRecording: { true })
        XCTAssertEqual(job.interruptedWork(), [])
        await job.shutDown()
    }

    func testQuittingMidAnswerSavesNothingAndRaisesNothing() async {
        let queue = InferenceQueue()
        let runner = ChatStreamRunner()
        var revealed = ""
        var finished: [String] = []
        var errors = 0
        runner.start(
            queue: queue, kind: .note, label: "note",
            makeStream: {
                AsyncThrowingStream { continuation in
                    continuation.yield("half a no")
                    // Never finishes on its own: only the quit ends it.
                }
            },
            onReveal: { revealed = $0 },
            onError: { _ in errors += 1 },
            onFinish: { finished.append($0) }
        )
        for _ in 0..<200 where revealed.isEmpty { try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertFalse(revealed.isEmpty, "the answer had started")

        await queue.shutDown()
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(finished, [], "a half-written answer must not replace the saved one")
        XCTAssertEqual(errors, 0)
        XCTAssertFalse(runner.isStreaming)
    }

    // MARK: - Search index

    private struct NoopSpotlightIndexer: SpotlightIndexing {
        func replaceIndex(with entries: [SpotlightEntry]) {}
        func clear() {}
    }

    private func quitIndexFileSurvives(encrypted: Bool) async throws -> Bool {
        let settings = AppSettings.shared
        let originalRoot = settings.dataRootURL
        settings.dataRootURL = root
        defer {
            settings.dataRootURL = originalRoot
            SessionSearch.index = SearchIndex()
        }
        let root = self.root!
        let defaultsName = "ShutdownCoordinatorTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer { defaults.removePersistentDomain(forName: defaultsName) }
        let encryption = EncryptionManager(dataRootProvider: { root }, defaults: defaults)
        if encrypted { try encryption.enable(passphrase: "test-passphrase-1", iterations: 100_000) }
        let appModel = AppModel(settings: settings, encryption: encryption, spotlightIndexer: NoopSpotlightIndexer())

        let indexFile = root.appendingPathComponent("search.sqlite")
        try Data("index".utf8).write(to: indexFile)
        await SearchSweepShutdownJob(appModel: appModel).shutDown()
        return FileManager.default.fileExists(atPath: indexFile.path)
    }

    func testQuitDestroysIndexWhenEncryptionEnabled() async throws {
        let survives = try await quitIndexFileSurvives(encrypted: true)
        XCTAssertFalse(survives, "the plaintext index does not outlive an encrypted folder's session")
    }

    func testQuitKeepsIndexWhenEncryptionIsOff() async throws {
        let survives = try await quitIndexFileSurvives(encrypted: false)
        XCTAssertTrue(survives)
    }
}
