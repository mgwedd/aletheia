import Foundation

/// Sampling parameters for a local-LLM generation.
///
/// Clinical documentation defaults to **deterministic** (greedy) decoding, so the
/// same transcript yields the same note — reproducibility matters more than
/// variety here.
struct LocalLLMSampling: Equatable {
    /// Hard cap on generated tokens.
    var maxTokens: Int
    /// 0 (or less) means greedy/deterministic; higher values add randomness.
    var temperature: Double
    /// Optional fixed seed for reproducible sampling when `temperature > 0`.
    var seed: UInt32?
    /// Penalty applied to recently generated tokens (> 1.0 discourages loops; 1.0 disables).
    var repeatPenalty: Double
    /// How many recent tokens the repeat penalty inspects.
    var repeatLastN: Int

    init(
        maxTokens: Int = 512,
        temperature: Double = 0,
        seed: UInt32? = nil,
        repeatPenalty: Double = 1.0,
        repeatLastN: Int = 64
    ) {
        self.maxTokens = maxTokens
        self.temperature = temperature
        self.seed = seed
        self.repeatPenalty = repeatPenalty
        self.repeatLastN = repeatLastN
    }

    /// Greedy decoding — reproducible output for clinical notes.
    static let deterministic = LocalLLMSampling(maxTokens: 512, temperature: 0)

    /// Task-tuned sampling: uses the task's reply cap and temperature with a
    /// mild repeat penalty so 3B/8B models don't loop on bullet lists.
    static func forTask(_ task: AITask, maxTokens: Int? = nil) -> LocalLLMSampling {
        LocalLLMSampling(
            maxTokens: maxTokens ?? task.maxTokens,
            temperature: task.temperature,
            repeatPenalty: 1.1,
            repeatLastN: 64
        )
    }

    /// Whether this resolves to greedy decoding (no sampling randomness).
    var isGreedy: Bool { temperature <= 0 }
}

/// A GBNF grammar that constrains decoding so the model's output always parses
/// into the app — e.g. a specific progress-note structure that the Notes view
/// can render and thread against without malformed markdown breaking it.
///
/// This is the *carrier*: `label` names the source (e.g. "SOAP") for diagnostics
/// and `gbnf` is the grammar text handed to the runtime. Generating the grammar
/// per note format (SOAP/DAP/BIRP/GIRP) is layered on separately (see the epic);
/// the seam only needs to carry one.
struct LocalLLMGrammar: Equatable {
    let label: String
    let gbnf: String
}

/// One local-LLM generation request: the standing system prompt, the turn
/// prompt, sampling parameters, and an optional grammar.
///
/// This is the stable contract the engine is built around, and the seam that
/// GBNF-constrained decoding and fine-tuned / LoRA models plug into later —
/// adding a grammar or swapping the model never changes call sites.
struct LocalLLMRequest {
    var system: String
    var prompt: String
    var sampling: LocalLLMSampling
    var grammar: LocalLLMGrammar?

    init(
        system: String = "",
        prompt: String,
        sampling: LocalLLMSampling = .deterministic,
        grammar: LocalLLMGrammar? = nil
    ) {
        self.system = system
        self.prompt = prompt
        self.sampling = sampling
        self.grammar = grammar
    }

}
