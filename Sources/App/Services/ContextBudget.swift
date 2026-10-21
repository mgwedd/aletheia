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

    /// The app's one characters-to-tokens estimate: English runs about 4
    /// characters a token; 3 leaves margin for timestamps and names. The budget
    /// check, `num_ctx` sizing, the progress display and the truncation tripwire
    /// all use it, so they agree with each other.
    ///
    /// Assumes English, the only language supported for now. Scripts that
    /// tokenize near a token per character (Chinese, Japanese, Korean, and others)
    /// would be underestimated about threefold; supporting them means a
    /// script-aware estimate here and a truncation check that also fires when
    /// the prompt reaches the whole window.
    static let charactersPerToken = 3

    static func estimatedTokens(forCharacters characters: Int) -> Int {
        characters / charactersPerToken
    }

    /// The window a prompt needs: its estimated tokens plus room for the reply.
    static func neededTokens(forCharacters characters: Int) -> Int {
        estimatedTokens(forCharacters: characters) + replyHeadroomTokens
    }

    /// How many more characters a prompt can carry on top of `reserved`
    /// characters already spoken for (instructions, history, question). Keeps
    /// a tenth back, so a rough header or count can't tip it over.
    func availableCharacters(reserving reserved: Int) -> Int {
        let usable = max(0, tokens - Self.replyHeadroomTokens) * Self.charactersPerToken * 9 / 10
        return max(0, usable - reserved)
    }

    func fits(promptCharacters: Int) -> Bool {
        Self.neededTokens(forCharacters: promptCharacters) <= tokens
    }

    /// Roughly how many minutes of conversation fit (a transcript runs about
    /// 1,100 characters a minute), for the message shown when one doesn't.
    var approximateMinutes: Int {
        max(0, tokens - Self.replyHeadroomTokens) * Self.charactersPerToken / 1100
    }
}

/// A patient-wide question whose instructions and conversation leave no room
/// for session material on this Mac. Nothing is sent.
struct PatientContextBudgetError: LocalizedError, Equatable {
    var errorDescription: String? {
        "This conversation leaves no room to read the sessions on this Mac. Use Compact to shorten it, or start a new chat, and ask again."
    }
}

/// A prompt too big for the budget. Shown as-is: no truncated prompt is sent.
struct ContextBudgetError: LocalizedError, Equatable {
    let minutes: Int

    var errorDescription: String? {
        "This session is longer than this Mac can read at once (~\(minutes) min). For a note, shorten your note instructions or comments and try again. For a question, ask about a shorter stretch."
    }
}
