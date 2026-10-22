import Foundation
import os

private let log = Logger(subsystem: "com.aletheia", category: "Shutdown")

/// Work that a quit cut short and that the next launch picks up again. Holds
/// identifiers only (the patient's id and the session's folder name, which is
/// already a plain folder name on disk), never transcript text or names.
struct InterruptedWork: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        /// Speech-to-text for a session: interrupted mid-run, waiting in the
        /// queue, or due to start automatically after a recording quit stopped.
        case transcription
        /// A background session summary. Finished sections are already on disk,
        /// so the build resumes where it stopped.
        case digest
    }

    let kind: Kind
    let patientID: UUID
    let sessionFolder: String
}

/// The interrupted-work list, kept in the data folder as
/// `<dataRoot>/.interrupted-work.json` so it stays with the data it points at.
/// Written once at quit, read at launch, and removed once everything in it has
/// been picked up again.
struct InterruptedWorkLedger {
    static let fileName = ".interrupted-work.json"

    let url: URL

    init(dataRoot: URL) {
        url = dataRoot.appendingPathComponent(Self.fileName)
    }

    func load() -> [InterruptedWork] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([InterruptedWork].self, from: data)) ?? []
    }

    /// Adds `items` to what is already listed (an earlier launch may not have
    /// been able to resume everything yet), without duplicates.
    func record(_ items: [InterruptedWork]) {
        guard !items.isEmpty else { return }
        var merged = load()
        for item in items where !merged.contains(item) { merged.append(item) }
        save(merged)
    }

    /// Replaces the list; an empty list removes the file.
    func save(_ items: [InterruptedWork]) {
        guard !items.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        do {
            try JSONEncoder().encode(items).write(to: url, options: .atomic)
        } catch {
            log.error("Couldn't save the interrupted-work list: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Something that has to wind down when the app quits.
@MainActor
protocol ShutdownJob: AnyObject {
    /// What should run again at the next launch. Asked before `shutDown()`, so
    /// it's saved even if winding down runs out of time.
    func interruptedWork() -> [InterruptedWork]
    /// Cancels and finalizes. May take a while, or never return; the
    /// coordinator stops waiting at its deadline either way.
    func shutDown() async
}

extension ShutdownJob {
    func interruptedWork() -> [InterruptedWork] { [] }
}

/// Winds every long-running job down when the app quits, within a hard
/// deadline: the interrupted work is saved first, then every job is cancelled
/// and finalized at the same time, and the quit goes ahead once they're all
/// done or the deadline passes, whichever comes first. A job that ignores
/// cancellation can't hold the quit up, and nothing here raises an alert.
@MainActor
final class ShutdownCoordinator {
    /// How the wind-down went, for the log and for tests.
    struct Report: Equatable {
        var timedOut: Bool
        /// Jobs (by registration order) that hadn't finished at the deadline.
        var unfinished: [Int]
        var saved: [InterruptedWork]
    }

    /// About the longest a quit should feel, and well inside the time macOS
    /// allows an app at logout or restart.
    nonisolated static let defaultDeadline: TimeInterval = 2.5

    private var jobs: [ShutdownJob] = []
    private let ledger: () -> InterruptedWorkLedger?
    private(set) var isShuttingDown = false

    init(ledger: @escaping () -> InterruptedWorkLedger?) {
        self.ledger = ledger
    }

    func register(_ job: ShutdownJob) {
        jobs.append(job)
    }

    @discardableResult
    func shutDown(deadline: TimeInterval = defaultDeadline) async -> Report {
        isShuttingDown = true
        var saved: [InterruptedWork] = []
        for job in jobs {
            for item in job.interruptedWork() where !saved.contains(item) { saved.append(item) }
        }
        ledger()?.record(saved)

        let race = Race(count: jobs.count)
        let report: Report = await withCheckedContinuation { continuation in
            race.onDone = { timedOut, unfinished in
                continuation.resume(returning: Report(timedOut: timedOut, unfinished: unfinished, saved: saved))
            }
            // Unstructured tasks, not a task group: a group waits for every
            // child on exit, so one job that ignores cancellation would hold the
            // quit up for good.
            for (index, job) in jobs.enumerated() {
                Task { @MainActor in
                    await job.shutDown()
                    race.finished(index)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(deadline * 1_000_000_000))
                race.expire()
            }
            race.finishIfEmpty()
        }
        if report.timedOut {
            log.notice("Quit went ahead at the deadline with \(report.unfinished.count) job(s) still winding down")
        }
        return report
    }
}

/// Resolves "all jobs done" against "deadline passed" exactly once.
@MainActor
private final class Race {
    var onDone: ((Bool, [Int]) -> Void)?
    private var remaining: Set<Int>

    init(count: Int) { remaining = Set(0..<count) }

    func finished(_ index: Int) {
        remaining.remove(index)
        finishIfEmpty()
    }

    func finishIfEmpty() {
        guard remaining.isEmpty else { return }
        complete(timedOut: false)
    }

    func expire() { complete(timedOut: true) }

    private func complete(timedOut: Bool) {
        guard let onDone else { return }
        self.onDone = nil
        onDone(timedOut, remaining.sorted())
    }
}

/// Picks interrupted work up again at launch, once the sessions it names can
/// be read (an encrypted folder may still be waiting for its passphrase).
@MainActor
enum InterruptedWorkResumer {
    struct Target {
        let patient: Patient
        let session: SessionRecord
    }

    /// Re-queues what can be resolved now and returns what can't yet. Work for
    /// a session that's gone, or a transcription whose recording is gone, is
    /// dropped: there's nothing left to run.
    static func resume(
        _ items: [InterruptedWork],
        patients: [Patient],
        sessions: (Patient) -> [SessionRecord]?,
        sweep: (() -> Void)? = nil,
        transcribe: (Target) -> Void,
        summarize: (Target) -> Void
    ) -> [InterruptedWork] {
        sweep?()
        var unresolved: [InterruptedWork] = []
        for item in items {
            guard let patient = patients.first(where: { $0.id == item.patientID }) else {
                // No patients yet means the folder can't be read yet; keep it.
                // Patients but not this one means it was deleted; drop it.
                if patients.isEmpty { unresolved.append(item) }
                continue
            }
            guard let list = sessions(patient) else {
                unresolved.append(item)
                continue
            }
            guard let session = list.first(where: { $0.folderName == item.sessionFolder }) else { continue }
            let target = Target(patient: patient, session: session)
            switch item.kind {
            case .transcription:
                if session.hasRecording { transcribe(target) }
            case .digest:
                summarize(target)
            }
        }
        return unresolved
    }
}
