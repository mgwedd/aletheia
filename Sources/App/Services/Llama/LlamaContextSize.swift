import Foundation

/// How big a window the embedded model's context needs, from the real tokenized
/// prompt. Pure math, so it is testable without a model.
enum LlamaContextSize {
    /// The smallest window (the same 8K floor `ModelAdvisor.contextBudgetTokens` keeps).
    static let floorTokens = 8_192

    /// `needed` rounded up to a power of two, never below the floor. A few stable
    /// sizes, so the context built for one session is reused for the next.
    static func bucket(for needed: Int) -> Int {
        var size = floorTokens
        while size < needed { size *= 2 }
        return size
    }

    /// The window for a prompt of `promptTokens` plus `replyTokens` of reply. Capped
    /// at this Mac's `budget` (set from its memory) and at the model's
    /// `trainContext` (0 = unknown). Over the cap it throws `ContextBudgetError`:
    /// nothing is cut.
    static func contextTokens(
        promptTokens: Int, replyTokens: Int, trainContext: Int, budget: ContextBudget
    ) throws -> Int {
        let cap = trainContext > 0 ? min(budget.tokens, trainContext) : budget.tokens
        let needed = promptTokens + replyTokens
        guard needed <= cap else {
            throw ContextBudgetError(minutes: ContextBudget(tokens: cap).approximateMinutes)
        }
        return min(bucket(for: needed), cap)
    }
}
