import Foundation

/// Builds a session's digest in the background: one model call per section, then
/// merges of them, each run as its own `InferenceQueue` job at low priority so
/// a note or chat answer never waits behind a whole session's worth of digesting.
/// Every call goes through `AssistantService`, so it gets the same context-budget
/// check, progress report and truncation tripwire as a note or an answer.
///
/// `progress` holds live state per session while it builds (stage, elapsed,
/// tokens); `failures` holds a short message for a build that failed. A session
/// in neither is idle.
@MainActor
final class DigestBuilder: ObservableObject {
    @Published private(set) var progress: [UUID: AIRunProgress] = [:]
    @Published private(set) var failures: [UUID: String] = [:]

    /// One build in flight. `id` tells it apart from the build that replaced it.
    private struct Build {
        let id: UUID
        /// Transcript fingerprint and model it is building for.
        let key: String
        let task: Task<Void, Never>
    }

    private let queue: InferenceQueue
    private var builds: [UUID: Build] = [:]

    /// Applies a change to the live progress of the call that started at
    /// `started` (nil: whichever call is current). Events from an earlier call
    /// or build are dropped.
    typealias Live = @MainActor (_ started: Date?, _ change: (inout AIRunProgress) -> Void) -> Void

    init(queue: InferenceQueue) {
        self.queue = queue
    }

    // MARK: - Lifecycle

    /// Starts a background build unless the stored digest is already current or
    /// a build for this transcript and model is running. A build for a changed
    /// transcript or model replaces the one in flight. The stored digest is read
    /// (and decrypted) off the main thread.
    func ensureDigest(
        for patient: Patient,
        session: SessionRecord,
        transcript: String,
        store: Store,
        service: AssistantService
    ) {
        let key = NoteFreshness.fingerprint(of: transcript) + "|" + service.model
        if builds[session.id]?.key == key { return }
        cancel(session.id)
        let id = UUID()
        let task = Task { [weak self] in
            let model = service.model
            let alreadyCurrent = await Task.detached {
                store.digest(for: patient, session: session, model: model) != nil
            }.value
            guard let self, self.builds[session.id]?.id == id else { return }
            if alreadyCurrent {
                self.builds[session.id] = nil
                return
            }
            self.progress[session.id] = AIRunProgress(readTitle: "Reading", startedAt: Date())
            do {
                let digest = try await self.build(transcript: transcript, service: service, live: { started, change in
                    self.update(session.id, build: id, started: started, change)
                })
                try Task.checkCancellation()
                guard self.builds[session.id]?.id == id else { return }
                try store.saveDigest(digest, for: patient, session: session)
            } catch {
                // Cancelling (Stop, or a newer build replacing this one) is not
                // a failure.
                if !Task.isCancelled && !(error is CancellationError) && self.builds[session.id]?.id == id {
                    self.failures[session.id] = "Couldn't build the digest: \(error.localizedDescription)"
                }
            }
            // A replaced or cancelled build leaves its successor's state alone.
            guard self.builds[session.id]?.id == id else { return }
            self.builds[session.id] = nil
            self.progress[session.id] = nil
        }
        builds[session.id] = Build(id: id, key: key, task: task)
    }

    func cancel(_ sessionID: UUID) {
        builds[sessionID]?.task.cancel()
        builds[sessionID] = nil
        progress[sessionID] = nil
        failures[sessionID] = nil
    }

    private func update(_ sessionID: UUID, build: UUID, started: Date?, _ change: (inout AIRunProgress) -> Void) {
        guard builds[sessionID]?.id == build, var current = progress[sessionID] else { return }
        if let started, current.startedAt != started { return }
        change(&current)
        progress[sessionID] = current
    }

    // MARK: - Building

