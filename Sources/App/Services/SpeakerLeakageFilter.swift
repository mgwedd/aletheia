import Foundation

/// Text-level guard against the call audio bleeding into the therapist's mic.
///
/// Speaker labels are the audio track a line came from, not voice analysis:
/// `mic.caf` is "Therapist", `call.caf` is "Call audio".
///
/// ```
///  therapist ─► mic ───────────────────────────────► mic.caf   "Therapist"
///                 ▲ bleed (speakers): the call re-enters the mic
///  patient ─► call app ─► speakers ─► system audio ─► call.caf  "Call audio"
/// ```
///
/// With speakers (not headphones) the same words are transcribed twice: once on
/// the call track (correct) and once on the mic track (wrongly labelled
/// "Therapist"). This drops a mic line when its words are, in order, nearly all
/// contained in call-track lines that start around the same time.
///
/// What it does not fix: in-person or shared-mic sessions (every line is
/// "Therapist"), a call track that carries non-patient system audio, and track
/// clocks that drift apart.
///
/// Pure and independent of Whisper and AVFoundation so it is unit tested
/// directly. **Not wired into `WhisperTranscriber` yet**: the thresholds are
/// unvalidated against a real two-party recording, and a false positive deletes
/// something the therapist actually said from the clinical record. It is biased
/// to keep: short lines and partial overlaps are never dropped.
///
/// Rule for wiring it: never drop a line only because it overlaps the other
/// track in time. An interruption is real simultaneous speech; only drop when
/// the words match too. Run it on the mic lines after cleaning and before the
/// tracks are merged and sorted, which needs the per-track loop in
/// `transcribeSession` split so the two tracks stay separate until then.
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
    /// preserving order. `call` is never modified. Both inputs should already
    /// be cleaned (`TranscriptCleaner.clean`).
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
