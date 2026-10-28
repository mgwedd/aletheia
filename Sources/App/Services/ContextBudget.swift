import Foundation

/// How much text this Mac can have the model read in one go. Set from the
/// Mac's memory (`ModelAdvisor.contextBudgetTokens`): a bigger window costs
/// memory for the model's working state, so a prompt past the budget is not
/// sent. The app never lets the engine cut a prompt silently.
struct ContextBudget: Equatable {
    var tokens: Int

    #if DEBUG
    /// A UI test can set the window (see `FixtureScenario.contextTokens`).
    static let current = ContextBudget(
        tokens: FixtureMode.scenario?.contextTokens ?? ModelAdvisor.contextBudgetTokens(for: .current()))
    #else
    static let current = ContextBudget(tokens: ModelAdvisor.contextBudgetTokens(for: .current()))
    #endif

    /// Room kept for the reply and the prompt's own wrapper.
    static let replyHeadroomTokens = 2048

    /// The app's one text-to-tokens estimate. Latin-script text (English and
    /// other languages written in Latin letters) runs about 4 characters a
    /// token; 3 leaves margin for timestamps and names. Other scripts
    /// (Japanese, Chinese, Korean, Thai, …) run about a token a character, so
    /// each of their characters counts as `charactersPerToken` Latin ones (see
    /// `weightedLength`). The budget check, the progress display and the
    /// truncation tripwire all use it, so they agree with each other.
    static let charactersPerToken = 3

    /// Tokens for `characters` of Latin-script text, or for a `weightedLength`.
    static func estimatedTokens(forCharacters characters: Int) -> Int {
        characters / charactersPerToken
    }

    /// Tokens for `text`, by script: the same as `estimatedTokens(forCharacters:)`
    /// for English, about one a character for Japanese, Chinese or Korean.
    static func estimatedTokens<S: StringProtocol>(for text: S) -> Int {
        estimatedTokens(forCharacters: weightedLength(of: text))
    }

    /// Tokens for a request's instructions and prompt together.
    static func estimatedTokens(system: String, prompt: String) -> Int {
        estimatedTokens(forCharacters: weightedLength(of: system) + weightedLength(of: prompt))
    }

    /// `text`'s length in Latin-script characters, the unit this budget counts
    /// in: a Latin character (letters, accents, punctuation, digits) is 1, any
    /// other is `charactersPerToken` (a whole token). Equals `text.count` for
    /// English, so the English estimate is unchanged.
    static func weightedLength<S: StringProtocol>(of text: S) -> Int {
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.count }
        var total = 0
        for character in text { total += weight(of: character) }
        return total
    }

    /// The longest start of `text` whose `weightedLength` is at most `limit`.
    /// Never empty for non-empty text, so a caller cutting a long run moves on.
    static func prefix(_ text: Substring, weightedLength limit: Int) -> Substring {
        if text.utf8.allSatisfy({ $0 < 0x80 }) { return text.prefix(max(1, limit)) }
        var used = 0
        var end = text.startIndex
        for index in text.indices {
            let cost = weight(of: text[index])
            if used + cost > limit, end != text.startIndex { break }
            used += cost
            end = text.index(after: index)
        }
        return text[text.startIndex..<end]
    }

    /// How many characters of text like `sample` fit in `room`, a length in
    /// the budget's unit (`availableCharacters`, `weightedLength`): all of
    /// `room` for Latin-script text, about a third of it for Japanese.
    static func characters(fitting room: Int, like sample: String) -> Int {
        let count = sample.count
        let weighted = weightedLength(of: sample)
        guard count > 0, weighted > count else { return room }
        return Int(Double(room) * Double(count) / Double(weighted))
    }

    private static func weight(of character: Character) -> Int {
        var other = 0
        for scalar in character.unicodeScalars where !isLatin(scalar) { other += 1 }
        return other == 0 ? 1 : other * charactersPerToken
    }

    /// Basic Latin, Latin-1, Latin Extended, IPA, combining accents, Latin
    /// Extended Additional, general punctuation and currency signs.
    private static func isLatin(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0...0x036F, 0x1E00...0x1EFF, 0x2000...0x206F, 0x20A0...0x20CF: return true
        default: return false
        }
    }

    /// The window a prompt needs: its estimated tokens plus room for the reply.
    /// `characters` is a `weightedLength`.
    static func neededTokens(forCharacters characters: Int) -> Int {
        estimatedTokens(forCharacters: characters) + replyHeadroomTokens
    }

    /// How much more a prompt can carry on top of `reserved` already spoken
    /// for (instructions, history, question), both as a `weightedLength`. For
    /// text that isn't Latin-script, convert with `characters(fitting:like:)`.
    /// Keeps a tenth back, so a rough header or count can't tip it over.
    func availableCharacters(reserving reserved: Int) -> Int {
        let usable = max(0, tokens - Self.replyHeadroomTokens) * Self.charactersPerToken * 9 / 10
        return max(0, usable - reserved)
    }

    /// `promptCharacters` is a `weightedLength` (the character count, for English).
    func fits(promptCharacters: Int) -> Bool {
        Self.neededTokens(forCharacters: promptCharacters) <= tokens
    }

    /// Whether a request's instructions and prompt fit, measured by script.
    func fits(system: String, prompt: String) -> Bool {
        fits(promptCharacters: Self.weightedLength(of: system) + Self.weightedLength(of: prompt))
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
        "This conversation leaves no room to read the sessions. Use Compact to shorten it, or start a new chat, and ask again."
    }
}

/// A prompt too big for the budget. Shown as-is: no truncated prompt is sent.
struct ContextBudgetError: LocalizedError, Equatable {
    let minutes: Int

    var errorDescription: String? {
        "This session is longer than this Mac can read at once (~\(minutes) min). For a note, shorten your note instructions or comments and try again. For a question, ask about a shorter stretch."
    }
}
