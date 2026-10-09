import Foundation

/// Renders cleaned transcript lines as the stored transcript text, one line
/// per segment: `[MM:SS] <source>: <text>`, or `[MM:SS] <source> (overlapping):
/// <text>` when that speaker was talking over the other track.
///
///   Therapist   |------ A ------|        |-- C --|
///   Call audio          |-- B --|  |-- D --|
///   time ------>
///
///   A and B intersect by more than `overlapTolerance`: both are marked.
///   D only touches C (within the tolerance): neither is marked.
///
///   [00:10] Therapist (overlapping): ...A
///   [00:14] Call audio (overlapping): ...B
///   [00:20] Call audio: ...D
///   [00:21] Therapist: ...C
///
/// Rules:
///   - Lines are printed in start-time order (ties keep input order).
///   - Two lines overlap only if they are from DIFFERENT sources and their
///     [start, end] intervals intersect by more than `overlapTolerance`.
///     Lines of one source never overlap each other.
///   - Both sides of an overlap are marked.
///   - Order is approximate: a segment's start is only as precise as the
///     speech model's timestamps (see `Prompts.transcriptLegend`).
///
/// Pure, so it is unit tested without audio. Anything that reads the printed
/// lines must tolerate the suffix: `TranscriptTimeline` only reads the leading
/// `[...]`, so it is unaffected.
enum TranscriptFormatter {
    /// Intersections shorter than this are not overlaps. Whisper segment
    /// boundaries are only good to a few tenths of a second, and a normal
    /// hand-off between speakers often touches or briefly abuts; without a
    /// tolerance almost every turn change would be flagged.
    static let overlapTolerance: TimeInterval = 0.3

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

    /// Indices into `ordered` (sorted by start time) of every line that
    /// overlaps a line from another source.
    ///
    /// Sweep: for line i, only later lines starting before i's end (less the
    /// tolerance) can overlap it, so the scan stops at the first one that
    /// starts later than that.
    static func overlappingIndices(in ordered: [TranscribedLine]) -> Set<Int> {
        var result = Set<Int>()
        for i in 0..<ordered.count {
            let a = ordered[i]
            var j = i + 1
            while j < ordered.count {
                let b = ordered[j]
                // b starts at or after a, so the intersection is
                // [b.start, min(a.end, b.end)].
                if b.startTime >= a.endTime - overlapTolerance { break }
                if b.source != a.source, min(a.endTime, b.endTime) - b.startTime > overlapTolerance {
                    result.insert(i)
                    result.insert(j)
                }
                j += 1
            }
        }
        return result
    }

    /// `MM:SS`; minutes are not wrapped, so a long session reads `[75:12]`
    /// (`TranscriptTimeline.leadingSeconds` parses that form).
    private static func timestamp(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }
}
