import Foundation

/// Answers an Ask question about the therapist's own notes straight from My
/// Notes, on this Mac, with no model. My Notes never go into an AI prompt
/// (`AIContextPolicy`), so the model can't answer "What have I noted about…?";
/// this shows the matching paragraphs instead.
enum MyNotesLookup {
    /// Longest My Notes shown in full when nothing in them matches the question.
    static let wholeLimit = 1_500

    /// "What have I noted about…", "did I write anything on…", "what's in my
    /// notes". Asking for work done with the notes ("based on my notes…", "turn
    /// my notes into a SOAP note", "summarize the session") goes to the model.
    static func asksAboutNotes(_ question: String) -> Bool {
        let folded = question.lowercased().replacingOccurrences(of: "’", with: "'")
        let about = #"\b(have\s+i\s+(noted|written|wrote|jotted)|did\s+i\s+(note|write|jot)|what\s+did\s+i\s+(note|write|jot)|i'?ve\s+(noted|written|jotted)|(anything|something)\s+i\s+(noted|wrote|jotted)|i\s+(wrote|jotted)\s+down|in\s+my\s+((private|own)\s+)?notes|my\s+((private|own)\s+)?notes\s+(say|mention))\b"#
        let work = #"\b(transcript|soap|summar\w*|session\s+notes?|based\s+on|turn|draft|compare|match)\b"#
        return folded.range(of: about, options: .regularExpression) != nil
            && folded.range(of: work, options: .regularExpression) == nil
    }

    /// The reply for a question about My Notes, or nil when the question isn't
    /// about them or there are none.
    static func answer(question: String, notes: String) -> String? {
        guard asksAboutNotes(question) else { return nil }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let header = "From My Notes, read on this Mac. My Notes stay private, so the AI never reads them."
        let terms = SessionSearch.terms(from: question).filter { noteWords.isDisjoint(with: $0.words) }
        let asked = Set(terms.flatMap(\.words))
        let named = terms.map { $0.isName ? $0.text.capitalized : $0.text }.joined(separator: ", ")
        let paragraphs = trimmed
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let matching = asked.isEmpty ? [] : paragraphs.filter { !asked.isDisjoint(with: SessionSearch.tokenize($0)) }
        if !matching.isEmpty { return header + "\n\n" + matching.map(quoted).joined(separator: "\n\n") }
        if trimmed.count <= wholeLimit {
            let lead = asked.isEmpty ? "" : "Nothing in them mentions \(named). Here they are in full:\n\n"
            return header + "\n\n" + lead + quoted(trimmed)
        }
        if asked.isEmpty { return header + "\n\n" + quoted(String(trimmed.prefix(wholeLimit)) + "…") }
        return header + "\n\nNothing in them mentions \(named)."
    }

    /// Words about the notes themselves, not what to look for in them.
    private static let noteWords: Set<String> = [
        "noted", "note", "notes", "wrote", "written", "write", "jot", "jotted", "down",
        "ive", "i've", "anything", "something", "private", "own", "say", "mention",
    ]

    private static func quoted(_ text: String) -> String {
        text.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
    }
}
