import Foundation

/// Tidies a generated progress note's Markdown so it reads like a set document.
///
/// Local models often write a note the way they'd write a chat reply: a
/// "Here is a summary…:" opener, paragraphs separated by a single newline (which
/// Markdown folds into one block), and section labels as bare "Label:" lines.
///
///     Here is a concise summary of the session:      ← dropped
///     The client reported…                            ┐ one paragraph each
///     Notable statements include…                     ┘ (blank line between)
///     Mood/affect observations: The client…           → **Mood/affect observations:** The client…
///     Follow-ups to revisit next session:             → ### Follow-ups to revisit next session
///     - …
///
/// Only prose lines are touched: fenced code, lists, quotes, headings, rules and
/// tables pass through unchanged. Pure and idempotent, so it runs both when a
/// note is saved and when an older, untidied note is displayed or copied.
enum NoteMarkdown {
    static func tidy(_ text: String) -> String {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        dropPreamble(&lines)

        var out: [String] = []
        var inFence = false
        var previousWasProse = false
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if isFence(trimmed) {
                inFence.toggle()
                out.append(line)
                previousWasProse = false
                continue
            }
            guard !inFence, isProse(line) else {
                out.append(line)
                previousWasProse = false
                continue
            }
            if previousWasProse { out.append("") }
            if let label = standaloneLabel(trimmed), hasContent(after: index, in: lines) {
                out.append("### \(label)")
            } else {
                out.append(boldingLeadInLabel(trimmed))
            }
            previousWasProse = true
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Preamble

    private static let preambleOpeners = [
        "here is", "here's", "here are", "below is", "below are",
        "sure", "certainly", "of course",
    ]

    /// Drops a first line that only announces what follows ("Here is a concise
    /// narrative clinical summary of the session:"), when real content follows it.
    private static func dropPreamble(_ lines: inout [String]) {
        guard let first = lines.firstIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return }
        let trimmed = lines[first].trimmingCharacters(in: .whitespaces)
        let lowered = trimmed.lowercased()
        guard trimmed.count <= 160,
              trimmed.hasSuffix(":"),
              preambleOpeners.contains(where: { lowered.hasPrefix($0) }),
              hasContent(after: first, in: lines) else { return }
        lines.removeSubrange(0...first)
    }

    // MARK: - Labels

    /// Words that mark a clause rather than a label ("The client said:",
    /// "She reported:"), so those lines stay prose.
    private static let clauseWords: Set<String> = [
        "the", "a", "an", "is", "was", "were", "are", "be", "been",
        "said", "says", "asked", "reported", "stated", "noted", "added", "explained",
        "she", "he", "they", "i", "we", "you", "it",
    ]

    /// A line that is only a short label ending in a colon
    /// ("Follow-ups to revisit next session:"), returned without the colon.
    static func standaloneLabel(_ trimmed: String) -> String? {
        guard trimmed.hasSuffix(":"), !trimmed.hasSuffix("::") else { return nil }
        let label = String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces)
        guard isLabel(label, maxWords: 6, maxLength: 60) else { return nil }
        return label
    }

    /// "Mood/affect observations: The client…" → "**Mood/affect observations:** The client…".
    static func boldingLeadInLabel(_ trimmed: String) -> String {
        guard let colon = trimmed.firstIndex(of: ":") else { return trimmed }
        let label = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        let rest = trimmed[trimmed.index(after: colon)...]
        // A label is followed by a space and real text, not "12:30" or a URL.
        guard rest.first == " ",
              !rest.trimmingCharacters(in: .whitespaces).isEmpty,
              isLabel(label, maxWords: 4, maxLength: 40) else { return trimmed }
        return "**\(label):**\(rest)"
    }

    private static func isLabel(_ label: String, maxWords: Int, maxLength: Int) -> Bool {
        guard let first = label.unicodeScalars.first,
              CharacterSet.uppercaseLetters.contains(first),
              label.count <= maxLength,
              !label.contains("*"), !label.contains("`"), !label.contains("["),
              !label.contains("\""), !label.contains("“") else { return false }
        let words = label.split(whereSeparator: { $0 == " " })
        guard !words.isEmpty, words.count <= maxWords else { return false }
        // Sentence punctuation inside means it's prose that happens to end in a colon.
        guard !label.contains(where: { ".!?;".contains($0) }) else { return false }
        return !words.contains { clauseWords.contains($0.lowercased()) }
    }

    // MARK: - Line classes

    /// A line of running text: not blank, and not the start of any other block.
    /// Indented lines are left alone (list continuations, code indented by hand).
    private static func isProse(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, line.first?.isWhitespace != true else { return false }
        if trimmed.hasPrefix("#") || trimmed.hasPrefix(">") || trimmed.hasPrefix("|") { return false }
        if isBullet(trimmed) || isNumbered(trimmed) || isRule(trimmed) { return false }
        return true
    }

    private static func isFence(_ trimmed: String) -> Bool {
        trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
    }

    private static func isBullet(_ trimmed: String) -> Bool {
        ["- ", "* ", "+ ", "• "].contains { trimmed.hasPrefix($0) }
    }

    private static func isNumbered(_ trimmed: String) -> Bool {
        let digits = trimmed.prefix { $0.isNumber }
        guard !digits.isEmpty, digits.count <= 3 else { return false }
        let rest = trimmed.dropFirst(digits.count)
        return rest.hasPrefix(". ") || rest.hasPrefix(") ")
    }

    private static func isRule(_ trimmed: String) -> Bool {
        guard let first = trimmed.first, "-*_".contains(first) else { return false }
        let stripped = trimmed.filter { !$0.isWhitespace }
        return stripped.count >= 3 && stripped.allSatisfy { $0 == first }
    }

    private static func hasContent(after index: Int, in lines: [String]) -> Bool {
        lines[(index + 1)...].contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }
}
