import Foundation

/// Text the therapist didn't write, going into a prompt as reference material:
/// transcripts, digests, the model's own drafts and chat summaries, and
/// passages quoted from those. It is put in plain tags, and any copy of those
/// tags inside the text is broken, so material can't close its own tags and
/// pass for the instructions around it. `Prompts.materialRule` is the one line
/// that tells the model what the tags mean.
///
/// Nothing is cut here: callers size material to the budget (the long-session
/// digest and passages, compaction), and a prompt that still doesn't fit is
/// refused with an error, never trimmed.
///
/// The therapist's own words (her notes, comments, background, questions,
/// edited prompts and chat turns) are instructions and context she chose, so
/// they are never put in these tags.
struct UntrustedText: Equatable {
    enum Kind: String, CaseIterable {
        /// A session transcript, whole or as passages.
        case transcript
        /// A model-written summary of a session or of its sections.
        case digest
        /// A model-written draft note under check.
        case draft
        /// A model-written summary of an earlier chat (compaction).
        case summary
        /// A mix of the above: retrieved passages, digests, generated notes.
        case material
    }

    let kind: Kind
    let text: String

    init(_ kind: Kind, _ raw: String) {
        self.kind = kind
        self.text = Self.defused(raw)
    }

    /// The text in its tags, as it goes into the prompt.
    var rendered: String { "<\(kind.rawValue)>\n\(text)\n</\(kind.rawValue)>" }

    /// The characters the tags add around `kind`'s text.
    static func tagOverhead(_ kind: Kind) -> Int { 2 * kind.rawValue.count + 7 }

    /// Tag names and spaced or cased variants (`</ transcript>`, `< /Digest >`).
    private static let tagPattern: NSRegularExpression? = {
        let names = Kind.allCases.map(\.rawValue).joined(separator: "|")
        return try? NSRegularExpression(pattern: "<(\\s*/?\\s*)(\(names))\\b", options: .caseInsensitive)
    }()

    /// Breaks any copy of a tag, so text can't close its own.
    static func defused(_ raw: String) -> String {
        guard let tagPattern else { return raw }
        return tagPattern.stringByReplacingMatches(
            in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "<\u{200B}$1$2")
    }
}
