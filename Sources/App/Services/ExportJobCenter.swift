import Foundation

/// Runs one patient-records export at a time, off the main thread, and tells the
/// UI where it is. It outlives the screen that started it, so the therapist can
/// carry on (or leave the patient) while a long history is prepared.
@MainActor
final class ExportJobCenter: ObservableObject {
    enum State: Equatable {
        case idle
        case running(fraction: Double, label: String)
        case finished(URL, PatientArchiveWriter.Outcome)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    private let notifier: AppNotifying
    private var task: Task<Void, Never>?
    private var generation = 0
    private var isCancelling = false

    init(notifier: AppNotifying) {
        self.notifier = notifier
    }

    var isRunning: Bool {
        if case .running = state { return true }
        return false
    }

    /// Starts writing the archive to `destination` (a place the user already chose).
    /// False when another export is still running. `load` reads one session and runs
    /// on a background thread; `onFinished` runs on the main actor after a success.
    @discardableResult
    func start(
        patientName: String,
        background: String,
        sessionCount: Int,
        load: @escaping (Int) throws -> ArchiveSession,
        destination: URL,
        onFinished: @escaping @MainActor (PatientArchiveWriter.Outcome) -> Void = { _ in }
    ) -> Bool {
        start(destination: destination, onFinished: onFinished) { progress, isCancelled in
            try PatientArchiveWriter.write(
                patientName: patientName,
                background: background,
                sessionCount: sessionCount,
                loadSession: load,
                to: destination,
                progress: progress,
                isCancelled: isCancelled
            )
        }
    }

    /// Runs any export `work` on a background thread, reporting progress and
    /// honouring cancel. False when another export is still running.
    @discardableResult
    func start(
        destination: URL,
        onFinished: @escaping @MainActor (PatientArchiveWriter.Outcome) -> Void = { _ in },
        work: @escaping (_ progress: (Double, String) -> Void, _ isCancelled: () -> Bool) throws -> PatientArchiveWriter.Outcome
    ) -> Bool {
        guard !isRunning else { return false }
        generation += 1
        isCancelling = false
        let mine = generation
        state = .running(fraction: 0, label: "Starting")
        let notifier = self.notifier
        Task { await notifier.requestAuthorization() }

        let job = UncheckedSendable(work)
        task = Task.detached(priority: .utility) { [weak self] in
            let result: Result<PatientArchiveWriter.Outcome, Error>
            do {
                result = .success(try job.value(
                    { fraction, label in
                        Task { @MainActor in self?.apply(fraction: fraction, label: label, generation: mine) }
                    },
                    { Task.isCancelled }
                ))
            } catch {
                result = .failure(error)
            }
            await self?.finish(result, destination: destination, generation: mine, onFinished: onFinished)
        }
        return true
    }

    /// Stops after the session being read. Nothing is written.
    func cancel() {
        guard isRunning else { return }
        isCancelling = true
        task?.cancel()
        state = .running(fraction: progressFraction, label: "Cancelling")
    }

    /// Quitting: cancels a running export and waits for it to stop. Nothing is
    /// written for a cancelled export, so there's nothing to resume; the
    /// therapist exports again when they need it.
    func shutDown() async {
        guard let task else { return }
        cancel()
        await task.value
    }

    /// Clears a finished or failed status. A running export is left alone.
    func dismiss() {
        guard !isRunning else { return }
        state = .idle
    }

    // MARK: - Updates from the background task

    private var progressFraction: Double {
        if case let .running(fraction, _) = state { return fraction }
        return 0
    }

    private func apply(fraction: Double, label: String, generation: Int) {
        guard generation == self.generation, isRunning, !isCancelling else { return }
        // Updates hop to the main actor one by one; never let an old one move the bar back.
        state = .running(fraction: max(fraction, progressFraction), label: label)
    }

    private func finish(
        _ result: Result<PatientArchiveWriter.Outcome, Error>,
        destination: URL,
        generation: Int,
        onFinished: @MainActor (PatientArchiveWriter.Outcome) -> Void
    ) {
        guard generation == self.generation else { return }
        task = nil
        isCancelling = false
        let notifier = self.notifier
        switch result {
        case .success(let outcome):
            state = .finished(destination, outcome)
            onFinished(outcome)
            Task { await notifier.post(SessionNotifications.exportReady()) }
        case .failure(is CancellationError):
            state = .idle
        case .failure(let error):
            state = .failed(Self.message(for: error))
            Task { await notifier.post(SessionNotifications.exportFailed()) }
        }
    }

    static func message(for error: Error) -> String {
        switch error {
        case ZipArchive.Failure.tooLarge, ZipArchive.Failure.tooManyEntries:
            return "These records are too large to save as one zip file."
        default:
            return "The export couldn't be finished: \(error.localizedDescription)"
        }
    }
}

extension ExportJobCenter: ShutdownJob {}

/// Carries a value the compiler can't prove is safe to move to another thread.
/// Used for the closure that reads the store: it only reads, and nothing else
/// touches it while the export runs.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value

    init(_ value: Value) { self.value = value }
}
