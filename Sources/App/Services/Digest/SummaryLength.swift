import Foundation

/// Holds a Summary note to its depth's word range. Small models drift past
/// the target they are given, so a Summary longer than `AnswerDepth.summaryWordCeiling`
/// keeps its whole sentences up to the ceiling, plus every later sentence with a
/// risk phrase: a risk statement or denial is never dropped to make the length.
/// No sentence is cut part-way.
enum SummaryLength {
    /// `text`, or its leading whole sentences within `ceiling` words followed by
    /// any later sentence holding one of `phrases`.
    nonisolated static func trimmed(_ text: String, ceiling: Int, phrases: [String]) -> String {
        trimmed(text, ceiling: ceiling, matcher: RiskPhraseMatcher(phrases))
    }

    private nonisolated static func trimmed(_ text: String, ceiling: Int, matcher: RiskPhraseMatcher) -> String {
        guard words(in: text[...]) > ceiling else { return text }
        let ranges = sentenceRanges(text)
        var count = 0
        var cut = text.startIndex
        var rest = ranges.endIndex
        for (index, range) in ranges.enumerated() {
            let added = words(in: text[range])
            // The first sentence always stays, so the note is never empty.
            if index > 0, count + added > ceiling {
                rest = index
                break
            }
            count += added
            cut = range.upperBound
        }
        let risk = ranges[rest...].map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { matcher.firstMatch(in: $0) != nil }
        let kept = String(text[..<cut]).trimmingCharacters(in: .whitespacesAndNewlines)
        return ([kept] + risk).joined(separator: " ")
    }

    /// `written` (the growing note) with every snapshot trimmed the same way,
    /// so the pane and the saved note never run past the ceiling.
    nonisolated static func held(
        _ written: AsyncThrowingStream<String, Error>, ceiling: Int, phrases: [String]
    ) -> AsyncThrowingStream<String, Error> {
        let matcher = RiskPhraseMatcher(phrases)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await text in written { continuation.yield(trimmed(text, ceiling: ceiling, matcher: matcher)) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    nonisolated static func words(in text: Substring) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    /// The sentences of `text`, in order: each ends after `.`, `!` or `?` (and
    /// any closing quote, bracket or emphasis mark) before a space, or at a line
    /// break. Blank stretches are left out.
    private nonisolated static func sentenceRanges(_ text: String) -> [Range<String.Index>] {
        let enders: Set<Character> = [".", "!", "?"]
        let closers: Set<Character> = ["\"", "'", "\u{201D}", "\u{2019}", ")", "]", "*", "_"]
        var out: [Range<String.Index>] = []
        var start = text.startIndex
        var index = start
        func close(at end: String.Index) {
            if words(in: text[start..<end]) > 0 { out.append(start..<end) }
            start = end
        }
        while index < text.endIndex {
            let character = text[index]
            if character == "\n" {
                let end = text.index(after: index)
                close(at: end)
                index = end
            } else if enders.contains(character) {
                var end = text.index(after: index)
                while end < text.endIndex, enders.contains(text[end]) || closers.contains(text[end]) {
                    end = text.index(after: end)
                }
                if end == text.endIndex || text[end].isWhitespace { close(at: end) }
                index = end
            } else {
                index = text.index(after: index)
            }
        }
        close(at: text.endIndex)
        return out
    }
}
