import Foundation

/// One stretch of a transcript, cut on line boundaries, that gets its own digest.
struct TranscriptSection: Equatable {
    /// Time codes (seconds) of the first and last timed line; nil when the
    /// section has no timed line (untimed transcript).
    let start: Int?
    let end: Int?
    let text: String

    /// How the section is pointed at in prompts and digests: `[12:30–22:10]`, or
    /// `[part 2 of 5]` when the transcript has no time codes.
    func anchor(index: Int, count: Int) -> String {
        guard let start, let end else { return "[part \(index + 1) of \(count)]" }
        return "[\(TranscriptTimeline.format(start))–\(TranscriptTimeline.format(end))]"
    }
}

/// Splits a transcript into sections of about ten minutes (by its `[MM:SS]`
/// stamps) so each can be digested on its own. Dense speech is cut sooner, at
/// `maxCharacters`, so a section always fits a small model's window. Pure logic,
/// unit-tested in isolation.
enum TranscriptSections {
    static let targetSeconds = 600
    static let maxCharacters = 12_000

    static func split(
        _ transcript: String,
        targetSeconds: Int = targetSeconds,
        maxCharacters: Int = maxCharacters
    ) -> [TranscriptSection] {
        var sections: [TranscriptSection] = []
        var lines: [String] = []
        var length = 0
        var start: Int?
        var end: Int?

        func flush() {
            guard !lines.isEmpty else { return }
            sections.append(TranscriptSection(start: start, end: end, text: lines.joined(separator: "\n")))
            lines = []; length = 0; start = nil; end = nil
        }

        for raw in transcript.split(separator: "\n", omittingEmptySubsequences: true) {
            // A single line over the cap (a monologue with no breaks) is cut by
            // characters so no section can exceed it.
            var rest = Substring(raw)
            repeat {
                let piece = rest.prefix(maxCharacters)
                rest = rest.dropFirst(piece.count)
                let seconds = TranscriptTimeline.leadingSeconds(of: String(piece))
                let overTime = seconds.map { s in start.map { s - $0 >= targetSeconds } ?? false } ?? false
                if !lines.isEmpty, overTime || length + piece.count + 1 > maxCharacters { flush() }
                if let seconds {
                    start = start ?? seconds
                    end = seconds
                }
                lines.append(String(piece))
                length += piece.count + 1
            } while !rest.isEmpty
        }
        flush()
        return sections
    }
}
