import Foundation

/// Text-level guard against the call audio bleeding into the therapist's mic.
///
/// Speaker labels are the audio track a line came from, not voice analysis:
/// `mic.caf` is "You", `call.caf` is "Call audio".
///
/// ```
///  therapist ─► mic ───────────────────────────────► mic.caf   "You"
///                 ▲ bleed (speakers): the call re-enters the mic
///  patient ─► call app ─► speakers ─► system audio ─► call.caf  "Call audio"
/// ```
///
/// With speakers (not headphones) the same words are transcribed twice: once on
/// the call track (correct) and once on the mic track (wrongly labelled
/// "You"). This drops a mic line when its words are, in order, nearly all
/// contained in call-track lines that start around the same time, and cuts
/// echoed runs of words out of mic lines that also hold the therapist's own
/// words.
///
/// What it does not fix: in-person or shared-mic sessions (every line is
/// "You"), a call track that carries non-patient system audio, and track
/// clocks that drift apart.
///
/// Pure and independent of Whisper and AVFoundation so it is unit tested
/// directly. `WhisperTranscriber.assemble` runs it on the raw mic
/// segments before the tracks are cleaned and merged. A false positive deletes
/// something the therapist actually said from the transcript (the recording
/// keeps it), so it is biased to keep: short lines and partial overlaps are
/// never dropped, and a line is never dropped only because it overlaps the
/// other track in time. An interruption is real simultaneous speech; only
/// matching words count.
enum SpeakerLeakageFilter {
    /// A call line counts as simultaneous when its start time is within this
    /// many seconds of the mic line's. Segments carry only a start time, and
    /// Whisper cuts the two tracks at different points, so this is generous.
    static let defaultTimeWindow: TimeInterval = 5.0

    /// Mic lines with fewer words than this are always kept: "yes", "mm-hm",
    /// "okay" are as likely to be the therapist as an echo.
    static let defaultMinWords = 5

    /// Fraction of the mic line's words that must appear, in order, in the
    /// nearby call text for the line to be treated as leakage.
    static let defaultContainment = 0.8

    /// Returns `mic` without the lines that look like leakage of `call`,
    /// preserving order. `call` is never modified.
    static func dropLeakedLines(
        mic: [TranscribedLine],
        call: [TranscribedLine],
        timeWindow: TimeInterval = SpeakerLeakageFilter.defaultTimeWindow,
        minWords: Int = SpeakerLeakageFilter.defaultMinWords,
        containment: Double = SpeakerLeakageFilter.defaultContainment
    ) -> [TranscribedLine] {
        guard !call.isEmpty else { return mic }
        let sortedCall = call.sorted { $0.startTime < $1.startTime }
        return mic.filter { line in
            !isLeak(line, call: sortedCall, timeWindow: timeWindow, minWords: minWords, containment: containment)
        }
    }

    /// Whether one mic line is an echo of `call` (which must be sorted by start time).
    static func isLeak(
        _ line: TranscribedLine,
        call: [TranscribedLine],
        timeWindow: TimeInterval = SpeakerLeakageFilter.defaultTimeWindow,
        minWords: Int = SpeakerLeakageFilter.defaultMinWords,
        containment: Double = SpeakerLeakageFilter.defaultContainment
    ) -> Bool {
        let micWords = words(in: line.text)
        guard micWords.count >= max(1, minWords) else { return false }

        var nearbyWords: [String] = []
        for candidate in call where abs(candidate.startTime - line.startTime) <= timeWindow {
            nearbyWords += words(in: candidate.text)
        }
        guard !nearbyWords.isEmpty else { return false }

        let matched = longestCommonSubsequence(micWords, nearbyWords)
        return Double(matched) / Double(micWords.count) >= containment
    }

    /// Lowercased alphanumeric words with apostrophes removed, so "Don't" and
    /// "dont" compare equal and punctuation never matters.
    static func words(in text: String) -> [String] {
        text.lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
    }

    // MARK: - Echoes inside mixed lines

    /// Shortest run of matching words removed from inside a mic line. Shorter
    /// runs are too often everyday phrases both people say.
    static let defaultMinRun = 4

    /// How far apart, in seconds, the estimated times of an echoed run on the
    /// two tracks may be. Segments carry no word times, so each word's time is
    /// interpolated across its segment.
    static let defaultRunTimeWindow: TimeInterval = 3.0

    /// Whole-line echoes dropped, then echoed runs cut out of the lines that
    /// mix the therapist's own words with the call's: Whisper often puts both
    /// in one mic segment. `call` is never modified.
    static func removeLeakage(
        mic: [TranscribedLine],
        call: [TranscribedLine]
    ) -> [TranscribedLine] {
        let sortedCall = call.sorted { $0.startTime < $1.startTime }
        return dropLeakedLines(mic: mic, call: sortedCall).compactMap { stripEchoedRuns(from: $0, call: sortedCall) }
    }

