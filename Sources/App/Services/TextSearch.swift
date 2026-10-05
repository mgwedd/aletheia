import Foundation

/// Small, dependency-free text matching used by search and (later) by
/// relevance ranking. Matching is case- and diacritic-insensitive.
///
/// Everything here searches the *original* string with
/// `String.CompareOptions` rather than pre-folding it, because folding can
/// change a string's length (e.g. "ß" → "ss", decomposed diacritics), which
/// would make any index computed on the folded text point at the wrong spot
/// in the original — and snippet extraction needs valid original indices.
enum TextSearch {
    static let compareOptions: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

    /// Lowercased alphanumeric terms from a query string. Punctuation and
    /// whitespace split terms; empty terms are dropped.
    static func queryTerms(_ query: String) -> [String] {
        query
            .split { !$0.isLetter && !$0.isNumber }
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
    }

    /// True when every term in the query appears somewhere in `text` (AND
    /// semantics). An empty query never matches.
    static func matches(_ text: String, query: String) -> Bool {
        let terms = queryTerms(query)
        guard !terms.isEmpty else { return false }
        return terms.allSatisfy { text.range(of: $0, options: compareOptions) != nil }
    }

    /// A one-line excerpt of `text` centered on the earliest query-term
    /// match, with ellipses where it's been trimmed. Returns nil if nothing
    /// matches.
    static func snippet(from text: String, query: String, radius: Int = 64) -> String? {
        let terms = queryTerms(query)
        guard !terms.isEmpty else { return nil }

        var earliest: Range<String.Index>?
        for term in terms {
            if let range = text.range(of: term, options: compareOptions) {
                if earliest == nil || range.lowerBound < earliest!.lowerBound {
                    earliest = range
                }
            }
        }
        guard let match = earliest else { return nil }

        let lower = text.index(match.lowerBound, offsetBy: -radius, limitedBy: text.startIndex) ?? text.startIndex
        let upper = text.index(match.upperBound, offsetBy: radius, limitedBy: text.endIndex) ?? text.endIndex

        var excerpt = text[lower..<upper]
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if lower > text.startIndex { excerpt = "…" + excerpt }
        if upper < text.endIndex { excerpt += "…" }
        return excerpt
    }
}
