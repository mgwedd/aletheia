import Foundation

/// Runs session transcriptions at app level, so a transcription outlives the
/// screen that started it: leaving the session (or the patient) and coming back
/// shows the same progress, and the sidebar and menu bar can reflect it.
/// Shared by injection like the app-wide `SessionRecorder`.
///
/// One transcription at a time — each loads the speech model and holds a whole
/// session's audio in memory, so running them side by side would only slow both.
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

    private var tasks: [UUID: Task<Void, Never>] = [:]
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
    var isBusy: Bool { !jobs.isEmpty }

    /// Compact status for the menu bar; nil when idle.
    var statusLine: String? {
        jobs.values.first?.statusLine
    }

    /// Takes (and clears) how `sessionID`'s last transcription ended.
    func takeOutcome(for sessionID: UUID) -> TranscriptionOutcome? {
        outcomes.removeValue(forKey: sessionID)
    }

    /// Starts transcribing a session. A no-op while another transcription runs.
    func start(patient: Patient, session: SessionRecord) {
        guard !isBusy, let store = appModel.store else { return }
        let sessionID = session.id
        outcomes[sessionID] = nil
        jobs[sessionID] = TranscriptionJob(startedAt: Date())
        let protector = appModel.currentProtector
        tasks[sessionID] = Task { [weak self] in
            guard let self else { return }
            let outcome = await self.run(patient: patient, session: session, store: store, protector: protector)
            self.finish(sessionID, outcome: outcome)
        }
    }

    /// Stops a running transcription. Returns once the stop has been requested;
    /// the job ends (as `.cancelled`) when the transcriber has wound down.
    func cancel(sessionID: UUID) {
        guard var job = jobs[sessionID], job.requestCancel() else { return }
        jobs[sessionID] = job
        tasks[sessionID]?.cancel()
    }

    private func apply(_ progress: TranscriptionProgress, to sessionID: UUID) {
        guard var job = jobs[sessionID] else { return }
        job.apply(progress, now: Date())
        jobs[sessionID] = job
    }

    private func finish(_ sessionID: UUID, outcome: TranscriptionOutcome) {
        tasks[sessionID] = nil
        jobs[sessionID] = nil
        outcomes[sessionID] = outcome
    }

    private func run(
        patient: Patient,
        session: SessionRecord,
        store: Store,
        protector: FileProtector
    ) async -> TranscriptionOutcome {
        let sessionID = session.id
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
            try store.saveTranscript(text, for: patient, session: session)
            // Transcript-only by default: discard the raw audio now that the
            // transcript (the document of record) is saved. Audio is kept only
            // when the user opted in *and* at-rest encryption is on, so anything
            // retained on disk is ciphertext, never plaintext PHI. The gate is
            // enforced here on behavior, not just in the UI, so stale settings or
            // encryption being turned off can't leave audio in the clear.
            if decision == .discard {
                store.deleteRecordings(for: patient, session: session)
            }
            appModel.refreshPatients()
            await integrations.makeNotifier().post(
                SessionNotifications.transcriptionComplete(patientName: patient.name, date: session.date)
            )
            return .completed
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed(message: error.localizedDescription)
        }
    }
}