    /// `line` without the runs of at least `minRun` words that repeat, in
    /// order, a call line spoken at the same time; nil when nothing is left.
    /// Only call lines whose time span overlaps the mic line's count: an echo
    /// is simultaneous, while a therapist repeating the client's words back
    /// does so after the client stops. One differing word inside a run (a
    /// number written two ways) doesn't break it.
    static func stripEchoedRuns(
        from line: TranscribedLine,
        call: [TranscribedLine],
        minRun: Int = SpeakerLeakageFilter.defaultMinRun,
        timeWindow: TimeInterval = SpeakerLeakageFilter.defaultRunTimeWindow
    ) -> TranscribedLine? {
        let overlapping = call.filter { $0.startTime < line.endTime && $0.endTime > line.startTime }
        guard !overlapping.isEmpty else { return line }

        let pieces = line.text.split(whereSeparator: \.isWhitespace).map(String.init)
        let micWords = timedWords(pieces: pieces, in: line)
        let callWords = overlapping.flatMap { candidate in
            timedWords(pieces: candidate.text.split(whereSeparator: \.isWhitespace).map(String.init), in: candidate)
        }
        guard micWords.count >= minRun, callWords.count >= minRun else { return line }

        var removed = IndexSet()
        var i = 0
        while i < micWords.count {
            var best = 0
            for j in callWords.indices where callWords[j].key == micWords[i].key
                && abs(callWords[j].time - micWords[i].time) <= timeWindow {
                best = max(best, runLength(micWords, from: i, callWords, from: j, minRun: minRun))
            }
            if best > 0 {
                removed.insert(integersIn: micWords[i].piece...micWords[i + best - 1].piece)
                i += best
            } else {
                i += 1
            }
        }
        guard !removed.isEmpty else { return line }

        let kept = pieces.indices.filter { !removed.contains($0) }.map { pieces[$0] }
        // A line under `defaultMinWords` words is never removed whole.
        guard kept.contains(where: { !words(in: $0).isEmpty }) else {
            return micWords.count < defaultMinWords ? line : nil
        }
        var text = Substring(kept.joined(separator: " "))
        text = text.drop { ",;:-–—.?!… ".contains($0) }
        while let last = text.last, ",;:-–— ".contains(last) { text = text.dropLast() }
        // A cut at the start leaves the rest's first word in lowercase.
        var out = String(text)
        if removed.contains(0), let first = out.first, first.isLowercase {
            out = first.uppercased() + out.dropFirst()
        }
        return TranscribedLine(source: line.source, startTime: line.startTime, endTime: line.endTime, text: out)
    }

    private struct TimedWord {
        let key: String
        /// Index of the whitespace-separated piece the word came from.
        let piece: Int
        let time: TimeInterval
    }

    /// One entry per word (as `words(in:)` splits them, so "well-known" is two),
    /// timed by its place in the segment.
    private static func timedWords(pieces: [String], in line: TranscribedLine) -> [TimedWord] {
        let keyed = pieces.enumerated().flatMap { index, piece in
            words(in: piece).map { (index, $0) }
        }
        let span = max(0, line.endTime - line.startTime)
        return keyed.enumerated().map { position, entry in
            TimedWord(key: entry.1, piece: entry.0,
                      time: line.startTime + span * (Double(position) + 0.5) / Double(keyed.count))
        }
    }

    /// Length (in mic words) of the matching run starting at `i`/`j`, ending on
    /// a match, or 0 when it has fewer than `minRun` matched words. One word
    /// inside the run may differ, if the words either side of it match.
    private static func runLength(_ mic: [TimedWord], from i: Int, _ call: [TimedWord], from j: Int, minRun: Int) -> Int {
        var k = 0, matched = 0, length = 0, substituted = false
        while i + k < mic.count, j + k < call.count {
            if mic[i + k].key == call[j + k].key {
                matched += 1
                length = k + 1
            } else if !substituted, k > 0, i + k + 1 < mic.count, j + k + 1 < call.count,
                      mic[i + k + 1].key == call[j + k + 1].key {
                substituted = true
            } else {
                break
            }
            k += 1
        }
        return matched >= minRun ? length : 0
    }

    private static func longestCommonSubsequence(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: b.count + 1)
        var current = previous
        for x in a {
            for j in 1...b.count {
                current[j] = x == b[j - 1] ? previous[j - 1] + 1 : max(previous[j], current[j - 1])
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
