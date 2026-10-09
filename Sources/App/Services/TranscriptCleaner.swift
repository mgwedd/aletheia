import Foundation

/// One transcribed segment, tagged with the track it came from. `endTime` is
/// the end of the spoken span (for a coalesced line, the end of its last
/// segment); `TranscriptFormatter` uses it to detect people talking over each
/// other.
struct TranscribedLine: Equatable {
    let source: String
    let startTime: TimeInterval
    let endTime: TimeInterval
    let text: String
}

/// Strips Whisper's non-speech output ("[BLANK_AUDIO]", "(static)",
/// "*sigh*", ...) from a transcript. Pure and independent of the Whisper
/// binding so it can be unit tested directly.
enum TranscriptCleaner {
    /// Consecutive kept lines from one source whose start times are this
    /// close together are merged into a single line, unless the later line
    /// opens with a "- " turn marker (see `startsNewTurn`) or the other source
    /// started a line in between (see `coalesce`).
    static let coalesceWindow: TimeInterval = 2.0

    /// Most segments a split tag is allowed to span before giving up.
    private static let maxTagSpan = 3

    private static let skippable = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)

    /// Cleans the lines of all sources: rejoins tags split across segments and
    /// drops annotation-only and punctuation-only segments (both per source),
    /// then coalesces near-adjacent lines against the merged, cross-source
    /// timeline (see `coalesce`). Pass the lines of every track together.
    /// Output is sorted by start time; ties go to the source that appeared
    /// first in `lines`, then to input order, so the result is deterministic.
    static func clean(_ lines: [TranscribedLine]) -> [TranscribedLine] {
        var order: [String] = []
        var bySource: [String: [TranscribedLine]] = [:]
        for line in lines {
            if bySource[line.source] == nil { order.append(line.source) }
            bySource[line.source, default: []].append(line)
        }
        var rank: [String: Int] = [:]
        for (index, source) in order.enumerated() { rank[source] = index }

        let kept = order.flatMap { dropNonSpeech(rejoin(bySource[$0] ?? [])) }
        return coalesce(timeOrdered(kept, sourceRank: rank))
    }

    /// `lines` sorted by start time. Equal start times are ordered by
    /// `sourceRank` (lower first; sources missing from it rank 0), then by
    /// input position. An explicit key rather than relying on the sort being
    /// stable, so the order is the same on every run.
    static func timeOrdered(_ lines: [TranscribedLine], sourceRank: [String: Int] = [:]) -> [TranscribedLine] {
        let keyed = lines.enumerated().map { (index: $0.offset, line: $0.element) }
        let sorted = keyed.sorted { a, b in
            if a.line.startTime != b.line.startTime { return a.line.startTime < b.line.startTime }
            let rankA = sourceRank[a.line.source] ?? 0
            let rankB = sourceRank[b.line.source] ?? 0
            if rankA != rankB { return rankA < rankB }
            return a.index < b.index
        }
        return sorted.map { $0.line }
    }

    /// True if the text is empty or consists only of annotations such as
    /// "[BLANK_AUDIO]", "(static)" or "*sigh*" plus whitespace/punctuation.
    static func isNonSpeech(_ text: String) -> Bool {
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let closer: Character
            switch chars[i] {
            case "[": closer = "]"
            case "(": closer = ")"
            case "*": closer = "*"
            default:
                if isSkippable(chars[i]) {
                    i += 1
                    continue
                }
                return false
            }
            guard let end = chars[(i + 1)...].firstIndex(of: closer) else {
                // Dangling opener with nothing real after it, e.g. a lone "[".
                return chars[(i + 1)...].allSatisfy(isSkippable)
            }
            i = end + 1
        }
        return true
    }

    // MARK: - Steps

    /// Joins a segment with an unclosed '[' or '(' to the following
    /// segment(s) that close it ("[" + "static ]" -> "[ static ]").
    private static func rejoin(_ lines: [TranscribedLine]) -> [TranscribedLine] {
        var result: [TranscribedLine] = []
        var i = 0
        while i < lines.count {
            var merged = lines[i]
            var next = i + 1
            if hasUnclosedTag(merged.text) {
                var joined = merged.text
                var j = i + 1
                while j < lines.count, j <= i + maxTagSpan {
                    joined += " " + lines[j].text
                    if !hasUnclosedTag(joined) {
                        merged = TranscribedLine(
                            source: merged.source,
                            startTime: merged.startTime,
                            endTime: lines[j].endTime,
                            text: joined
                        )
                        next = j + 1
                        break
                    }
                    j += 1
                }
            }
            result.append(merged)
            i = next
        }
        return result
    }

    private static func dropNonSpeech(_ lines: [TranscribedLine]) -> [TranscribedLine] {
        lines.compactMap { line in
            let text = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if isNonSpeech(text) { return nil }
            return TranscribedLine(source: line.source, startTime: line.startTime, endTime: line.endTime, text: text)
        }
    }

    /// Merges a source's near-adjacent lines into one turn, walking the
    /// time-ordered lines of ALL sources so an interjection splits the turn.
    ///
    ///   t:            10    11    11.5    13
    ///   Therapist     A1          A2      A3
    ///   Call audio          B
    ///
    ///   per source:   [A1 A2 A3]  [B]       B is shown after the whole turn
    ///   timeline:     [A1] [B] [A2 A3]      B splits the turn
    ///
    /// A line merges into its source's previous line only if ALL hold:
    ///   1. it starts within `coalesceWindow` of that source's previous
    ///      segment (chained: a run of close segments is one turn);
    ///   2. it does not open with a "- " turn marker (`startsNewTurn`);
    ///   3. no other-source line has started since, i.e. that previous line is
    ///      still the last one on the timeline so far.
    /// A merged line keeps its first start time and takes the latest end time.
    /// Speech that merely overlaps (B starts before A1 ends) is not hidden
    /// here; `TranscriptFormatter` marks it.
    ///
    /// `timeline` must already be sorted by start time.
    private static func coalesce(_ timeline: [TranscribedLine]) -> [TranscribedLine] {
        var result: [TranscribedLine] = []
        // source -> index in `result` of its latest line
        var lastIndex: [String: Int] = [:]
        // source -> start of its previous raw segment (not of the merged line)
        var previousStart: [String: TimeInterval] = [:]
        for line in timeline {
            if let index = lastIndex[line.source],
               index == result.count - 1,
               let previous = previousStart[line.source],
               line.startTime - previous <= coalesceWindow,
               !startsNewTurn(line.text) {
                let last = result[index]
                result[index] = TranscribedLine(
                    source: last.source,
                    startTime: last.startTime,
                    endTime: max(last.endTime, line.endTime),
                    text: last.text + " " + line.text
                )
            } else {
                result.append(line)
                lastIndex[line.source] = result.count - 1
            }
            previousStart[line.source] = line.startTime
        }
        return result
    }

    // MARK: - Helpers

    /// True if the text opens with Whisper's "- " turn-change marker: a hyphen
    /// followed by whitespace. "-5" and "-ish" are not markers. Trims first so
    /// the check does not depend on earlier steps having already done so.
    private static func startsNewTurn(_ text: String) -> Bool {
        let trimmed = text.drop(while: { $0.isWhitespace })
        guard trimmed.first == "-" else { return false }
        return trimmed.dropFirst().first?.isWhitespace ?? false
    }

    private static func hasUnclosedTag(_ text: String) -> Bool {
        occurrences(of: "[", in: text) > occurrences(of: "]", in: text)
            || occurrences(of: "(", in: text) > occurrences(of: ")", in: text)
    }

    private static func occurrences(of character: Character, in text: String) -> Int {
        text.reduce(0) { $1 == character ? $0 + 1 : $0 }
    }

    private static func isSkippable(_ character: Character) -> Bool {
        character.unicodeScalars.allSatisfy { skippable.contains($0) }
    }
}
