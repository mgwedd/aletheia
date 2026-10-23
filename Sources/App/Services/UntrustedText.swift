import Foundation

/// Text the model must treat as data: transcripts, notes, comments, earlier
/// answers. The only way such text gets into a prompt. It is fenced in fixed
/// tags (`Prompts.untrustedDataRule` tells the model to ignore instructions
/// inside them), any copy of those tags inside the text is defused, and
/// free-standing pastes (background, notes, comments, the question) are
/// capped so one huge paste can't crowd out the instructions.
struct UntrustedText: Equatable {
    enum Kind: String, CaseIterable {
        case transcript, background, notes, comments, conversation, digest, draft, material
        /// The therapist's own question: sent as-is, not fenced.
        case question

        var isFenced: Bool { self != .question }
        /// Only free-standing pastes are capped. Transcripts, material, the
        /// conversation, digests and drafts are sized by their callers (the fit
        /// check, compaction, the digest budget); cutting them here would
        /// silently drop text, such as the newest chat turns.
        var isCapped: Bool { [.background, .notes, .comments, .question].contains(self) }
    }

    static let cutMarker = "\n[… cut: too long]"

    let kind: Kind
    let text: String

    init(_ kind: Kind, _ raw: String, budget: ContextBudget = .current) {
        self.kind = kind
        var text = Self.defused(raw)
        if kind.isCapped {
            let cap = budget.untrustedSegmentCharacters
            if ContextBudget.weightedLength(of: text) > cap {
                text = String(ContextBudget.prefix(Substring(text), weightedLength: cap)) + Self.cutMarker
            }
        }
        self.text = text
    }

    var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// The text as it goes into the prompt: fenced, or bare for a question.
    var rendered: String {
        kind.isFenced ? "<\(kind.rawValue)>\n\(text)\n</\(kind.rawValue)>" : text
    }

    private static let fencePattern: NSRegularExpression? = {
        let names = Kind.allCases.filter(\.isFenced).map(\.rawValue).joined(separator: "|")
        return try? NSRegularExpression(pattern: "<(/?)(\(names))\\b", options: .caseInsensitive)
    }()

    /// Breaks any copy of a fence tag, so text can't close its own fence.
    private static func defused(_ raw: String) -> String {
        guard let fencePattern else { return raw }
        return fencePattern.stringByReplacingMatches(
            in: raw, range: NSRange(raw.startIndex..., in: raw), withTemplate: "<\u{200B}$1$2")
    }
}

extension ContextBudget {
    /// The most one untrusted segment (a note, comment, answer or background)
    /// may take: a quarter of what the window can read.
    var untrustedSegmentCharacters: Int { availableCharacters(reserving: 0) / 4 }
}
