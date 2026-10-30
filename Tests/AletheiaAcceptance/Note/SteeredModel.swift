@testable import Aletheia
import Foundation

/// The AI model on this Mac, answering as the test tells it to. Nothing here
/// judges the quality of what a model would write: the checks are about what the
/// app asks it, and what the app does with what comes back.
///
/// A thin face over the app's `ScriptedModel` (the same rules the fixture runs
/// of the UI tests use): rules are tried in the order they were added; the first
/// whose marker is found anywhere in the request's text (instructions, earlier
/// turns or prompt) answers, and a rule made with `once` is used up by that
/// answer. A request no rule matches gets `fallback`.
///
/// Held answers are per request: `release()` (or `moveOn()`) lets the oldest held
/// step go on, or, when nothing is held yet, is kept for the next step that holds.
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

        var scripted: ScriptedModel.Answer {
            switch self {
            case .writes(let text): return .writes(text)
            case .writesThenWaits(let text): return .writesThenHolds(text)
            case .readsInParts(let parts, let text): return .readsInParts(parts, thenWrites: text)
            case .fails(let error): return .fails(error)
            }
        }
    }

    let model = ScriptedModel(pace: .held)

    var state: LocalLLMEngineState { model.state }

    // MARK: Steering

    func answer(_ marker: String? = nil, with answer: Answer, once: Bool = false) {
        model.add(.init(marker: marker, answer: answer.scripted, once: once))
    }

    func writes(_ text: String, whenAsked marker: String? = nil, once: Bool = false) {
        answer(marker, with: .writes(text), once: once)
    }

    func fallback(_ text: String) { model.setFallback([text]) }

    /// Lets the oldest held answer go on (or the next one, if none is held yet).
    func release() { model.release() }

    /// Lets every held answer go on and every later one pass at once. For teardown.
    func releaseEverything() { model.releaseEverything() }

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

    /// Every request fails as it does when the model file is not on this Mac.
    func failsAsNotDownloaded() { answer(nil, with: .fails(LocalLLMEngineError.modelNotDownloaded)) }

    /// Lets an answer that reads in parts take its next step.
    func moveOn() { model.release() }

    /// Answers by reading the prompt in `parts` parts, a step at a time (see `moveOn()`).
    func readsPromptInParts(_ parts: Int, thenWrites text: String, whenAsked marker: String? = nil, once: Bool = false) {
        answer(marker, with: .readsInParts(parts, thenWrites: text), once: once)
    }

    /// Drops every rule, so the model answers with its fallback again.
    func clearRules() { model.clearRules() }

    /// Returns once the app has asked the model `count` times in all.
    func waitUntilAsked(count: Int, within seconds: Double = 30) async throws {
        try await model.waitUntilAsked(count: count, within: seconds)
    }

    // MARK: What it was asked

    var requests: [LocalLLMRequest] { model.requests }
    var requestTexts: [String] { model.requestTexts }
    /// Requests that have begun being answered, and those that have been given a whole answer or an error.
    var startedCount: Int { model.startedCount }
    var finishedCount: Int { model.finishedCount }
    /// Steps holding now, waiting for `release()`.
    var heldCount: Int { model.heldCount }

    static func text(of request: LocalLLMRequest) -> String { ScriptedModel.text(of: request) }

    // MARK: LocalLLMEngine

    func load() async throws {}
    func unload() {}

    func generate(_ request: LocalLLMRequest) async throws -> String { try await model.generate(request) }

    func stream(_ request: LocalLLMRequest) -> AsyncThrowingStream<String, Error> { model.stream(request) }

    func stream(
        _ request: LocalLLMRequest, onStats: (@Sendable (AIRunStats) -> Void)?
    ) -> AsyncThrowingStream<String, Error> {
        model.stream(request, onStats: onStats)
    }
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
