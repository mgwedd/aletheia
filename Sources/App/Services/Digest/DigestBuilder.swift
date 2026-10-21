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
    /// Sessions a note is building a digest for right now, inline.
    private var inlineBuilds: Set<UUID> = []

    /// Applies a change to the live progress of the call that started at
    /// `started` (nil: whichever call is current). Events from an earlier call
    /// or build are dropped.
    typealias Live = @MainActor (_ started: Date?, _ change: (inout AIRunProgress) -> Void) -> Void

    /// What the user sees for this work: it reads and condenses the transcript,
    /// so the wording avoids "digest".
    static let activityTitle = "Processing transcript"
    static let writeTitle = "Writing summary"
    static let mergeTitle = "Combining sections"

    init(queue: InferenceQueue) {
        self.queue = queue
    }

    // MARK: - Lifecycle

    /// Starts a background build unless the stored digest is already current or
    /// a build for this transcript and model is running. A build for a changed
    /// transcript or model replaces the one in flight. The stored digest and the
    /// section summaries already written (`SectionDigestCache`) are read (and
    /// decrypted) off the main thread, so a build that was stopped or failed
    /// carries on from the sections it finished. Returns the build's task, to
    /// await; nil when nothing was started.
    @discardableResult
    func ensureDigest(
        for patient: Patient,
        session: SessionRecord,
        transcript: String,
        store: Store,
        service: AssistantService
    ) -> Task<Void, Never>? {
        let key = NoteFreshness.fingerprint(of: transcript) + "|" + service.model
        if builds[session.id]?.key == key || inlineBuilds.contains(session.id) { return nil }
        cancel(session.id)
        let id = UUID()
        let task = Task { [weak self] in
            let model = service.model
            let loaded = await Task.detached { () -> (current: Bool, sections: [String: String]) in
                (store.digest(for: patient, session: session, model: model) != nil,
                 store.sectionDigestCache(for: patient, session: session))
            }.value
            guard let self, self.builds[session.id]?.id == id else { return }
            if loaded.current {
                self.builds[session.id] = nil
                return
            }
            let cache = SectionDigestCache(entries: loaded.sections) { entries in
                try? store.saveSectionDigestCache(entries, for: patient, session: session)
            }
            self.progress[session.id] = AIRunProgress(readTitle: "Reading", startedAt: Date())
            do {
                let digest = try await self.build(transcript: transcript, service: service, live: { started, change in
                    self.update(session.id, build: id, started: started, change)
                }, cache: cache)
                try Task.checkCancellation()
                guard self.builds[session.id]?.id == id else { return }
                try store.saveDigest(digest, for: patient, session: session)
                cache.prune()
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
        return task
    }

    /// Builds a digest in the caller's own queue job (a note), cancelling any
    /// background build of the same session and keeping a new one from starting
    /// until this is done.
    func buildInline(
        sessionID: UUID, transcript: String, service: AssistantService, live: @escaping Live
    ) async throws -> SessionDigest {
        cancel(sessionID)
        inlineBuilds.insert(sessionID)
        defer { inlineBuilds.remove(sessionID) }
        return try await build(transcript: transcript, service: service, live: live, inline: true)
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
        inline: Bool = false,
        cache: SectionDigestCache? = nil
    ) async throws -> SessionDigest {
        let sections = TranscriptSections.split(transcript)
        // One call per section, plus the final merge. Merging a long session
        // takes more rounds than that; `merge` raises the total as it finds them.
        let totalSteps = sections.count + 1
        var parts: [SessionDigest.Section] = []
        var anchored: [(anchor: String, digest: String)] = []
        for (index, section) in sections.enumerated() {
            try Task.checkCancellation()
            progress(index + 1, sections.count)
            live(nil) { $0.steps = AIRunSteps(done: index, total: totalSteps) }
            let anchor = section.anchor(index: index, count: sections.count)
            let sectionKey = DigestSchedulePolicy.sectionKey(
                text: section.text, anchor: anchor, model: service.model, promptVersion: Prompts.digestVersion)
            let text: String
            if let cached = cache?.lookup(sectionKey) {
                // Written by an earlier build that was stopped or failed.
                text = cached
            } else {
                text = try await generate(
                    Prompts.sectionDigest(text: section.text, anchor: anchor),
                    stage: "Reading section \(index + 1) of \(sections.count)", service: service, live: live, inline: inline)
                cache?.store(sectionKey, text)
            }
            parts.append(.init(start: section.start, end: section.end, digest: text))
            anchored.append((anchor, text))
        }
        try Task.checkCancellation()
        let merged = try await merge(
            anchored, callsDone: sections.count, service: service, live: live, inline: inline)
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
    ///
    /// `callsDone` is how many model calls the build has finished (the
    /// sections). Each call reports `steps` before it runs: every group merge
    /// counts, and the total always leaves room for the final merge, so the bar
    /// grows with the work found rather than reading full while rounds remain.
    private func merge(
        _ items: [(anchor: String, digest: String)], callsDone: Int,
        service: AssistantService, live: @escaping Live, inline: Bool
    ) async throws -> String {
        var items = items
        var done = callsDone
        while items.count > 1 && !service.fits(prompt: Prompts.sessionDigest(sections: items)) {
            try Task.checkCancellation()
            var next: [(anchor: String, digest: String)] = []
            var group: [(anchor: String, digest: String)] = []
            func flush() async throws {
                guard let first = group.first, let last = group.last else { return }
                if group.count == 1 {
                    next.append(first)
                } else {
                    // This call and the final merge are still to come.
                    let before = done
                    done += 1
                    live(nil) { $0.steps = AIRunSteps(done: before, total: before + 2) }
                    let text = try await generate(
                        Prompts.sessionDigest(sections: group), stage: Self.mergeTitle, service: service, live: live, inline: inline)
                    next.append((TranscriptSection.mergedAnchor(first: first.anchor, last: last.anchor), text))
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
        let finished = done
        live(nil) { $0.steps = AIRunSteps(done: finished, total: finished + 1) }
        return try await generate(
            Prompts.sessionDigest(sections: items), stage: Self.mergeTitle, service: service, live: live, inline: inline)
    }

    /// One model call, run as a `.digest` job on the shared queue. With `inline`
    /// it runs right here instead: for a caller that is itself a queue job (a
    /// note building its own digest), which would otherwise wait on itself.
    private func generate(
        _ prompt: String, stage: String, service: AssistantService, live: @escaping Live, inline: Bool
    ) async throws -> String {
        if inline {
            return try await runStage(prompt, read: stage, write: Self.writeTitle, service: service, live: live)
        }
        let waiter = JobWaiter()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Already cancelled before the job was queued: don't queue it.
                guard waiter.attach(continuation) else { return }
                waiter.jobID = queue.enqueue(kind: .digest, label: "digest") {
                    do {
                        waiter.finish(.success(try await self.runStage(
                            prompt, read: stage, write: Self.writeTitle, service: service, live: live)))
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
        grammar: LocalLLMGrammar? = nil,
        service: AssistantService, live: @escaping Live, onSnapshot: ((String) -> Void)? = nil
    ) async throws -> String {
        let started = Date()
        live(nil) { $0.beginStage(readTitle: read, writeTitle: write, startedAt: started) }
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
        for try await snapshot in run.streamDigest(prompt: prompt, task: task, grammar: grammar) {
            text = snapshot
            chunks += 1
            onSnapshot?(snapshot)
            live(started) { progress in
                if progress.firstTokenAt == nil { progress.firstTokenAt = Date() }
                if progress.stats == nil { progress.tokensWritten = chunks }
            }
        }
        try Task.checkCancellation()
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// The section summaries of one session's build, kept on disk as each is
/// written (`Store.digestSectionsFileName`, encrypted like the digest), so a
/// build that is stopped (a pause, quitting) or fails carries on from the
/// sections it finished instead of starting over. Keyed by
/// `DigestSchedulePolicy.sectionKey`, so a changed section is built again.
@MainActor
final class SectionDigestCache {
    private(set) var entries: [String: String]
    private var used = Set<String>()
    private let persist: ([String: String]) -> Void

    init(entries: [String: String], persist: @escaping ([String: String]) -> Void) {
        self.entries = entries
        self.persist = persist
    }

    func lookup(_ key: String) -> String? {
        guard let text = entries[key] else { return nil }
        used.insert(key)
        return text
    }

    /// Keeps a finished section, on disk at once.
    func store(_ key: String, _ text: String) {
        entries[key] = text
        used.insert(key)
        persist(entries)
    }

    /// Once the whole digest is saved: drops sections of an older transcript.
    func prune() {
        let kept = entries.filter { used.contains($0.key) }
        guard kept.count != entries.count else { return }
        entries = kept
        persist(kept)
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
