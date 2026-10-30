#if DEBUG
import Foundation

/// A local model that answers from a script: the one rule-and-answer model
/// behind both test layers. The acceptance suite steers it directly
/// (`SteeredModel`); a fixture run builds it from the scenario
/// (`FixtureScriptedEngine`). Only compiled into Debug builds.
///
/// Rules are tried in the order they were added; the first whose marker is found
/// anywhere in the request's text (instructions, earlier turns' text and prompt)
/// answers, and a rule made with `once` is used up by that answer. A request no
/// rule matches gets the fallback replies, in order, the last one repeating.
///
/// A held step waits until `release()`: each call lets the oldest held step go
/// on, or, when nothing is held yet, is kept for the next step that would hold.
final class ScriptedModel: LocalLLMEngine, @unchecked Sendable {
    /// How the model answers one request.
    enum Answer {
        /// Writes this, then is done.
        case writes(String)
        /// Writes this much, then holds (until released or stopped) before finishing.
        case writesThenHolds(String)
        /// Reads the prompt in this many parts, then writes this. Each step
        /// (every further part, finishing the reading, the first text) is paced.
        case readsInParts(Int, thenWrites: String)
        /// Fails with this error before writing anything.
        case fails(Error)
    }

    /// How a step of `readsInParts` waits.
    enum Pace {
        /// Until `release()`.
        case held
        /// This long.
        case timed(nanoseconds: UInt64)
    }

    struct Rule {
        var marker: String?
        var answer: Answer
        var once: Bool
    }

    /// Thrown by `waitUntilAsked` when the requests never come.
    struct NotAsked: Error, CustomStringConvertible {
        let wanted: Int
        let asked: Int
        let seconds: Double
        var description: String { "the model was asked \(asked) time(s) in \(seconds)s, wanted \(wanted)" }
    }

    static func text(of request: LocalLLMRequest) -> String {
        ([request.system] + request.turns.map(\.text) + [request.prompt]).joined(separator: "\n")
    }

    // MARK: Script

    private let lock = NSLock()
    private var rules: [Rule] = []
    private var fallbackReplies: [String]
    private var nextFallback = 0
    /// How each step of `readsInParts` waits.
    private let pace: Pace
    /// A pause before writing and between streamed words; zero writes at once.
    private let stageNanoseconds: UInt64
    /// When above one, every streamed `writes` answer first reads the prompt in this many parts.
    private let partsForEveryAnswer: Int
    /// Streamed text arrives a word at a time, then the answer stays open until stopped.
    private let streamsWords: Bool

    // MARK: Record

    private var asked: [LocalLLMRequest] = []
    private var started = 0
    private var finished = 0
    private var held: [(id: UInt64, resume: CheckedContinuation<Void, Never>)] = []
    private var banked = 0
    private var releasedForGood = false
    private var nextHoldID: UInt64 = 0
    private var askWaiters: [(id: UInt64, count: Int, resume: CheckedContinuation<Void, Never>)] = []

    var state: LocalLLMEngineState { .ready }

    init(fallback: [String] = ["Understood."], pace: Pace = .held, stageMs: Int = 0,
         partsForEveryAnswer: Int = 0, streamsWords: Bool = false) {
        self.fallbackReplies = fallback
        self.pace = pace
        self.stageNanoseconds = UInt64(max(0, stageMs)) * 1_000_000
        self.partsForEveryAnswer = partsForEveryAnswer
        self.streamsWords = streamsWords
    }

    // MARK: Steering

    func add(_ rule: Rule) {
        lock.lock(); rules.append(rule); lock.unlock()
    }

    func setFallback(_ replies: [String]) {
        lock.lock(); fallbackReplies = replies; nextFallback = 0; lock.unlock()
    }

    func clearRules() { lock.lock(); rules = []; lock.unlock() }

    /// Lets the oldest held step go on, or keeps the release for the next one.
    func release() {
        lock.lock()
        guard !held.isEmpty else { banked += 1; lock.unlock(); return }
        let first = held.removeFirst()
        lock.unlock()
        first.resume.resume()
    }

    /// Lets every held step go on, and every later one pass at once. For teardown.
    func releaseEverything() {
        lock.lock()
        releasedForGood = true
        let all = held
        held = []
        lock.unlock()
        for waiter in all { waiter.resume.resume() }
    }

    // MARK: What it was asked

