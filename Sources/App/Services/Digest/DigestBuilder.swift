import Foundation

/// Builds a session's digest in the background: one model call per section, then
/// one to merge them, each run as its own `InferenceQueue` job at low priority so
/// a note or chat answer never waits behind a whole session's worth of digesting.
///
/// `status` holds a calm one-line progress text per session while it builds
/// ("Building digest · section 4 of 11"); a session absent from it is idle.
@MainActor
final class DigestBuilder: ObservableObject {
    @Published private(set) var status: [UUID: String] = [:]

    private let queue: InferenceQueue
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(queue: InferenceQueue) {
        self.queue = queue
    }

    // MARK: - Lifecycle

    /// Starts a background build unless the stored digest is already current or a
    /// build for this session is running. A build for a changed transcript or
    /// model replaces the one in flight.
    func ensureDigest(
        for patient: Patient,
        session: SessionRecord,
        transcript: String,
        store: Store,
        service: AssistantService
    ) {
        if store.digest(for: patient, session: session, model: service.model) != nil { return }
        cancel(session.id)
        status[session.id] = "Building digest…"
        tasks[session.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let digest = try await self.build(transcript: transcript, service: service) { done, total in
                    self.status[session.id] = "Building digest · section \(done) of \(total)"
                }
                try Task.checkCancellation()
                try store.saveDigest(digest, for: patient, session: session)
            } catch {
                // Best effort: a failed or cancelled build just leaves the session
                // without a digest; the next trigger tries again.
            }
            self.status[session.id] = nil
            self.tasks[session.id] = nil
        }
    }

    func cancel(_ sessionID: UUID) {
        tasks[sessionID]?.cancel()
        tasks[sessionID] = nil
        status[sessionID] = nil
    }

    // MARK: - Building

    /// Digests every section of `transcript`, then merges them. `progress` is told
    /// which section is being worked on (1-based). Throws `CancellationError` if
    /// the surrounding task is cancelled.
    func build(
        transcript: String,
        service: AssistantService,
        progress: @escaping (_ section: Int, _ of: Int) -> Void = { _, _ in }
    ) async throws -> SessionDigest {
        let sections = TranscriptSections.split(transcript)
        var parts: [SessionDigest.Section] = []
        var anchored: [(anchor: String, digest: String)] = []
        for (index, section) in sections.enumerated() {
            try Task.checkCancellation()
            progress(index + 1, sections.count)
            let anchor = section.anchor(index: index, count: sections.count)
            let text = try await generate(Prompts.sectionDigest(text: section.text, anchor: anchor), label: "digest", service: service)
            parts.append(.init(start: section.start, end: section.end, digest: text))
            anchored.append((anchor, text))
        }
        try Task.checkCancellation()
        let merged = try await generate(Prompts.sessionDigest(sections: anchored), label: "digest", service: service)
        return SessionDigest(
            model: service.model,
            promptVersion: Prompts.digestVersion,
            transcriptFingerprint: NoteFreshness.fingerprint(of: transcript),
            sections: parts,
            sessionDigest: merged,
            createdAt: Date()
        )
    }

    /// One model call, run as a `.digest` job on the shared queue.
    private func generate(_ prompt: String, label: String, service: AssistantService) async throws -> String {
        let waiter = JobWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Already cancelled before the job was queued: don't queue it.
                guard waiter.attach(continuation) else { return }
                waiter.jobID = queue.enqueue(kind: .digest, label: label) {
                    do {
                        let text = try await service.assistant.generate(
                            model: service.model, system: service.systemPrompt, prompt: prompt
                        )
                        waiter.finish(.success(text.trimmingCharacters(in: .whitespacesAndNewlines)))
                    } catch {
                        waiter.finish(.failure(error))
                    }
                }.id
            }
        } onCancel: {
            Task { @MainActor [queue] in
                if let id = waiter.jobID { queue.cancel(id) }
                // A job dropped while waiting never runs its body, so settle here.
                waiter.finish(.failure(CancellationError()))
            }
        }
    }
}

/// Resumes the awaiting caller exactly once, whether the job finished, failed or
/// was dropped from the queue before it started.
@MainActor
private final class JobWaiter {
    private var continuation: CheckedContinuation<String, Error>?
    private var settled: Result<String, Error>?
    var jobID: UUID?

    /// False (after resuming `continuation`) if the wait was already settled.
    func attach(_ continuation: CheckedContinuation<String, Error>) -> Bool {
        if let settled {
            continuation.resume(with: settled)
            return false
        }
        self.continuation = continuation
        return true
    }

    func finish(_ result: Result<String, Error>) {
        guard settled == nil else { return }
        settled = result
        continuation?.resume(with: result)
        continuation = nil
    }
}
