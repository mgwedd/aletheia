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

    /// The anchor for a run of consecutive sections merged into one, from where
    /// the `first` starts to where the `last` ends: `[00:00–09:00]` and
    /// `[10:00–19:00]` give `[00:00–19:00]`, `[part 1 of 5]` and `[part 2 of 5]`
    /// give `[part 1–2 of 5]`. Merging merged anchors stays one flat range
    /// rather than listing every piece. Anchors of a different shape give
    /// `first … last` (endpoints only).
    static func mergedAnchor(first: String, last: String) -> String {
        if let a = partRange(first), let b = partRange(last), a.count == b.count {
            return "[part \(a.from)–\(b.to) of \(a.count)]"
        }
        let firstEnd = unbracketed(first)
        let lastEnd = unbracketed(last)
        if let start = firstEnd.components(separatedBy: "–").first,
           let end = lastEnd.components(separatedBy: "–").last,
           firstEnd.contains("–"), lastEnd.contains("–"),
           !firstEnd.hasPrefix("part "), !lastEnd.hasPrefix("part ") {
            return "[\(start)–\(end)]"
        }
        let head = first.components(separatedBy: " … ").first ?? first
        let tail = last.components(separatedBy: " … ").last ?? last
        return "\(head) … \(tail)"
    }

    private static func unbracketed(_ anchor: String) -> String {
        anchor.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    /// `[part 2 of 5]` or `[part 1–2 of 5]`: the first and last part and the count.
    private static func partRange(_ anchor: String) -> (from: String, to: String, count: String)? {
        let inner = unbracketed(anchor)
        guard inner.hasPrefix("part ") else { return nil }
        let pieces = inner.dropFirst("part ".count).components(separatedBy: " of ")
        guard pieces.count == 2, let from = pieces[0].components(separatedBy: "–").first,
              let to = pieces[0].components(separatedBy: "–").last else { return nil }
        return (from, to, pieces[1])
    }
}

/// Splits a transcript into sections of about ten minutes (by its `[MM:SS]`
/// stamps) so each can be digested on its own. Dense speech is cut sooner, at
/// `maxCharacters` (a `ContextBudget.weightedLength`, so a Japanese section is cut
/// at about a third of the characters), so a section always fits a small model's window. Pure logic,
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
                let piece = ContextBudget.prefix(rest, weightedLength: maxCharacters)
                let size = ContextBudget.weightedLength(of: piece)
                rest = rest.dropFirst(piece.count)
                let seconds = TranscriptTimeline.leadingSeconds(of: String(piece))
                let overTime = seconds.map { s in start.map { s - $0 >= targetSeconds } ?? false } ?? false
                if !lines.isEmpty, overTime || length + size + 1 > maxCharacters { flush() }
                if let seconds {
                    start = start ?? seconds
                    end = seconds
                }
                lines.append(String(piece))
                length += size + 1
            } while !rest.isEmpty
        }
        flush()
        return sections
    }
}
