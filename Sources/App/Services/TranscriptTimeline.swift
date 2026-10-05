import Foundation

/// Reads the time codes the transcriber stamps on every line
/// (`[MM:SS] Speaker: …`, or `[H:MM:SS]` for long sessions) so an annotation
/// can be anchored to the moment in the recording it's about.
///
/// Pure string logic, no UI — the seconds it returns are what a comment stores
/// and what the transcript view formats back for display. Unit-tested in
/// isolation.
enum TranscriptTimeline {
    /// The time code at the start of a single transcript line, in seconds, or
    /// nil if the line isn't timestamped (e.g. a hand-typed line).
    static func leadingSeconds(of line: String) -> Int? {
        let trimmed = line.drop(while: { $0 == " " || $0 == "\t" })
        guard trimmed.first == "[", let close = trimmed.firstIndex(of: "]") else { return nil }
        let inside = trimmed[trimmed.index(after: trimmed.startIndex)..<close]
        let parts = inside.split(separator: ":", omittingEmptySubsequences: false).map { Int($0) }
        guard parts.allSatisfy({ $0 != nil }) else { return nil }
        let values = parts.compactMap { $0 }
        switch values.count {
        case 2: return values[0] * 60 + values[1]                        // MM:SS
        case 3: return values[0] * 3600 + values[1] * 60 + values[2]     // H:MM:SS
        default: return nil
        }
    }

    /// The time code of the transcript line that a quoted passage falls in — the
    /// timestamp of the last line at or before where the quote first appears.
    /// Returns nil if the quote isn't found verbatim or no line before it carries
    /// a time code.
    static func seconds(forQuote quote: String, in transcript: String) -> Int? {
        let needle = quote.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, let match = transcript.range(of: needle) else { return nil }
        let matchStart = match.lowerBound

        var chosen: Int?
        var lineStart = transcript.startIndex
        while lineStart <= matchStart {
            let lineEnd = transcript[lineStart...].firstIndex(of: "\n") ?? transcript.endIndex
            if let seconds = leadingSeconds(of: String(transcript[lineStart..<lineEnd])) {
                chosen = seconds
            }
            if lineEnd == transcript.endIndex { break }
            lineStart = transcript.index(after: lineEnd)
        }
        return chosen
    }

    /// Formats seconds as `M:SS` (or `H:MM:SS` past an hour) for display.
    static func format(_ seconds: Int) -> String {
        let clamped = max(0, seconds)
        let hours = clamped / 3600
        let minutes = (clamped % 3600) / 60
        let secs = clamped % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%d:%02d", minutes, secs)
    }
}
