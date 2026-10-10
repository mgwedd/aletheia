import Foundation

/// Finds where a search query matches inside a result's snippet, so the row
/// can mark it. Pure and UI-free; uses the same case- and diacritic-insensitive
/// matching as `TextSearch`, so what's marked is what matched.
enum SearchHighlighter {
    /// A run of text and whether it is a match.
    struct Segment: Equatable {
        let text: String
        let isMatch: Bool
    }

    /// Every occurrence of every query term in `text`, in order, with
    /// overlapping or touching ranges merged.
    static func ranges(of query: String, in text: String) -> [Range<String.Index>] {
        let terms = TextSearch.queryTerms(query)
        guard !terms.isEmpty, !text.isEmpty else { return [] }

        var found: [Range<String.Index>] = []
        for term in terms {
            var from = text.startIndex
            while from < text.endIndex,
                  let range = text.range(of: term, options: TextSearch.compareOptions, range: from..<text.endIndex) {
                found.append(range)
                from = range.upperBound > range.lowerBound ? range.upperBound : text.index(after: range.lowerBound)
            }
        }
        found.sort { $0.lowerBound < $1.lowerBound }

        var merged: [Range<String.Index>] = []
        for range in found {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                if range.upperBound > last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<range.upperBound
                }
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// `text` cut into alternating plain and matching runs; joining the
    /// segments gives back `text` exactly.
    static func segments(in text: String, query: String) -> [Segment] {
        var segments: [Segment] = []
        var cursor = text.startIndex
        for range in ranges(of: query, in: text) {
            if range.lowerBound > cursor {
                segments.append(Segment(text: String(text[cursor..<range.lowerBound]), isMatch: false))
            }
            segments.append(Segment(text: String(text[range]), isMatch: true))
            cursor = range.upperBound
        }
        if cursor < text.endIndex {
            segments.append(Segment(text: String(text[cursor...]), isMatch: false))
        }
        return segments
    }
}
