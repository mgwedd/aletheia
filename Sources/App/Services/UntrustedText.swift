import Foundation

/// Text the model must treat as data: transcripts, notes, comments, earlier
/// answers. The only way such text gets into a prompt. It is fenced in fixed
/// tags (`Prompts.untrustedDataRule` tells the model to ignore instructions
/// inside them), any copy of those tags inside the text is defused, and
/// segments other than whole transcripts and session material (sized by the
/// context budget itself) are capped so one huge paste can't crowd out the
/// instructions.
struct UntrustedText: Equatable {
    enum Kind: String, CaseIterable {
        case transcript, background, notes, comments, conversation, digest, draft, material
        /// The therapist's own question: sent as-is, not fenced.
        case question

        var isFenced: Bool { self != .question }
        /// Whole transcripts and session material are measured by the budget's
        /// fit check, which refuses a prompt that is too long; cutting them here
        /// would be a silent truncation.
        var isCapped: Bool { self != .transcript && self != .material }
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
