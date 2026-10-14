import Foundation

/// Renders cleaned transcript lines as the stored transcript text, one line
/// per segment: `[MM:SS] <source>: <text>`, or `[MM:SS] <source> (overlapping):
/// <text>` when that speaker was talking over the other track.
///
///   You         |------ A ------|        |-- C --|
///   Call audio          |-- B --|  |-- D --|
///   time ------>
///
///   B spends most of its time under A, and A a good share of its time under
///   B: both are marked. D only touches C: neither is marked.
///
///   [00:10] You (overlapping): ...A
///   [00:14] Call audio (overlapping): ...B
///   [00:20] Call audio: ...D
///   [00:21] You: ...C
///
/// Rules:
///   - Lines are printed in start-time order (ties keep input order).
///   - A line is marked when lines from OTHER sources cover at least
///     `minimumOverlap` seconds of it AND at least `minimumOverlapShare` of
///     its length. Lines of one source never overlap each other.
///   - So each side is judged on its own: a brief "mm-hmm" under a long turn
///     marks neither (too short), and a two-second aside inside a 30-second
///     turn marks the aside but not the turn (too small a share of it).
///   - Order is approximate: a segment's start is only as precise as the
///     speech model's timestamps (see `Prompts.transcriptLegend`).
///
/// Pure, so it is unit tested without audio. Anything that reads the printed
/// lines must tolerate the suffix: `TranscriptTimeline` only reads the leading
/// `[...]`, so it is unaffected.
enum TranscriptFormatter {
    /// Whisper segments run 5-15 seconds and their boundaries are only good to
    /// a few tenths of a second, so a bare "any intersection" rule marks nearly
    /// every line of a lively conversation: one backchannel tags a whole
    /// sentence. A line is only marked when the talk-over is real for it:
    /// at least this many seconds...
    static let minimumOverlap: TimeInterval = 1
    /// ...and at least this share of the line's own length.
    static let minimumOverlapShare = 0.3

    /// Appended to the speaker label of an overlapping line.
    static let overlapSuffix = " (overlapping)"

    /// The transcript text for `lines` (any order), or "" when there are none.
    static func format(_ lines: [TranscribedLine]) -> String {
        let ordered = TranscriptCleaner.timeOrdered(lines)
        let overlapping = overlappingIndices(in: ordered)
        var printed: [String] = []
        for (index, line) in ordered.enumerated() {
            let label = overlapping.contains(index) ? line.source + overlapSuffix : line.source
            let text = line.text.trimmingCharacters(in: .whitespaces)
            printed.append("[\(timestamp(line.startTime))] \(label): \(text)")
        }
        return printed.joined(separator: "\n")
    }

    /// Indices into `ordered` (sorted by start time) of every line that other
    /// sources talk over enough to mark (see `minimumOverlap`).
    ///
    /// Sweep: for line i, only later lines starting before i's end can
    /// intersect it, so the scan stops at the first one that starts later.
    static func overlappingIndices(in ordered: [TranscribedLine]) -> Set<Int> {
        // ponytail: sums intersections, so two other-source lines covering the
        // same stretch count it twice; same-source lines rarely overlap.
        var covered = [TimeInterval](repeating: 0, count: ordered.count)
        for i in 0..<ordered.count {
            let a = ordered[i]
            var j = i + 1
            while j < ordered.count {
                let b = ordered[j]
                // b starts at or after a, so the intersection is
                // [b.start, min(a.end, b.end)].
                if b.startTime >= a.endTime { break }
                if b.source != a.source {
                    let shared = min(a.endTime, b.endTime) - b.startTime
                    covered[i] += shared
                    covered[j] += shared
                }
                j += 1
            }
        }
        return Set(ordered.indices.filter { index in
            let length = ordered[index].endTime - ordered[index].startTime
            return covered[index] >= minimumOverlap && covered[index] >= minimumOverlapShare * length
        })
    }

    /// `MM:SS`; minutes are not wrapped, so a long session reads `[75:12]`
    /// (`TranscriptTimeline.leadingSeconds` parses that form).
    private static func timestamp(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