    var requests: [LocalLLMRequest] { lock.lock(); defer { lock.unlock() }; return asked }
    var requestTexts: [String] { requests.map(Self.text(of:)) }
    var startedCount: Int { lock.lock(); defer { lock.unlock() }; return started }
    var finishedCount: Int { lock.lock(); defer { lock.unlock() }; return finished }
    /// Steps holding now, waiting for `release()`.
    var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }

    /// Returns once the model has been asked `count` times in all, or throws `NotAsked`.
    func waitUntilAsked(count: Int, within seconds: Double = 30) async throws {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask { await self.untilAsked(atLeast: count); return true }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return false
            }
            let reached = try await group.next() ?? false
            group.cancelAll()
            if !reached { throw NotAsked(wanted: count, asked: startedCount, seconds: seconds) }
        }
    }

    private func untilAsked(atLeast count: Int) async {
        lock.lock(); let id = nextHoldID; nextHoldID += 1; lock.unlock()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if started >= count || Task.isCancelled { lock.unlock(); continuation.resume(); return }
                askWaiters.append((id, count, continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let index = askWaiters.firstIndex { $0.id == id }
            let waiter = index.map { askWaiters.remove(at: $0) }
            lock.unlock()
            waiter?.resume.resume()
        }
    }

    // MARK: LocalLLMEngine

    func load() async throws {}
    func unload() {}

    func generate(_ request: LocalLLMRequest) async throws -> String {
        var last = ""
        for try await text in stream(request, onStats: nil) { last = text }
        return last
    }

    func stream(_ request: LocalLLMRequest) -> AsyncThrowingStream<String, Error> {
        stream(request, onStats: nil)
    }

    func stream(
        _ request: LocalLLMRequest, onStats: (@Sendable (AIRunStats) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        let answer = take(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.play(answer, onStats: onStats, into: continuation)
                    self.markFinished()
                    continuation.finish()
                } catch {
                    self.markFinished()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func play(
        _ answer: Answer, onStats: (@Sendable (AIRunStats) -> Void)?,
        into continuation: AsyncThrowingStream<String, Error>.Continuation
    ) async throws {
        switch answer {
        case .fails(let error):
            throw error
        case .writes(let text):
            if partsForEveryAnswer > 1, let onStats {
                try await readPrompt(parts: partsForEveryAnswer, onStats: onStats)
            }
            try await write(text, into: continuation)
        case .readsInParts(let total, let text):
            try await readPrompt(parts: total, onStats: onStats)
            try await step()
            if Task.isCancelled { return }
            try await write(text, into: continuation)
        case .writesThenHolds(let text):
            continuation.yield(text)
            await hold()
        }
    }

    /// Reports each part, then the reading done, a paced step apart.
    private func readPrompt(parts total: Int, onStats: (@Sendable (AIRunStats) -> Void)?) async throws {
        func report(_ prefill: PrefillProgress) {
            var stats = AIRunStats()
            stats.prefill = prefill
            onStats?(stats)
        }
        report(PrefillProgress(part: 1, total: total))
        if total >= 2 {
            for part in 2...total {
                try await step()
                report(PrefillProgress(part: part, total: total))
            }
        }
        try await step()
        report(PrefillProgress(part: total, total: total, complete: true))
    }

    private func write(_ text: String, into continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        if stageNanoseconds > 0 { try await Task.sleep(nanoseconds: stageNanoseconds) }
        guard streamsWords else { continuation.yield(text); return }
        var shown = ""
        for word in text.components(separatedBy: " ") {
            shown = shown.isEmpty ? word : shown + " " + word
            continuation.yield(shown)
            try await Task.sleep(nanoseconds: stageNanoseconds)
        }
        // Stay open until stopped, still, so a UI test can click Stop mid-answer:
        // XCUI clicks wait for the app to go idle, which it never does while words arrive.
        await hold()
    }

    private func step() async throws {
        switch pace {
        case .held:
            await hold()
        case .timed(let nanoseconds):
            try await Task.sleep(nanoseconds: max(nanoseconds, stageNanoseconds))
        }
    }

    /// Suspends until released, or until the request is stopped.
    private func hold() async {
        lock.lock(); let id = nextHoldID; nextHoldID += 1; lock.unlock()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if releasedForGood { lock.unlock(); continuation.resume(); return }
                if banked > 0 { banked -= 1; lock.unlock(); continuation.resume(); return }
                if Task.isCancelled { lock.unlock(); continuation.resume(); return }
                held.append((id, continuation))
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let index = held.firstIndex { $0.id == id }
            let waiter = index.map { held.remove(at: $0) }
            lock.unlock()
            waiter?.resume.resume()
        }
    }

    private func take(_ request: LocalLLMRequest) -> Answer {
        lock.lock()
        asked.append(request)
        started += 1
        let ready = askWaiters.filter { $0.count <= started }
        askWaiters.removeAll { $0.count <= started }
        let text = Self.text(of: request)
        let answer: Answer
        if let index = rules.firstIndex(where: { $0.marker.map(text.contains) ?? true }) {
            answer = rules[index].answer
            if rules[index].once { rules.remove(at: index) }
        } else if fallbackReplies.isEmpty {
            answer = .writes("")
        } else {
            answer = .writes(fallbackReplies[min(nextFallback, fallbackReplies.count - 1)])
            nextFallback += 1
        }
        lock.unlock()
        for waiter in ready { waiter.resume.resume() }
        return answer
    }

    private func markFinished() { lock.lock(); finished += 1; lock.unlock() }
}
#endif
