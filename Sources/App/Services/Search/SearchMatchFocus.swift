import Foundation

/// Where a global-search hit matched inside a session, so opening it can
/// scroll to the match and flash it (the way a comment hit flashes its
/// passage). The query is matched the way the search matched it (stems, the
/// start of words, case and diacritics ignored), so what flashes is what the
/// result row marked. Pure.
struct SearchMatchFocus: Equatable {
    /// The query as typed.
    let query: String
    /// The passage the hit showed: a transcript line, or a note paragraph
    /// (`GlobalSearchText.paragraphs`).
    let passage: Int

    /// The match to flash in a transcript (UTF-16, in `text`): the first
    /// matching word of the hit's line, or the first in the whole transcript
    /// when that line no longer holds one (edited since). nil when nothing matches.
    func transcriptRange(in text: String) -> NSRange? {
        if let line = Self.lineRange(passage, in: text) {
            let lineText = String(text[line])
            if let match = firstMatch(in: lineText) {
                let start = line.lowerBound.utf16Offset(in: text)
                let inner = NSRange(match, in: lineText)
                return NSRange(location: start + inner.location, length: inner.length)
            }
        }
        return firstMatch(in: text).map { NSRange($0, in: text) }
    }

    /// The match to flash in a note as the reader shows it (`rendered`, the
    /// Markdown of `note` rendered to text; UTF-16): the first match in the
    /// rendered line whose words are most nearly all in the hit's paragraph of
    /// `note`, the first such line on a tie. Rendering drops markup and splits
    /// paragraphs, so lines are matched by their words rather than by position.
    /// nil when nothing matches.
    func noteRange(in rendered: String, note: String) -> NSRange? {
        let paragraphs = GlobalSearchText.paragraphs(note)
        let passageWords = passage < paragraphs.count ? Set(TextSearch.queryTerms(paragraphs[passage])) : []
        var best: (range: NSRange, share: Double)?
        var lineStart = rendered.startIndex
        while lineStart <= rendered.endIndex {
            let lineEnd = rendered[lineStart...].firstIndex(of: "\n") ?? rendered.endIndex
            let line = String(rendered[lineStart..<lineEnd])
            if let match = firstMatch(in: line) {
                let words = Set(TextSearch.queryTerms(line))
                let share = words.isEmpty ? 0 : Double(words.intersection(passageWords).count) / Double(words.count)
                if best == nil || share > best!.share {
                    let inner = NSRange(match, in: line)
                    best = (NSRange(location: lineStart.utf16Offset(in: rendered) + inner.location, length: inner.length), share)
                }
            }
            guard lineEnd < rendered.endIndex else { break }
            lineStart = rendered.index(after: lineEnd)
        }
        return best?.range
    }

    /// The first word the search matched in `text`; where none does (a word
    /// the index doesn't look up), the first place the typed text appears.
    private func firstMatch(in text: String) -> Range<String.Index>? {
        let terms = GlobalSearchQuery(query).textTerms
        return GlobalSearchText.wordRanges(in: text, terms: terms).first
            ?? SearchHighlighter.ranges(of: query, in: text).first
    }

    /// Line `index` of `text` (split at "\n", as the index splits transcripts),
    /// without its newline; nil past the last line.
    static func lineRange(_ index: Int, in text: String) -> Range<String.Index>? {
        guard index >= 0 else { return nil }
        var start = text.startIndex
        var line = 0
        while line < index {
            guard let newline = text[start...].firstIndex(of: "\n") else { return nil }
            start = text.index(after: newline)
            line += 1
        }
        let end = text[start...].firstIndex(of: "\n") ?? text.endIndex
        return start..<end
    }

    /// Whether a focus request (bumped `token` on every open) still has to be
    /// shown: once per token, so re-rendering doesn't flash again.
    static func isNewRequest(token: Int, lastHandledToken: Int?) -> Bool {
        token != lastHandledToken
    }
}
