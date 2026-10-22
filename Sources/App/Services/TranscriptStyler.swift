import Foundation

/// Finds the parts of a transcript line that are styled differently in the
/// transcript view: the `[MM:SS]` time stamp and the speaker label. Only the
/// attributes change; the text is never touched. Pure `NSString`-range logic so
/// the AppKit text view stays a thin shell, and it keeps working as the
/// therapist edits (a line that no longer looks like `[time] Speaker:` simply
/// gets no styling).
///
///   [00:16] You: - No problem.
///   └─────┘ └───────┘
///   timestamp speaker
enum TranscriptStyler {
    enum Role: Equatable {
        case timestamp
        case speaker(String)
        /// The " (overlapping)" suffix after a label: a hint for the note model
        /// that stays in the stored text (so every character offset, comment
        /// anchor and search hit is stable) but is never shown to the reader.
        case overlapTag
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

    /// The labels `WhisperTranscriber` writes ("You" for the microphone
    /// track, "Call audio" for the call track); anything else (a hand-typed
    /// name) is neutral.
    static func tone(for label: String) -> Tone {
        switch label.trimmingCharacters(in: .whitespaces).lowercased() {
        case "you": return .therapist
        case "call audio": return .callAudio
        default: return .other
        }
    }

    // Line start, [M:SS] / [MM:SS] / [H:MM:SS], then optionally: space, the
    // label (no colon or bracket), an optional " (overlapping)" suffix and the
    // colon. A stamp with no label yet is still a stamp.
    private static let linePattern = try! NSRegularExpression(
        pattern: #"^(\[(?:\d+:)?\d{1,3}:\d{2}\])(?:[ \t]*([^:\n\[\]]{1,40}?)( \(overlapping\))?:)?"#,
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
            let tag = match.range(at: 3)
            if tag.location != NSNotFound {
                result.append(Span(range: tag, role: .overlapTag))
            }
        }
        return result
    }

    /// The call track's label ranges, which the view shows as the patient's
    /// first name. The stored text keeps "Call audio".
    static func callAudioLabels(in text: String) -> [NSRange] {
        spans(in: text).compactMap { span in
            if case let .speaker(label) = span.role, tone(for: label) == .callAudio { return span.range }
            return nil
        }
    }

    /// `text` with each call-audio label replaced by `name`, for what the
    /// reader takes away (copy). Unchanged when `name` is empty.
    static func namingCallAudio(_ text: String, as name: String) -> String {
        guard !name.isEmpty else { return text }
        let ns = NSMutableString(string: text)
        for range in callAudioLabels(in: text).reversed() {
            ns.replaceCharacters(in: range, with: name)
        }
        return ns as String
    }

    /// What the reader sees of a stored transcript: call audio named after the
    /// patient's first name and no " (overlapping)" suffixes. For exports,
    /// copies, snippets and VoiceOver.
    static func forReader(_ text: String, callAudioName: String) -> String {
        removingOverlapLabels(namingCallAudio(text, as: callAudioName))
    }

    /// `forReader` for styled text (a rich-text copy): the same edits, each
    /// keeping the attributes of the text it replaces.
    static func forReader(_ text: NSAttributedString, callAudioName: String) -> NSAttributedString {
        let out = NSMutableAttributedString(attributedString: text)
        var edits: [(NSRange, String)] = spans(in: text.string).filter { $0.role == .overlapTag }.map { ($0.range, "") }
        if !callAudioName.isEmpty { edits += callAudioLabels(in: text.string).map { ($0, callAudioName) } }
        for (range, replacement) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            out.replaceCharacters(in: range, with: replacement)
        }
        return out
    }

    /// `text` with every " (overlapping)" label suffix removed, for anything
    /// the reader sees or takes away (copy, exports) that needs no offsets
    /// into the stored text. The stored transcript itself keeps the suffix:
    /// the compactor turns it into the `~` hint for the model.
    static func removingOverlapLabels(_ text: String) -> String {
        let ns = text as NSString
        let tags = spans(in: text).filter { $0.role == .overlapTag }.map(\.range)
        guard !tags.isEmpty else { return text }
        var out = ""
        var cursor = 0
        for tag in tags {
            out += ns.substring(with: NSRange(location: cursor, length: tag.location - cursor))
            cursor = NSMaxRange(tag)
        }
        return out + ns.substring(from: cursor)
    }
}
