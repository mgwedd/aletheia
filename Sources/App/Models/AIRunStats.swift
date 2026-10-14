import Foundation

/// What a model run reported about itself, from Ollama's final chunk
/// (`prompt_eval_count`, `prompt_eval_duration`, `eval_count`, `eval_duration`;
/// durations in nanoseconds). Any field can be missing, so each is optional.
struct AIRunStats: Equatable {
    var promptTokens: Int?
    var promptNanos: Int?
    var outputTokens: Int?
    var outputNanos: Int?
    /// Tokens Ollama should have had to read for this prompt (the shared
    /// `ContextBudget.estimatedTokens`), minus any leading part of the prompt it already holds from the
    /// previous request (see `PromptPrefixMemory`). 0 when unknown.
    var expectedPromptTokens: Int = 0

    /// Prompt tokens read per second. Needs enough tokens to be a real
    /// measurement; a short prompt's timing is mostly noise.
    var readTokensPerSecond: Double? {
        Self.rate(tokens: promptTokens, nanos: promptNanos, minimumTokens: 200)
    }

    /// Reply tokens written per second.
    var writeTokensPerSecond: Double? {
        Self.rate(tokens: outputTokens, nanos: outputNanos, minimumTokens: 20)
    }

    /// The tripwire: Ollama read well under what we sent, so it may have cut
    /// the prompt. Only judged for prompts big enough that the estimate is
    /// reliable, and against `expectedPromptTokens` so a cached prefix (which
    /// Ollama doesn't count in `prompt_eval_count`) isn't mistaken for a cut.
    ///
    /// Threshold: 60% of the estimate. The estimate is deliberately high (3
    /// characters a token; ordinary English tokenizes at about 4, so a complete
    /// read lands near 75% of it, and text heavy in long words nearer 65%). 60%
    /// sits under that spread, so only a real cut (a dropped chunk, not
    /// tokenizer noise) trips it.
    var possiblyTruncated: Bool {
        guard let promptTokens, expectedPromptTokens >= 500 else { return false }
        return promptTokens * 10 < expectedPromptTokens * 6
    }

    /// Shown under an answer or note when `possiblyTruncated`.
    static let truncationNotice = "The model may not have read all of the material; try again or lower the length."

    private static func rate(tokens: Int?, nanos: Int?, minimumTokens: Int) -> Double? {
        guard let tokens, let nanos, tokens >= minimumTokens, nanos > 0 else { return nil }
        return Double(tokens) / (Double(nanos) / 1_000_000_000)
    }
}

/// What a backend tells the UI while a run is going.
enum AIRunEvent {
    /// The prompt is built and about to be read; `estimatedTokens` is `ContextBudget.estimatedTokens`.
    case reading(estimatedTokens: Int)
    case finished(AIRunStats)
}

/// Live state of one run, for `AIProgressView`.
struct AIRunProgress: Equatable {
    /// Stage names: "Reading the session", "Writing the note".
    var readTitle = "Reading"
    var writeTitle = "Writing"
    var startedAt: Date?
    /// Set when the first text arrives: reading ends, writing starts.
    var firstTokenAt: Date?
    var estimatedPromptTokens: Int?
    /// Streamed chunks (about one per token) until Ollama reports the real count.
    var tokensWritten = 0
    var stats: AIRunStats?
}

/// Measured speeds for one model on this Mac, as a moving average.
struct ModelSpeed: Equatable {
    var read: Double?
    var write: Double?

    /// Weight of the newest run: recent enough to follow a thermal slowdown,
    /// steady enough that one odd run doesn't swing the estimate.
    private static let newest = 0.3

    init(read: Double? = nil, write: Double? = nil) {
        self.read = read
        self.write = write
    }

    /// From the UserDefaults form (a property-list dictionary).
    init(stored: [String: Double]) {
        self.init(read: stored["read"], write: stored["write"])
    }

    var stored: [String: Double] {
        var out: [String: Double] = [:]
        if let read { out["read"] = read }
        if let write { out["write"] = write }
        return out
    }

    func folding(_ stats: AIRunStats) -> ModelSpeed {
        ModelSpeed(
            read: Self.blend(read, stats.readTokensPerSecond),
            write: Self.blend(write, stats.writeTokensPerSecond)
        )
    }

    private static func blend(_ old: Double?, _ sample: Double?) -> Double? {
        guard let sample else { return old }
        guard let old else { return sample }
        return old * (1 - newest) + sample * newest
    }
}
