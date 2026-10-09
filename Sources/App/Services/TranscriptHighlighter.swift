import Foundation

/// Maps the therapist's margin comments onto positions in the transcript so the
/// text view can highlight the passage each comment is about — the in-place,
/// Google-Docs-style anchoring. A comment stores the `quotedText` it was made
/// on plus (since position anchoring) the UTF-16 offset where that quote
/// started. The offset is only a *hint*: the quote is always re-verified
/// against the transcript, so an edit that shifts text can't leave a dangling
/// character offset behind.
///
/// Pure `NSString`-range logic, no UI, so it's unit-tested in isolation and the
/// AppKit text view stays a thin shell over it.
enum TranscriptHighlighter {
    /// What the highlighter needs to know about one comment: its id, the quoted
    /// passage, and the offset the quote started at when it was made (nil for
    /// comments written before positions were stored).
    typealias Anchor = (id: String, quote: String, start: Int?)

    struct Span: Equatable {
        let range: NSRange
        let commentID: String
    }

    /// Where a comment's quote sits in the transcript, as an `NSString` (UTF-16)
    /// range, or nil if it can't be placed confidently.
    ///
    ///  1. The hinted position still holds the quote verbatim → use it.
    ///  2. Otherwise (the transcript was edited and text shifted) → the
    ///     occurrence of the quote nearest the hint.
    ///  3. No hint (a legacy comment) → the quote's only occurrence, and only if
    ///     it is unique. A quote that repeats (e.g. a speaker label) with no
    ///     position to disambiguate it is left unanchored rather than
    ///     mis-anchored to the first match.
    static func resolve(quote: String, hintStart: Int?, in transcript: String) -> NSRange? {
        let needle = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        let text = transcript as NSString
        let length = (needle as NSString).length

        if let hint = hintStart, hint >= 0, hint <= text.length - length {
            let candidate = NSRange(location: hint, length: length)
            if text.substring(with: candidate) == needle { return candidate }
        }

        let matches = allOccurrences(of: needle, in: text)
        guard !matches.isEmpty else { return nil }

        if let hint = hintStart {
            // Strict `<` keeps the earlier of two equally-near candidates.
            var nearest = matches[0]
            for match in matches where abs(match.location - hint) < abs(nearest.location - hint) {
                nearest = match
            }
            return nearest
        }
        return matches.count == 1 ? matches[0] : nil
    }

    /// One highlight span per comment whose quoted passage can be placed in the
    /// transcript (see `resolve`). Comments with an empty quote, or a quote that
    /// no longer appears (e.g. the transcript was edited), or an ambiguous
    /// legacy quote, are simply left without a highlight rather than
    /// mis-anchored.
    ///
    /// Ranges are `NSString` ranges (UTF-16), matching what `NSTextView` uses,
    /// and are always within the transcript's bounds.
    static func spans(in transcript: String, comments: [Anchor]) -> [Span] {
        var spans: [Span] = []
        for comment in comments {
            guard let range = resolve(quote: comment.quote, hintStart: comment.start, in: transcript) else { continue }
            spans.append(Span(range: range, commentID: comment.id))
        }
        return spans
    }

    /// Ids of the comments that carry a quote but couldn't be placed in the
    /// transcript, so the rail can say so instead of silently not scrolling.
    /// Comments with no quote at all (general notes) aren't "unplaced" — they
    /// never had a passage.
    static func unplacedIDs(in transcript: String, comments: [Anchor]) -> Set<String> {
        var ids = Set<String>()
        for comment in comments {
            let quote = comment.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty else { continue }
            if resolve(quote: quote, hintStart: comment.start, in: transcript) == nil {
                ids.insert(comment.id)
            }
        }
        return ids
    }

    /// The comment a click at `index` lands on: among the spans containing that
    /// character, the shortest (most specific) one, earliest on a tie. Resolving
    /// by the placed ranges — never by re-searching the quote text — is what
    /// keeps two comments on the same repeated word distinct.
    static func commentID(at index: Int, in spans: [Span]) -> String? {
        var best: Span?
        for span in spans where NSLocationInRange(index, span.range) {
            if let current = best, current.range.length <= span.range.length { continue }
            best = span
        }
        return best?.commentID
    }

    /// Whether the view should scroll-and-flash for the current focus: a comment
    /// is focused and its token differs from the one last acted on. Focus is an
    /// event, not a state — the owner bumps the token on every click, so
    /// re-clicking the *same* comment after scrolling away still counts, while
    /// unrelated re-renders (same token) don't re-trigger the flash.
    static func isNewFocusRequest(commentID: String?, token: Int, lastHandledToken: Int?) -> Bool {
        commentID != nil && token != lastHandledToken
    }

    /// `range` with leading/trailing whitespace and newlines dropped, or nil if
    /// that leaves nothing. A selection can include stray whitespace the saved
    /// quote is trimmed of, and the stored start offset must match the *trimmed*
    /// quote.
    static func trimmed(_ range: NSRange, in transcript: String) -> NSRange? {
        let text = transcript as NSString
        guard range.location >= 0, range.length > 0, NSMaxRange(range) <= text.length else { return nil }
        var start = range.location
        var end = NSMaxRange(range)
        while start < end, isWhitespace(text.character(at: start)) { start += 1 }
        while end > start, isWhitespace(text.character(at: end - 1)) { end -= 1 }
        guard end > start else { return nil }
        return NSRange(location: start, length: end - start)
    }

    private static func isWhitespace(_ unit: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(unit) else { return false }
        return CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    /// Every non-overlapping, verbatim occurrence of `needle`, in order.
    private static func allOccurrences(of needle: String, in text: NSString) -> [NSRange] {
        var found: [NSRange] = []
        var searchFrom = 0
        while searchFrom < text.length {
            let remaining = NSRange(location: searchFrom, length: text.length - searchFrom)
            let match = text.range(of: needle, options: [.literal], range: remaining)
            guard match.location != NSNotFound, match.length > 0 else { break }
            found.append(match)
            searchFrom = NSMaxRange(match)
        }
        return found
    }
}
