import Foundation

/// Serializes the app's AI generations (progress notes, session chat, patient
/// chat) so only one runs at a time, first come first served (background
/// digests yield to everything else).
///
/// Why app-side: every request goes to the same local model. The engine may queue
/// or interleave concurrent requests on its own, but that is invisible to the
/// user (a question just "thinks" forever behind a long note), and two
/// generations compete for the same memory on small Macs. Serializing here keeps
/// behaviour deterministic and lets the UI say what it is waiting for. This can
/// be relaxed later (e.g. allow N concurrent jobs) without touching call sites.
///
/// A job's `body` should return when its work is finished *or* when the task
/// running it is cancelled; the next job starts only after the body returns.
/// Free of SwiftUI and the engine so it can be unit tested.
@MainActor
final class InferenceQueue: ObservableObject {
    enum Kind: String, Equatable, Sendable {
        case note
        case sessionChat
        case patientChat
        /// Background digest building: runs only when no note or chat is waiting.
        case digest
    }

    struct JobInfo: Identifiable, Equatable, Sendable {
        let id: UUID
        let kind: Kind
        /// Human-readable description, e.g. "progress note".
        let label: String
    }

    /// The job currently generating, if any.
    @Published private(set) var running: JobInfo?
    /// Jobs waiting their turn, oldest first.
    @Published private(set) var waiting: [JobInfo] = []

    private struct Pending {
        let info: JobInfo
        let body: @MainActor () async throws -> Void
    }

    /// Mirrors `waiting` with the closures attached.
    private var pending: [Pending] = []
    private var runningTask: Task<Void, Never>?
    /// Set once the app has started quitting: jobs enqueued after that never run.
    private(set) var isShutDown = false

    /// Why AI may not run because of the license, or nil. Set by the app; unset allows all.
    var licenseRefusal: (() -> String?)?

    /// Throws `LicenseBlockedError` when a lapsed license stops AI. Every caller that
    /// starts AI work asks this before it enqueues.
    func authorize() throws {
        if let message = licenseRefusal?() { throw LicenseBlockedError(message: message) }
    }

    /// Adds a job to the back of the queue; it starts as soon as nothing is
    /// ahead of it. A body that throws is treated as finished (the caller owns
    /// its own error reporting), so the queue never stalls on a failure.
    @discardableResult
    func enqueue(
        kind: Kind,
        label: String,
        _ body: @escaping @MainActor () async throws -> Void
    ) -> JobInfo {
        let info = JobInfo(id: UUID(), kind: kind, label: label)
        pending.append(Pending(info: info, body: body))
        startNextIfIdle()
        return info
    }

    /// Whether a job with this label is running or waiting.
    func hasJob(labelled label: String) -> Bool {
        running?.label == label || waiting.contains { $0.label == label }
    }

    /// Cancels a job. A waiting job is dropped and never runs. The running job
    /// has its task cancelled; the next job starts once its body returns.
    func cancel(_ id: UUID) {
        if let index = pending.firstIndex(where: { $0.info.id == id }) {
            pending.remove(at: index)
            waiting = pending.map { $0.info }
        } else if running?.id == id {
            runningTask?.cancel()
        }
    }

    /// For a job that is waiting, the job it is waiting on; nil once it is
    /// running (or unknown).
    func blockingJob(for id: UUID) -> JobInfo? {
        guard waiting.contains(where: { $0.id == id }) else { return nil }
        return running
    }

    /// Calm, plain status line for a waiting job, or nil if it isn't waiting.
    func waitingStatus(for id: UUID) -> String? {
        guard let job = waiting.first(where: { $0.id == id }),
              let blocker = blockingJob(for: id) else { return nil }
        return Self.statusText(requesting: job.kind, behind: blocker.kind)
    }

    static func statusText(requesting: Kind, behind: Kind) -> String {
        if requesting == .digest { return "Waiting for other work to finish…" }
        if behind == .digest { return "Finishing a background digest, yours will run next." }
        if requesting == .note {
            if behind == .note { return "Waiting for another note to finish…" }
            return "Waiting for the chat answer to finish…"
        }
        if behind == .note { return "Still generating the note, your question will run next." }
        return "Still answering another question, yours will run next."
    }

    /// Quitting: drops every waiting job, cancels the running one and returns
    /// once its body has returned (a body should stop promptly when cancelled;
    /// the shutdown deadline covers one that doesn't).
    func shutDown() async {
        isShutDown = true
        pending.removeAll()
        waiting = []
        guard let task = runningTask else { return }
        task.cancel()
        await task.value
    }

    private func startNextIfIdle() {
        guard !isShutDown else {
            pending.removeAll()
            waiting = []
            return
        }
        guard running == nil, !pending.isEmpty else {
            waiting = pending.map { $0.info }
            return
        }
        // Digests are background work: a note or chat waiting anywhere in the
        // line goes first. Otherwise first come first served.
        let nextIndex = pending.firstIndex(where: { $0.info.kind != .digest }) ?? 0
        let next = pending.remove(at: nextIndex)
        waiting = pending.map { $0.info }
        running = next.info
        runningTask = Task { [weak self] in
            _ = try? await next.body()
            self?.finish(next.info.id)
        }
    }

    private func finish(_ id: UUID) {
        guard running?.id == id else { return }
        running = nil
        runningTask = nil
        startNextIfIdle()
    }
}

extension InferenceQueue: ShutdownJob {}
