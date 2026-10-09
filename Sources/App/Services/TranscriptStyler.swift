import Foundation

/// Finds the parts of a transcript line that are styled differently in the
/// transcript view: the `[MM:SS]` time stamp and the speaker label. Only the
/// attributes change; the text is never touched. Pure `NSString`-range logic so
/// the AppKit text view stays a thin shell, and it keeps working as the
/// therapist edits (a line that no longer looks like `[time] Speaker:` simply
/// gets no styling).
///
///   [00:16] Therapist: - No problem.
///   └─────┘ └───────┘
///   timestamp speaker
enum TranscriptStyler {
    enum Role: Equatable {
        case timestamp
        case speaker(String)
    }

    struct Span: Equatable {
        let range: NSRange
        let role: Role
    }

    /// How a speaker label is coloured.
    enum Tone: Equatable {
        case therapist
        case callAudio
        case other
    }

    /// The labels `WhisperTranscriber` writes ("Therapist" for the microphone
    /// track, "Call audio" for the call track); anything else (a hand-typed
    /// name) is neutral.
    static func tone(for label: String) -> Tone {
        switch label.trimmingCharacters(in: .whitespaces).lowercased() {
        case "therapist": return .therapist
        case "call audio": return .callAudio
        default: return .other
        }
    }

    // Line start, [M:SS] / [MM:SS] / [H:MM:SS], then optionally: space, the
    // label (no colon or bracket), an optional " (overlapping)" suffix and the
    // colon. A stamp with no label yet is still a stamp.
    private static let linePattern = try! NSRegularExpression(
        pattern: #"^(\[(?:\d+:)?\d{1,3}:\d{2}\])(?:[ \t]*([^:\n\[\]]{1,40}?)(?: \(overlapping\))?:)?"#,
        options: [.anchorsMatchLines]
    )

    static func spans(in text: String) -> [Span] {
        let ns = text as NSString
        var result: [Span] = []
        linePattern.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            guard let match else { return }
            result.append(Span(range: match.range(at: 1), role: .timestamp))
            let label = match.range(at: 2)
            if label.location != NSNotFound, label.length > 0 {
                result.append(Span(range: label, role: .speaker(ns.substring(with: label))))
            }
        }
        return result
    }
}
