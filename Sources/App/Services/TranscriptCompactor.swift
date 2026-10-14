import Foundation

/// Shrinks a stored transcript for the model, and only for the model: the
/// stored text, the transcript view, search and `TranscriptTimeline` all keep
/// the full `[MM:SS] You: ...` lines. Fewer tokens means faster prompt reading
/// and more of a long session fitting the Mac's budget.
///
/// Rules (the legend in `Prompts.transcriptLegend` explains the result):
///   1. Speakers are `Y:` (You) and `C:` (Call audio); `~` after the letter
///      (`C~:`) is "(overlapping)".
///   2. Consecutive lines from one speaker become one turn with one stamp.
///   3. A turn running 60 s or more gets a further `[stamp] Y:` line each 60 s,
///      so a time still anchors every minute. Stamps keep their original text
///      (`[75:12]` or `[1:15:12]`).
///   4. The same short sentence 3+ times in a row keeps one copy plus
///      `(repeated ×N)`.
///   5. Only the standalone words um, uh, erm and hmm are removed. Nothing else.
///
/// Pure, deterministic and idempotent: its own output parses back to itself.
/// Lines it doesn't recognise (hand-typed, other labels, "…" gaps) pass through
/// unchanged and end the turn before them.
enum TranscriptCompactor {
    /// A long turn gets a new stamp when this many seconds have passed since the last.
    static let anchorInterval = 60
    /// Most words in a sentence that counts as a repeatable phrase.
    static let maxLoopWords = 8
    static let minLoopRepeats = 3

    static func compact(_ transcript: String) -> String {
        var out: [String] = []
        var turn: Turn?

        func flush() {
            if let t = turn { out.append(contentsOf: render(t)) }
            turn = nil
        }
        for raw in transcript.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let line = parse(String(raw)) else {
                flush()
                out.append(String(raw))
                continue
            }
            // A line that was only filler vanishes without ending the turn.
            guard !line.segment.text.isEmpty else { continue }
            if turn?.speaker == line.speaker {
                turn?.segments.append(line.segment)
            } else {
                flush()
                turn = Turn(speaker: line.speaker, segments: [line.segment])
            }
        }
        flush()
        return out.joined(separator: "\n")
    }

    // MARK: - Parsing

    private struct Segment {
        let stamp: String
        let seconds: Int
        var text: String
    }

    private struct Turn {
        let speaker: String   // "Y", "C", "Y~", "C~"
        var segments: [Segment]
    }

    /// Groups: stamp, speaker (long or short form), overlap marker, text.
    private static let linePattern = try! NSRegularExpression(
        pattern: #"^\[([0-9]+(?::[0-9]{2}){1,2})\] (You|Call audio|Y|C)( \(overlapping\)|~)?: ?(.*)$"#)

    private static func parse(_ line: String) -> (speaker: String, segment: Segment)? {
        let ns = line as NSString
        guard let m = linePattern.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
              let seconds = TranscriptTimeline.leadingSeconds(of: line) else { return nil }
        let who = ns.substring(with: m.range(at: 2))
        let speaker = (who == "You" || who == "Y" ? "Y" : "C") + (m.range(at: 3).location == NSNotFound ? "" : "~")
        return (speaker, Segment(stamp: ns.substring(with: m.range(at: 1)), seconds: seconds, text: removeFiller(ns.substring(with: m.range(at: 4)))))
    }

    // MARK: - Rendering

    private static func render(_ turn: Turn) -> [String] {
        var segments = turn.segments
        collapseLoops(&segments)
        segments.removeAll { $0.text.isEmpty }

        var lines: [String] = []
        var lastStamp = Int.min
        for segment in segments {
            if lines.isEmpty || segment.seconds - lastStamp >= anchorInterval {
                lines.append("[\(segment.stamp)] \(turn.speaker): \(segment.text)")
                lastStamp = segment.seconds
            } else {
                lines[lines.count - 1] += " " + segment.text
            }
        }
        return lines
    }

    // MARK: - Filler

    private static let fillerPattern = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}'’-])(?:um|uh|erm|hmm)(?![\p{L}\p{N}'’-])[,;—–]?"#,
        options: .caseInsensitive)

    /// Drops standalone um/uh/erm/hmm (with a comma or dash right after) and
    /// tidies the punctuation it leaves. Text without filler is returned as is.
    static func removeFiller(_ text: String) -> String {
        let range = NSRange(location: 0, length: (text as NSString).length)
        guard fillerPattern.firstMatch(in: text, range: range) != nil else { return text }
        var s = fillerPattern.stringByReplacingMatches(in: text, range: range, withTemplate: "")
        for (pattern, template) in [
            (#"\s+([,;.!?])"#, "$1"),       // "was ." -> "was."
            (#"([,;])\s*([,;.!?])"#, "$2"), // ", ." -> "."
            (#"([.!?])\s*\.(?!\.)"#, "$1"), // "Right. ." -> "Right."
            (#"\s{2,}"#, " "),
        ] {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"^[\s,;.!?]+"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Repeat loops

    private static let unitPattern = try! NSRegularExpression(pattern: #"[^.!?…]*[.!?…]+\s*|[^.!?…]+"#)

    /// Sentences repeated back to back, across the segments of one turn.
    private static func collapseLoops(_ segments: inout [Segment]) {
        var units: [(segment: Int, text: String, key: String)] = []
        for (i, segment) in segments.enumerated() {
            let ns = segment.text as NSString
            for m in unitPattern.matches(in: segment.text, range: NSRange(location: 0, length: ns.length)) {
                let text = ns.substring(with: m.range)
                units.append((i, text, key(of: text)))
            }
        }
        var kept: [(segment: Int, text: String)] = []
        var i = 0
        while i < units.count {
            var j = i + 1
            while j < units.count, !units[i].key.isEmpty, units[j].key == units[i].key { j += 1 }
            let count = j - i
            if count >= minLoopRepeats, units[i].key.split(separator: " ").count <= maxLoopWords {
                let first = units[i].text.trimmingCharacters(in: .whitespaces)
                kept.append((units[i].segment, "\(first) (repeated ×\(count)) "))
            } else {
                for k in i..<j { kept.append((units[k].segment, units[k].text)) }
            }
            i = j
        }
        for index in segments.indices {
            segments[index].text = kept.filter { $0.segment == index }.map(\.text).joined()
                .trimmingCharacters(in: .whitespaces)
        }
    }

    /// Lowercased words only, so "Okay." and "okay!" count as the same phrase.
    private static func key(of unit: String) -> String {
        unit.lowercased()
            .components(separatedBy: CharacterSet.letters.union(.decimalDigits).union(CharacterSet(charactersIn: "'’")).inverted)
            .filter { !$0.isEmpty }.joined(separator: " ")
    }
}
