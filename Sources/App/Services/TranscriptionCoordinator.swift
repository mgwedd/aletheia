import Foundation
import os

private let log = Logger(subsystem: "com.aletheia", category: "Transcription")

/// Runs session transcriptions at app level, so a transcription outlives the
/// screen that started it: leaving the session (or the patient) and coming back
/// shows the same progress, and the sidebar and menu bar can reflect it.
/// Shared by injection like the app-wide `SessionRecorder`.
///
/// One transcription at a time — each loads the speech model and holds a whole
/// session's audio in memory, so running them side by side would only slow both.
/// A session asked for while another is running waits its turn (`queue`).
///
/// Nothing is written until the transcript is complete: a cancelled or failed run
/// leaves the session folder exactly as it was (the recordings are untouched and
/// any plaintext copies made for decryption are removed).
@MainActor
final class TranscriptionCoordinator: ObservableObject {
    /// In-flight jobs by session id.
    @Published private(set) var jobs: [UUID: TranscriptionJob] = [:]
    /// How finished jobs ended, until the session screen takes them with
    /// `takeOutcome(for:)` (it may not have been on screen when they finished).
    @Published private(set) var outcomes: [UUID: TranscriptionOutcome] = [:]

    /// Which session is running and which are waiting, in order.
    @Published private(set) var queue = TranscriptionQueue()

    private var tasks: [UUID: Task<Void, Never>] = [:]
    /// What to transcribe for each waiting session, until its turn comes.
    private var pending: [UUID: (patient: Patient, session: SessionRecord)] = [:]
    /// What the running job is transcribing, so a quit can list it as interrupted.
    private var running: (patient: Patient, session: SessionRecord)?
    /// Set once the app has started quitting: nothing new starts after that.
    private var isShutDown = false
    private let appModel: AppModel
    private let integrations: Integrations
    private let settings: AppSettings

    init(appModel: AppModel, integrations: Integrations, settings: AppSettings) {
        self.appModel = appModel
        self.integrations = integrations
        self.settings = settings
    }

    func job(for sessionID: UUID) -> TranscriptionJob? {
        jobs[sessionID]
    }

    /// Whether any session is being transcribed.
    var isBusy: Bool { queue.running != nil }

    /// Whether `sessionID` is waiting for another transcription to finish.
    func isWaiting(_ sessionID: UUID) -> Bool {
        queue.isWaiting(sessionID)
    }

    /// Compact status for the menu bar; nil when idle.
    var statusLine: String? {
        jobs.values.first?.statusLine
    }

    /// Takes (and clears) how `sessionID`'s last transcription ended.
    func takeOutcome(for sessionID: UUID) -> TranscriptionOutcome? {
        outcomes.removeValue(forKey: sessionID)
    }

    /// Starts transcribing a session, or queues it behind the one that is
    /// running. Asking again for a session already running or waiting is a no-op.
    func start(patient: Patient, session: SessionRecord) {
        guard !isShutDown else { return }
        switch queue.submit(session.id) {
        case .alreadyKnown:
            return
        case .queued:
            outcomes[session.id] = nil
            pending[session.id] = (patient, session)
        case .startNow:
            outcomes[session.id] = nil
            begin(patient: patient, session: session)
        }
    }

