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
///      (the formatter writes minutes past 59, `[75:12]`; `[1:15:12]` also parses).
///   4. The same short sentence, exactly as spoken, 5+ times in a row keeps one
///      copy plus `(repeated ×N)`. Fewer is emphasis, not a glitch, and stays.
///   5. Only the standalone words um, uh, erm and hmm are removed, never next to
///      a back-channel ("Mm hmm", "Uh huh", "Uh oh"), and a line that is only
///      "hmm" is kept. Nothing else.
///
/// Pure, deterministic and idempotent: its own output parses back to itself.
/// Lines it doesn't recognise (hand-typed, other labels, "…" gaps) pass through
/// unchanged and end the turn before them.
enum TranscriptCompactor {
    /// A long turn gets a new stamp when this many seconds have passed since the last.
    static let anchorInterval = 60
    /// Most words in a sentence that counts as a repeatable phrase.
    static let maxLoopWords = 8
    static let minLoopRepeats = 5

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
            // A line that was only filler vanishes, but still ends the turn.
            guard !line.segment.text.isEmpty else { flush(); continue }
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
    /// A back-channel ("Mm hmm", "Uh huh", "Uh oh") right before / after a filler
    /// token, joined by a space, hyphen or dash. Such a filler is part of the sound.
    private static let backChannelBefore = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])(?:huh|hmm|hm|mm|oh|uh|um)[ \-–—]+$"#, options: .caseInsensitive)
    private static let backChannelAfter = try! NSRegularExpression(
        pattern: #"^[ \-–—]+(?:huh|hmm|hm|mm|oh|uh|um)(?![\p{L}\p{N}])"#, options: .caseInsensitive)
    private static let hmmWord = try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])hmm?(?![\p{L}\p{N}])"#, options: .caseInsensitive)

    /// Drops standalone um/uh/erm/hmm (with a comma or dash right after) and
    /// tidies the punctuation only where it removed something. Fillers next to
    /// a back-channel ("Mm hmm", "Uh huh", "Uh oh") stay, and a line that is
    /// only "hmm"-type is kept whole. Text without filler is returned as is.
    static func removeFiller(_ text: String) -> String {
        let ns = text as NSString
        var result = ""
        var pos = 0
        var removed = false
        for m in fillerPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            var tokenEnd = m.range.location + m.range.length
            if ",;—–".contains(ns.substring(with: NSRange(location: tokenEnd - 1, length: 1))) { tokenEnd -= 1 }
            let before = ns.substring(to: m.range.location)
            let after = ns.substring(from: tokenEnd)
            func hit(_ re: NSRegularExpression, _ s: String) -> Bool {
                re.firstMatch(in: s, range: NSRange(location: 0, length: (s as NSString).length)) != nil
            }
            if hit(backChannelBefore, before) || hit(backChannelAfter, after) { continue }
            result = join(result, ns.substring(with: NSRange(location: pos, length: m.range.location - pos)))
            pos = m.range.location + m.range.length
            removed = true
        }
        guard removed else { return text }
        result = join(result, ns.substring(from: pos)).trimmingCharacters(in: .whitespaces)
        if result.isEmpty, hmmWord.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil { return text }
        return result
    }

    /// Glues the text before a removed filler to the text after it, fixing only
    /// the spacing and punctuation at the seam ("was, ." -> "was.", "Right. ." -> "Right.").
    private static func join(_ head: String, _ tail: String) -> String {
        let h = head.replacingOccurrences(of: #"\s+$"#, with: "", options: .regularExpression)
        var t = tail.replacingOccurrences(of: #"^\s+"#, with: "", options: .regularExpression)
        guard !h.isEmpty else {   // start of the text
            t = t.replacingOccurrences(of: #"^[,;]+\s*"#, with: "", options: .regularExpression)
            return t.replacingOccurrences(of: #"^[.!?](?![.!?…])\s*"#, with: "", options: .regularExpression)
        }
        guard let next = t.first, ".!?…,;".contains(next) else {
            return head.last?.isWhitespace == true && tail.first?.isWhitespace == true ? head + tail.dropFirst() : head + tail
        }
        if ",;".contains(h.last!) { return String(h.dropLast()) + t }   // "hard, ." -> "hard."
        if ".!?…".contains(h.last!) {                                   // "Right. ." / "So... ..."
            return h + t.replacingOccurrences(of: #"^[.!?…,;]+"#, with: "", options: .regularExpression)
        }
        return h + t                                                    // "was ." -> "was."
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
        var kept = [[String]](repeating: [], count: segments.count)
        var i = 0
        while i < units.count {
            var j = i + 1
            while j < units.count, !units[i].key.isEmpty, units[j].key == units[i].key { j += 1 }
            let count = j - i
            if count >= minLoopRepeats, units[i].key.split(separator: " ").count <= maxLoopWords {
                let first = units[i].text.trimmingCharacters(in: .whitespaces)
                kept[units[i].segment].append("\(first) (repeated ×\(count)) ")
            } else {
                for k in i..<j { kept[units[k].segment].append(units[k].text) }
            }
            i = j
        }
        for index in segments.indices {
            segments[index].text = kept[index].joined().trimmingCharacters(in: .whitespaces)
        }
    }

    /// The sentence as spoken: lowercased, spaces collapsed, punctuation kept,
    /// so "No?" and "No!" stay different (a question is not an answer).
    private static func key(of unit: String) -> String {
        unit.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }
}