    /// Digests every section of `transcript`, then merges them (in budget-sized
    /// groups when they don't fit one prompt). `progress` is told which section
    /// is being worked on (1-based); `live` gets the running model call's state.
    /// Throws `CancellationError` if the surrounding task is cancelled.
    func build(
        transcript: String,
        service: AssistantService,
        progress: @escaping (_ section: Int, _ of: Int) -> Void = { _, _ in },
        live: @escaping Live = { _, _ in },
        inline: Bool = false
    ) async throws -> SessionDigest {
        let sections = TranscriptSections.split(transcript)
        var parts: [SessionDigest.Section] = []
        var anchored: [(anchor: String, digest: String)] = []
        for (index, section) in sections.enumerated() {
            try Task.checkCancellation()
            progress(index + 1, sections.count)
            let anchor = section.anchor(index: index, count: sections.count)
            let text = try await generate(
                Prompts.sectionDigest(text: section.text, anchor: anchor),
                stage: "Reading section \(index + 1) of \(sections.count)", service: service, live: live, inline: inline)
            parts.append(.init(start: section.start, end: section.end, digest: text))
            anchored.append((anchor, text))
        }
        try Task.checkCancellation()
        let merged = try await merge(anchored, service: service, live: live, inline: inline)
        return SessionDigest(
            model: service.model,
            promptVersion: Prompts.digestVersion,
            transcriptFingerprint: NoteFreshness.fingerprint(of: transcript),
            sections: parts,
            sessionDigest: merged,
            createdAt: Date()
        )
    }

    /// Merges section digests into the session digest. While they don't fit one
    /// prompt, merges them in groups of as many as fit and repeats on the
    /// results, so the final merge is always within budget (or fails with
    /// `ContextBudgetError` when even two can't be merged).
    private func merge(
        _ items: [(anchor: String, digest: String)], service: AssistantService, live: @escaping Live, inline: Bool
    ) async throws -> String {
        var items = items
        while items.count > 1 && !service.fits(prompt: Prompts.sessionDigest(sections: items)) {
            try Task.checkCancellation()
            var next: [(anchor: String, digest: String)] = []
            var group: [(anchor: String, digest: String)] = []
            func flush() async throws {
                guard let first = group.first, let last = group.last else { return }
                if group.count == 1 {
                    next.append(first)
                } else {
                    let text = try await generate(
                        Prompts.sessionDigest(sections: group), stage: "Merging digests", service: service, live: live, inline: inline)
                    next.append(("\(first.anchor) … \(last.anchor)", text))
                }
                group = []
            }
            for item in items {
                if group.count >= 2 && !service.fits(prompt: Prompts.sessionDigest(sections: group + [item])) {
                    try await flush()
                }
                group.append(item)
            }
            try await flush()
            items = next
        }
        return try await generate(
            Prompts.sessionDigest(sections: items), stage: "Merging digests", service: service, live: live, inline: inline)
    }

    /// One model call, run as a `.digest` job on the shared queue. With `inline`
    /// it runs right here instead: for a caller that is itself a queue job (a
    /// note building its own digest), which would otherwise wait on itself.
    private func generate(
        _ prompt: String, stage: String, service: AssistantService, live: @escaping Live, inline: Bool
    ) async throws -> String {
        if inline {
            return try await runStage(prompt, read: stage, write: "Writing digest", service: service, live: live)
        }
        let waiter = JobWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Already cancelled before the job was queued: don't queue it.
                guard waiter.attach(continuation) else { return }
                waiter.jobID = queue.enqueue(kind: .digest, label: "digest") {
                    do {
                        waiter.finish(.success(try await self.runStage(
                            prompt, read: stage, write: "Writing digest", service: service, live: live)))
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

    /// Runs one prompt now, streamed so its stage (`read` while the model reads,
    /// `write` once text arrives), elapsed time and token count reach `live`.
    func runStage(
        _ prompt: String, read: String, write: String, task: AITask = .digest,
        service: AssistantService, live: @escaping Live
    ) async throws -> String {
        let started = Date()
        live(nil) { $0 = AIRunProgress(readTitle: read, writeTitle: write, startedAt: started) }
        var run = service
        let outer = service.report
        run.report = { event in
            outer?(event)
            Task { @MainActor in
                live(started) { progress in
                    switch event {
                    case .reading(let tokens): progress.estimatedPromptTokens = tokens
                    case .finished(let stats):
                        progress.stats = stats
                        if let written = stats.outputTokens { progress.tokensWritten = written }
                    }
                }
            }
        }
        var text = ""
        var chunks = 0
        for try await snapshot in run.streamDigest(prompt: prompt, task: task) {
            text = snapshot
            chunks += 1
            live(started) { progress in
                if progress.firstTokenAt == nil { progress.firstTokenAt = Date() }
                if progress.stats == nil { progress.tokensWritten = chunks }
            }
        }
        try Task.checkCancellation()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
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
