import Combine
import Foundation

/// Drives the *responsive-but-calm* streaming reveal for a chat answer.
///
/// The problem it solves: a local model emits text in bursty clumps (Ollama
/// NDJSON, llama.cpp tokens, Foundation Models snapshots), and painting each
/// burst straight to screen either machine-guns characters or lurches in
/// paragraph-sized jumps — both feel worse than a steady flow. So this splits
/// the two clocks:
///
///  - a **producer** loop reads the backend's cumulative "full text so far" as
///    fast as it arrives, only updating a target string; and
///  - a **revealer** loop, on a steady ~30ms tick, advances the *shown* prefix
///    toward that target using `StreamSmoother` (word-snapped, adaptive), so
///    the reader always sees an even, word-by-word crawl that quietly speeds up
///    when the model has raced ahead.
///
/// Stop cancels generation but keeps whatever was already revealed and persists
/// it, matching how ChatGPT/Claude's Stop behaves.
///
/// Every run goes through the shared `InferenceQueue`, so a request made while
/// another generation is running waits its turn (`isQueued`, `queuedStatus`)
/// instead of hanging silently behind it. The stream is built lazily, only once
/// the job actually starts, so no request reaches the model while queued.
@MainActor
final class ChatStreamRunner: ObservableObject {
    /// True from the moment the job starts running until the reveal has drained
    /// and finished/errored.
    @Published private(set) var isStreaming = false
    /// True from `start` until the job begins running (or is cancelled).
    @Published private(set) var isQueued = false
    /// Whether the last run ended by Stop rather than running to completion;
    /// read it in `onFinish` to tell a partial result from a whole one.
    private(set) var wasStopped = false
    /// Live state of the current (or last) run, for `AIProgressView`, and the
    /// run's own stats once it ends (for the truncation notice).
    @Published private(set) var progress = AIRunProgress()

    /// Hand this to `makeAssistantService(report:)` just before `start`, so the
    /// run's events reach `progress`. Each call mints a new run id: events from an
    /// earlier reporter (a late `.finished` from the previous run) are ignored.
    var reporter: @Sendable (AIRunEvent) -> Void {
        let run = UUID()
        currentRun = run
        return { [weak self] event in Task { @MainActor in self?.apply(event, run: run) } }
    }

    private(set) var currentRun = UUID()
    /// Set once a run reports its own stages through `update`; then the run's
    /// token counts and stats are the stages', not the reveal's.
    private var externalStages = false

    /// Lets a multi-stage run (digest, passages, check) report its own stage.
    /// A change from a stage that has since been replaced (`started` no longer
    /// matches) is dropped; nil applies to whatever is current.
    func update(started: Date?, _ change: (inout AIRunProgress) -> Void) {
        externalStages = true
        if let started, let current = progress.startedAt, started != current { return }
        change(&progress)
    }

    func apply(_ event: AIRunEvent, run: UUID) {
        // A run that reports its own stages (see `update`) filters its events by
        // stage, so a late event from an earlier stage can't land on a later one.
        guard run == currentRun, !externalStages else { return }
        switch event {
        case .reading(let tokens):
            progress.estimatedPromptTokens = tokens
        case .finished(let stats):
            progress.stats = stats
            if let written = stats.outputTokens { progress.tokensWritten = written }
        }
    }

    /// Plain status line while this run is waiting behind another generation;
    /// nil when it is not waiting (including the instant before an idle queue
    /// picks the job up).
    var queuedStatus: String? {
        guard isQueued, let queue, let jobID else { return nil }
        return queue.waitingStatus(for: jobID)
    }

    private var target = ""
    private var finishedReceiving = false
    private var failure: Error?
    private var producer: Task<Void, Never>?
    private var revealer: Task<Void, Never>?

    private var queue: InferenceQueue?
    private var queueObserver: AnyCancellable?
    /// Id of the job in the queue, for cancelling it.
    private var jobID: UUID?
    /// Identifies the current run; cleared by `stop()` while queued so a job
    /// that is already scheduled becomes a no-op.
    private var jobToken: UUID?
    private var onCancelledWhileQueued: (() -> Void)?
    private var titles = (read: "Reading", write: "Writing")
    /// When the work behind this run began (an Ask's search), so the status
    /// line's counter carries on from it; nil starts it with the model.
    private var runStartedAt: Date?
    private var chunkCount = 0

    /// Interval between reveal ticks. Small enough to feel live, large enough
    /// that each tick reveals a readable chunk rather than one twitchy glyph.
    private let tickNanos: UInt64 = 30_000_000

