@testable import Aletheia
import Foundation

/// The AI model on this Mac, answering as the test tells it to. Nothing here
/// judges the quality of what a model would write: the checks are about what the
/// app asks it, and what the app does with what comes back.
///
/// Rules are tried in the order they were added; the first whose marker is found
/// anywhere in the request (instructions, earlier turns or prompt) answers, and a
/// rule made with `once` is used up by that answer. A request no rule matches gets
/// `fallback`.
final class SteeredModel: LocalLLMEngine, @unchecked Sendable {
    /// How the model answers one request.
    enum Answer {
        /// Writes this, then is done.
        case writes(String)
        /// Writes this much, then waits (until `release()` or until the app
        /// stops it) before finishing.
        case writesThenWaits(String)
        /// Reads the prompt in this many parts, then writes this. Each step
        /// (every part, finishing the reading, the first text) waits for
        /// `moveOn()`, so a test can look at the status between them.
        case readsInParts(Int, thenWrites: String)
        /// Fails with this error before writing anything.
        case fails(Error)
    }

    private struct Rule {
        let marker: String?
        let answer: Answer
        let once: Bool
    }

    private let lock = NSLock()
    private var rules: [Rule] = []
    private var asked: [LocalLLMRequest] = []
    private var releases = 0
    private var started = 0
    private var finished = 0
    private var fallbackText = "Understood."

    var state: LocalLLMEngineState { .ready }

    // MARK: Steering

    func answer(_ marker: String? = nil, with answer: Answer, once: Bool = false) {
        lock.lock(); rules.append(Rule(marker: marker, answer: answer, once: once)); lock.unlock()
    }

    func writes(_ text: String, whenAsked marker: String? = nil, once: Bool = false) {
        answer(marker, with: .writes(text), once: once)
    }

    func fallback(_ text: String) { lock.lock(); fallbackText = text; lock.unlock() }

    /// Lets every answer that is waiting finish.
    func release() { lock.lock(); releases += 1; lock.unlock() }

    /// The first request the app makes is held (after it has written a little) until `release()`.
    func pausesOnTheFirstRequest(writing text: String = "Understood.") {
        answer(nil, with: .writesThenWaits(text), once: true)
    }

    /// Asked which parts of a long session to read closely, it names the session's summary.
    func choosesToReadClosely() {
        answer("read-only local tool call", with: .writes(#"{"calls":[{"tool":"get_digest","session":"S1"}]}"#))
    }

    /// Asked to summarize a conversation so far, it writes `text`.
    func summarizesConversation(as text: String) {
        answer("Write a summary that will replace it", with: .writes(text))
    }

    /// Lets an answer that reads in parts take its next step.
    func moveOn() { release() }

    /// Answers by reading the prompt in `parts` parts, a step at a time (see `moveOn()`).
    func readsPromptInParts(_ parts: Int, thenWrites text: String, whenAsked marker: String? = nil, once: Bool = false) {
        answer(marker, with: .readsInParts(parts, thenWrites: text), once: once)
    }

    /// Drops every rule, so the model answers with its fallback again.
    func clearRules() { lock.lock(); rules = []; lock.unlock() }

    // MARK: What it was asked

    var requests: [LocalLLMRequest] { lock.lock(); defer { lock.unlock() }; return asked }
    var requestTexts: [String] { requests.map(Self.text(of:)) }
    /// Requests that have begun being answered, and those that have been given a whole answer or an error.
    var startedCount: Int { lock.lock(); defer { lock.unlock() }; return started }
    var finishedCount: Int { lock.lock(); defer { lock.unlock() }; return finished }

    static func text(of request: LocalLLMRequest) -> String {
        ([request.system] + request.turns.map(\.text) + [request.prompt]).joined(separator: "\n")
    }

    // MARK: LocalLLMEngine

    func load() async throws {}
    func unload() {}

    func generate(_ request: LocalLLMRequest) async throws -> String {
        var last = ""
        for try await text in stream(request) { last = text }
        return last
    }

    func stream(_ request: LocalLLMRequest) -> AsyncThrowingStream<String, Error> {
        stream(request, onStats: nil)
    }

    func stream(
        _ request: LocalLLMRequest, onStats: (@Sendable (AIRunStats) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        let (answer, ticket) = take(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch answer {
                case .fails(let error):
                    self.markFinished()
                    continuation.finish(throwing: error)
                case .writes(let text):
                    continuation.yield(text)
                    self.markFinished()
                    continuation.finish()
                case .readsInParts(let total, let text):
                    func report(_ prefill: PrefillProgress) {
                        var stats = AIRunStats()
                        stats.prefill = prefill
                        onStats?(stats)
                    }
                    report(PrefillProgress(part: 1, total: total))
                    for part in 2...max(2, total) where part <= total {
                        await self.wait(forRelease: ticket + part - 1)
                        report(PrefillProgress(part: part, total: total))
                    }
                    await self.wait(forRelease: ticket + total)
                    report(PrefillProgress(part: total, total: total, complete: true))
                    await self.wait(forRelease: ticket + total + 1)
                    if Task.isCancelled { self.markFinished(); continuation.finish(); return }
                    continuation.yield(text)
                    self.markFinished()
                    continuation.finish()
                case .writesThenWaits(let text):
                    continuation.yield(text)
                    while !Task.isCancelled, !self.wasReleased(since: ticket) {
                        try? await Task.sleep(nanoseconds: 5_000_000)
                    }
                    self.markFinished()
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func take(_ request: LocalLLMRequest) -> (Answer, Int) {
        lock.lock(); defer { lock.unlock() }
        asked.append(request)
        started += 1
        let text = Self.text(of: request)
        if let index = rules.firstIndex(where: { $0.marker.map(text.contains) ?? true }) {
            let rule = rules[index]
            if rule.once { rules.remove(at: index) }
            return (rule.answer, releases)
        }
        return (.writes(fallbackText), releases)
    }

    private func wait(forRelease count: Int) async {
        while !Task.isCancelled {
            lock.lock(); let reached = releases >= count; lock.unlock()
            if reached { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func wasReleased(since ticket: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return releases > ticket
    }

    private func markFinished() { lock.lock(); finished += 1; lock.unlock() }
}

/// Collects the notifications the app would post, without posting them.
final class QuietNotifier: AppNotifying, @unchecked Sendable {
    private let lock = NSLock()
    private var posted: [AppNotificationContent] = []
    var titles: [String] { lock.lock(); defer { lock.unlock() }; return posted.map(\.title) }
    func requestAuthorization() async {}
    func post(_ content: AppNotificationContent) async {
        lock.lock(); posted.append(content); lock.unlock()
    }
}
