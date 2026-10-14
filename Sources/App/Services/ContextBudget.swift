import Foundation

/// How much text this Mac can have the model read in one go. Set from the
/// Mac's memory (`ModelAdvisor.contextBudgetTokens`): a bigger window costs
/// memory for the model's working state, so a prompt past the budget is not
/// sent. The app never lets Ollama cut a prompt silently.
struct ContextBudget: Equatable {
    var tokens: Int

    static let current = ContextBudget(tokens: ModelAdvisor.contextBudgetTokens(for: .current()))

    /// Room kept for the reply and the prompt's own wrapper.
    static let replyHeadroomTokens = 2048

    /// A conservative estimate (English runs about 4 characters a token; 3
    /// leaves margin for timestamps and names) of the window a prompt needs.
    static func neededTokens(forCharacters characters: Int) -> Int {
        characters / 3 + replyHeadroomTokens
    }

    func fits(promptCharacters: Int) -> Bool {
        Self.neededTokens(forCharacters: promptCharacters) <= tokens
    }

    /// Roughly how many minutes of conversation fit (a transcript runs about
    /// 1,100 characters a minute), for the message shown when one doesn't.
    var approximateMinutes: Int {
        max(0, tokens - Self.replyHeadroomTokens) * 3 / 1100
    }
}

/// A prompt too big for the budget. Shown as-is: no truncated prompt is sent.
struct ContextBudgetError: LocalizedError, Equatable {
    let minutes: Int

    var errorDescription: String? {
        "This session is longer than this Mac can read at once (~\(minutes) min). Long-session support is coming; for now, ask about a shorter stretch or write this note from your own notes."
    }
}
