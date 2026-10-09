import Foundation

/// One transcribed segment, tagged with the track it came from.
struct TranscribedLine: Equatable {
    let source: String
    let startTime: TimeInterval
    let text: String
}

/// Strips Whisper's non-speech output ("[BLANK_AUDIO]", "(static)",
/// "*sigh*", ...) from a transcript. Pure and independent of the Whisper
/// binding so it can be unit tested directly.
enum TranscriptCleaner {
    /// Consecutive kept lines from one source whose start times are this
    /// close together are merged into a single line.
    static let coalesceWindow: TimeInterval = 2.0

    /// Most segments a split tag is allowed to span before giving up.
    private static let maxTagSpan = 3

    private static let skippable = CharacterSet.whitespacesAndNewlines
        .union(.punctuationCharacters)
        .union(.symbols)

    /// Cleans each source track independently: rejoins tags split across
    /// segments, drops annotation-only and punctuation-only segments, then
    /// coalesces near-adjacent lines. Output is grouped by source in order of
    /// first appearance; callers sort by time afterwards.
    static func clean(_ lines: [TranscribedLine]) -> [TranscribedLine] {
        var order: [String] = []
        var bySource: [String: [TranscribedLine]] = [:]
        for line in lines {
            if bySource[line.source] == nil { order.append(line.source) }
            bySource[line.source, default: []].append(line)
        }
        return order.flatMap { coalesce(dropNonSpeech(rejoin(bySource[$0] ?? []))) }
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
                        merged = TranscribedLine(source: merged.source, startTime: merged.startTime, text: joined)
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
            return TranscribedLine(source: line.source, startTime: line.startTime, text: text)
        }
    }

    private static func coalesce(_ lines: [TranscribedLine]) -> [TranscribedLine] {
        var result: [TranscribedLine] = []
        var previousStart: TimeInterval = 0
        for line in lines {
            if let last = result.last, line.startTime - previousStart <= coalesceWindow {
                result[result.count - 1] = TranscribedLine(
                    source: last.source,
                    startTime: last.startTime,
                    text: last.text + " " + line.text
                )
            } else {
                result.append(line)
            }
            previousStart = line.startTime
        }
        return result
    }

    // MARK: - Helpers

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
