import Combine
import Foundation

/// The quit and relaunch side of the app's long-running work: the shutdown
/// coordinator `AppDelegate` runs on quit, and the launch-time pick-up of
/// whatever the last quit interrupted. Set up once in `AletheiaApp.init`.
@MainActor
enum AppLifecycle {
    static var shutdown: ShutdownCoordinator?
    static let resume = InterruptedWorkLauncher()

    static func configure(
        settings: AppSettings,
        appModel: AppModel,
        recorder: SessionRecorder,
        transcription: TranscriptionCoordinator,
        integrations: Integrations,
        exports: ExportJobCenter
    ) {
        let coordinator = ShutdownCoordinator(ledger: { settings.dataRootURL.map(InterruptedWorkLedger.init) })
        // All wind down at once; the order only sets which is listed first.
        coordinator.register(RecordingShutdownJob(
            recorder: recorder, transcribesAfterRecording: { settings.autoTranscribeAfterRecording }))
        coordinator.register(transcription)
        coordinator.register(integrations.digestScheduler)
        coordinator.register(integrations.inferenceQueue)
        coordinator.register(exports)
        coordinator.register(SearchSweepShutdownJob(appModel: appModel))
        shutdown = coordinator

        resume.start(
            appModel: appModel,
            ledger: { settings.dataRootURL.map(InterruptedWorkLedger.init) },
            stagingSessionID: { [weak recorder] in recorder?.stagingSessionID },
            transcribesAfterRecording: { settings.autoTranscribeAfterRecording },
            transcribe: { [weak transcription] in transcription?.start(patient: $0.patient, session: $0.session) },
            summarize: { [weak integrations] in
                integrations?.digestScheduler.sessionOpened(patient: $0.patient, session: $0.session)
            }
        )
    }
}

/// Stops a recording on quit and finalizes its files (closed, and sealed when
/// the folder is encrypted), so the audio is kept. Its automatic transcription
/// is listed to run at the next launch instead of starting on the way out.
@MainActor
final class RecordingShutdownJob: ShutdownJob {
    private let recorder: SessionRecorder
    private let transcribesAfterRecording: () -> Bool

    init(recorder: SessionRecorder, transcribesAfterRecording: @escaping () -> Bool) {
        self.recorder = recorder
        self.transcribesAfterRecording = transcribesAfterRecording
    }

    func interruptedWork() -> [InterruptedWork] {
        guard recorder.hasOpenRecording, transcribesAfterRecording(), let active = recorder.active else { return [] }
        return [InterruptedWork(kind: .transcription, patientID: active.patientID, sessionFolder: active.sessionFolder)]
    }

    func shutDown() async { await recorder.shutDown() }
}

/// Stops the background search-index sweep and closes the index.
@MainActor
final class SearchSweepShutdownJob: ShutdownJob {
    private let appModel: AppModel

    init(appModel: AppModel) { self.appModel = appModel }

    func shutDown() async { await appModel.stopSearchSync() }
}

/// At launch, re-queues the work the last quit interrupted, as soon as the
/// sessions it names can be read: right away, or once an encrypted folder is
/// unlocked and its patients load.
@MainActor
final class InterruptedWorkLauncher {
    private var watcher: AnyCancellable?
    private var hasRunSweep = false

    func start(
        appModel: AppModel,
        ledger: @escaping () -> InterruptedWorkLedger?,
        stagingSessionID: @escaping () -> UUID? = { nil },
        transcribesAfterRecording: @escaping () -> Bool = { true },
        stagingRoot: URL = Store.stagingDirectoryURL,
        scratchRoot: URL = PrivateStaging.root,
        temporaryDirectory: URL = PrivateStaging.legacyTemporaryDirectory,
        transcribe: @escaping (InterruptedWorkResumer.Target) -> Void,
        summarize: @escaping (InterruptedWorkResumer.Target) -> Void
    ) {
        // `patients` publishes before it changes; read the store once the change has landed.
        watcher = appModel.$patients.receive(on: DispatchQueue.main).sink { [weak self, weak appModel] _ in
            guard let self, let appModel, let store = appModel.store else { return }
            let ledgerInstance = ledger()
            // Not while an encrypted folder is locked: it runs once the unlock reloads the patients.
            if !self.hasRunSweep, OrphanAudioSweep.canRun(with: appModel.currentProtector) {
                self.hasRunSweep = true
                OrphanAudioSweep.sweep(
                    store: store,
                    protector: appModel.currentProtector,
                    audit: appModel.audit,
                    ledger: ledgerInstance,
                    activeSessionID: stagingSessionID(),
                    queuesTranscription: transcribesAfterRecording(),
                    stagingRoot: stagingRoot,
                    scratchRoot: scratchRoot,
                    temporaryDirectory: temporaryDirectory
                )
            }
            guard let ledger = ledgerInstance else { return }
            let items = ledger.load()
            if !items.isEmpty {
                let left = InterruptedWorkResumer.resume(
                    items,
                    patients: appModel.patients,
                    sessions: { try? store.listSessions(for: $0) },
                    transcribe: transcribe,
                    summarize: summarize
                )
                ledger.save(left)
                if left.isEmpty && self.hasRunSweep { self.watcher = nil }
            } else if self.hasRunSweep {
                self.watcher = nil
            }
        }
    }
}