    /// Runs the session `queue` has just marked running.
    private func begin(patient: Patient, session: SessionRecord) {
        let sessionID = session.id
        // Read here, not when queued: the store is rebuilt when encryption is
        // unlocked or locked, and a waiting session must use the current one.
        guard let store = appModel.store else {
            finish(sessionID, outcome: .failed(
                message: "This session couldn't be transcribed because the data folder isn't available. Check it in Settings, then press Transcribe."
            ))
            return
        }
        running = (patient, session)
        jobs[sessionID] = TranscriptionJob(
            startedAt: Date(),
            modelName: "Whisper \(settings.whisperModel.rawValue)"
        )
        let protector = appModel.currentProtector
        tasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.run(patient: patient, session: session, store: store, protector: protector)
            // Tell someone who stepped away that no transcript is coming.
            switch outcome {
            case .failed, .blank:
                await self.integrations.makeNotifier().post(
                    SessionNotifications.transcriptionProblem(
                        patientName: patient.name, date: session.date,
                        policy: .current(showFullName: self.settings.notificationsShowPatientNames)
                    )
                )
            case .completedAudioKept:
                await self.integrations.makeNotifier().post(
                    SessionNotifications.recordingNotDeleted(
                        patientName: patient.name, date: session.date,
                        policy: .current(showFullName: self.settings.notificationsShowPatientNames)
                    )
                )
            case .completed, .cancelled:
                break
            }
            self.finish(sessionID, outcome: outcome)
        }
    }

    /// Starts transcribing the session whose recording just stopped, when the
    /// user has turned on "Transcribe automatically".
    func startAfterRecording(_ recording: SessionRecorder.ActiveRecording) {
        guard settings.autoTranscribeAfterRecording else { return }
        guard let patient = appModel.patients.first(where: { $0.id == recording.patientID }),
              let session = try? appModel.store?.listSessions(for: patient)
                  .first(where: { $0.folderName == recording.sessionFolder })
        else {
            // The recording is saved either way; Transcribe still works by hand.
            log.error("Automatic transcription skipped: the recorded session could not be found")
            return
        }
        start(patient: patient, session: session)
    }

    /// Stops a running transcription, or takes a waiting one out of the queue. Returns once the stop has been requested;
    /// the job ends (as `.cancelled`) when the transcriber has wound down.
    func cancel(sessionID: UUID) {
        if queue.withdraw(sessionID) {
            pending[sessionID] = nil
            return
        }
        guard var job = jobs[sessionID], job.requestCancel() else { return }
        jobs[sessionID] = job
        // Cancelled on purpose: a quit while it winds down doesn't run it again.
        if running?.session.id == sessionID { running = nil }
        tasks[sessionID]?.cancel()
    }

    /// Quitting: the running and waiting sessions are listed to run again at
    /// the next launch, and the running one is cancelled. Nothing is written for
    /// a cancelled run, so the session is left as it was.
    private func shutDownTranscriptions() async {
        isShutDown = true
        for id in queue.waiting { _ = queue.withdraw(id) }
        pending = [:]
        let inFlight = Array(tasks.values)
        for id in Array(tasks.keys) { cancel(sessionID: id) }
        for task in inFlight { await task.value }
    }

    private func apply(_ progress: TranscriptionProgress, to sessionID: UUID) {
        guard var job = jobs[sessionID] else { return }
        job.apply(progress, now: Date())
        jobs[sessionID] = job
    }

    private func finish(_ sessionID: UUID, outcome: TranscriptionOutcome) {
        tasks[sessionID] = nil
        jobs[sessionID] = nil
        if running?.session.id == sessionID { running = nil }
        outcomes[sessionID] = outcome
        if let next = queue.finishRunning(), let waiting = pending.removeValue(forKey: next) {
            begin(patient: waiting.patient, session: waiting.session)
        }
    }

    private func run(
        patient: Patient,
        session: SessionRecord,
        store: Store,
        protector: FileProtector
    ) async -> TranscriptionOutcome {
        let sessionID = session.id
        // Keep the Mac from idle-sleeping (or App Nap throttling the work)
        // while the user is away; the display can still sleep and lock.
        let activity = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Transcribing a session")
        defer { ProcessInfo.processInfo.endActivity(activity) }
        // Ask in context: transcription can take minutes, and we want to tell
        // her when it's done if she's stepped away.
        await integrations.makeNotifier().requestAuthorization()
        do {
            let transcriber = integrations.makeTranscriber()
            let micURL = store.micRecordingURL(for: patient, session: session)
            let callURL = store.callRecordingURL(for: patient, session: session)
            // If the recordings are sealed, decrypt them to temporary files for
            // the resampler (which needs a real, seekable audio file), and clean
            // the plaintext copies up afterwards — also when cancelled or failed.
            // Register cleanup *before* the second decrypt, so a failure there
            // still removes the first plaintext copy.
            var tempCopies: [URL] = []
            defer { for url in tempCopies { try? FileManager.default.removeItem(at: url) } }
            let (micReadURL, micIsTemp) = try protector.decryptedCopyOfLargeFile(at: micURL)
            if micIsTemp { tempCopies.append(micReadURL) }
            let (callReadURL, callIsTemp) = try protector.decryptedCopyOfLargeFile(at: callURL)
            if callIsTemp { tempCopies.append(callReadURL) }
            try Task.checkCancellation()
            let text = try await transcriber.transcribeSession(micURL: micReadURL, callURL: callReadURL) { progress in
                Task { @MainActor [weak self] in self?.apply(progress, to: sessionID) }
            }
            // Last chance to stop without having written anything.
            try Task.checkCancellation()
            apply(TranscriptionProgress(stage: .saving, fraction: 1), to: sessionID)

            let decision = AudioRetentionPolicy.decision(
                optedIn: settings.keepAudioRecordings,
                encryptionEnabled: appModel.isEncryptionEnabled,
                transcript: text
            )
            if decision == .keepBecauseTranscriptBlank {
                // Nothing was transcribed, so the recording may be the only copy
                // of the session: keep it, don't overwrite any existing
                // transcript with an empty one, and tell the user (inline, not a
                // blocking alert) what happened and what to do next.
                appModel.refreshPatients()
                return .blank(notice: AudioRetentionPolicy.blankTranscriptNotice(
                    encryptionEnabled: appModel.isEncryptionEnabled
                ))
            }
            try store.saveTranscribedText(text, for: patient, session: session)
            integrations.digestScheduler.transcriptSaved(patient: patient, session: session)
            // Transcript-only by default: discard the raw audio now that the
            // transcript (the document of record) is saved. Audio is kept only
            // when the user opted in *and* at-rest encryption is on, so anything
            // retained on disk is ciphertext, never plaintext PHI. The gate is
            // enforced here on behavior, not just in the UI, so stale settings or
            // encryption being turned off can't leave audio in the clear.
            var audioNotice: String?
            if decision == .discard {
                do {
                    try store.deleteRecordings(for: patient, session: session)
                } catch {
                    audioNotice = "The transcript is saved, but the recording couldn't be deleted and is still in "
                        + "your data folder. Delete it from the session folder to remove it."
                }
            }
            appModel.refreshPatients()
            await integrations.makeNotifier().post(
                SessionNotifications.transcriptionComplete(
                    patientName: patient.name, date: session.date,
                    policy: .current(showFullName: settings.notificationsShowPatientNames)
                )
            )
            if let audioNotice { return .completedAudioKept(notice: audioNotice) }
            return .completed
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }
}

extension TranscriptionCoordinator: ShutdownJob {
    func interruptedWork() -> [InterruptedWork] {
        let waiting = queue.waiting.compactMap { pending[$0] }
        return ([running].compactMap { $0 } + waiting).map {
            InterruptedWork(kind: .transcription, patientID: $0.patient.id, sessionFolder: $0.session.folderName)
        }
    }

    func shutDown() async { await shutDownTranscriptions() }
}
