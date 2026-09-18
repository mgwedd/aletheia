import Foundation

/// Maps the therapist's margin comments onto positions in the transcript so the
/// text view can highlight the passage each comment is about — the in-place,
/// Google-Docs-style anchoring, driven off the `quotedText` a comment already
/// stores (so nothing new is persisted and edits to the transcript can't leave
/// a dangling character offset behind).
///
/// Pure `NSString`-range logic, no UI, so it's unit-tested in isolation and the
/// AppKit text view stays a thin shell over it.
enum TranscriptHighlighter {
    struct Span: Equatable {
        let range: NSRange
        let commentID: String
    }

    /// One highlight span per comment whose quoted passage is found verbatim in
    /// the transcript (first occurrence). Comments with an empty quote, or a
    /// quote that no longer appears (e.g. the transcript was edited), are simply
    /// left without a highlight rather than mis-anchored.
    ///
    /// Ranges are `NSString` ranges (UTF-16), matching what `NSTextView` uses.
    static func spans(in transcript: String, comments: [(id: String, quote: String)]) -> [Span] {
        let text = transcript as NSString
        var spans: [Span] = []
        for comment in comments {
            let quote = comment.quote.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !quote.isEmpty else { continue }
            let range = text.range(of: quote)
            guard range.location != NSNotFound, range.length > 0 else { continue }
            spans.append(Span(range: range, commentID: comment.id))
        }
        return spans
    }
}