    /// Queue a generation and, when its turn comes, consume the stream
    /// (cumulative text) and smooth it into the UI.
    /// - makeStream: called when the job starts, not when it is queued.
    /// - onReveal: called on the main actor with the growing displayed prefix.
    /// - onError: called if the stream fails before any text arrived.
    /// - onFinish: called with the final full text once the reveal has drained
    ///   (also on Stop, with the text produced so far).
    /// - onCancelledWhileQueued: called if Stop/Cancel arrives before the job
    ///   started, so the caller can undo its "sending" state. Nothing else
    ///   fires in that case.
    func start(
        queue: InferenceQueue,
        kind: InferenceQueue.Kind,
        label: String,
        readTitle: String = "Reading",
        writeTitle: String = "Writing",
        runStartedAt: Date? = nil,
        makeStream: @escaping () -> AsyncThrowingStream<String, Error>,
        onReveal: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void,
        onFinish: @escaping (String) -> Void,
        onCancelledWhileQueued: @escaping () -> Void = {}
    ) {
        stop()
        titles = (readTitle, writeTitle)
        self.runStartedAt = runStartedAt
        self.queue = queue
        self.onCancelledWhileQueued = onCancelledWhileQueued
        isQueued = true
        // Re-render when the queue's state changes so the status line follows
        // whichever job is ahead.
        queueObserver = queue.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        let token = UUID()
        jobToken = token
        // Weak self: if the view (and so this runner) goes away while the job
        // is waiting, the job is skipped instead of generating for nobody.
        let job = queue.enqueue(kind: kind, label: label) { [weak self] in
            guard let self else { return }
            await self.run(
                token: token,
                makeStream: makeStream,
                onReveal: onReveal,
                onError: onError,
                onFinish: onFinish
            )
        }
        jobID = job.id
    }

    /// Stop generation now, keep what's shown. The revealer drains the current
    /// target and then calls `onFinish`, so the partial answer is persisted.
    /// If the job is still waiting its turn it is dropped instead.
    func stop() {
        if isQueued {
            cancelQueued()
            return
        }
        producer?.cancel()
        finishedReceiving = true
        wasStopped = true
    }

    /// Drops a job that has not started: it never runs and the queue moves on.
    private func cancelQueued() {
        if let jobID { queue?.cancel(jobID) }
        jobToken = nil
        jobID = nil
        isQueued = false
        queueObserver = nil
        let callback = onCancelledWhileQueued
        onCancelledWhileQueued = nil
        callback?()
    }

    /// The queued job body. Returns when the reveal has finished, so the queue
    /// only advances once this answer is fully done.
    private func run(
        token: UUID,
        makeStream: () -> AsyncThrowingStream<String, Error>,
        onReveal: @escaping (String) -> Void,
        onError: @escaping (Error) -> Void,
        onFinish: @escaping (String) -> Void
    ) async {
        guard jobToken == token else { return }
        // Cancelled through the queue itself before it got going.
        if Task.isCancelled {
            cancelQueued()
            return
        }
        isQueued = false
        queueObserver = nil
        onCancelledWhileQueued = nil
        target = ""
        finishedReceiving = false
        failure = nil
        wasStopped = false
        externalStages = false
        chunkCount = 0
        progress = AIRunProgress(readTitle: titles.read, writeTitle: titles.write, startedAt: Date())
        progress.runStartedAt = runStartedAt
        isStreaming = true

        let stream = makeStream()
        producer = Task { [weak self] in
            do {
                for try await snapshot in stream {
                    if Task.isCancelled { break }
                    guard let self else { break }
                    self.target = snapshot
                    self.chunkCount += 1
                    if self.progress.firstTokenAt == nil { self.progress.firstTokenAt = Date() }
                }
            } catch {
                self?.failure = error
            }
            self?.finishedReceiving = true
        }

        let revealer = Task { [weak self] in
            guard let self else { return }
            var displayed = 0
            while !Task.isCancelled {
                let next = StreamSmoother.nextCount(displayed: displayed, target: self.target)
                if next != displayed {
                    displayed = next
                    onReveal(StreamSmoother.prefix(of: self.target, count: displayed))
                }
                // The real count replaces this once the run reports its stats.
                if self.progress.stats == nil, !self.externalStages, self.chunkCount > 0, self.progress.tokensWritten != self.chunkCount {
                    self.progress.tokensWritten = self.chunkCount
                }
                if self.finishedReceiving && displayed >= self.target.count { break }
                try? await Task.sleep(nanoseconds: self.tickNanos)
            }
            // Snap to the complete text so no trailing characters are dropped.
            onReveal(self.target)
            self.isStreaming = false
            self.producer = nil
            self.revealer = nil
            if self.jobToken == token {
                self.jobToken = nil
                self.jobID = nil
            }
            if let failure = self.failure, self.target.isEmpty {
                onError(failure)
            } else {
                onFinish(self.target)
            }
        }
        self.revealer = revealer

        // If the queue cancels this job, behave like Stop.
        await withTaskCancellationHandler {
            await revealer.value
        } onCancel: {
            Task { @MainActor [weak self] in self?.stop() }
        }
    }
}

extension Array where Element == ChatMessage {
    /// Insert or replace a message by id, preserving its original timestamp so a
    /// streamed assistant bubble doesn't jump around as it grows.
    mutating func upsert(id: UUID, role: ChatRole, text: String) {
        if let index = firstIndex(where: { $0.id == id }) {
            self[index] = ChatMessage(id: id, role: role, text: text, date: self[index].date)
        } else {
            append(ChatMessage(id: id, role: role, text: text))
        }
    }
}
