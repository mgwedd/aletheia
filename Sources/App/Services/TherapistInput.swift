import Foundation

/// The therapist's own text given to the assistant: her session notes, margin
/// comments, the patient background and her question. It is never cut
/// silently. Up to its share of what this Mac can read it goes in whole;
/// longer, the parts of it that search finds for the question (or the note's
/// topics) go in, under a line saying so, and the caller reports it; past
/// `characterLimit` the request is refused with an error naming the field.
enum TherapistInput {
    /// A dense single-spaced page: about 500 words.
    static let pageCharacters = 3_000
    /// The most one field may hold, in pages. Far beyond what a therapist
    /// writes by hand, but room for a pasted intake packet or a long history;
    /// past it, searching the text for a question stops being meaningful
    /// (most of it would never be read) and the request is refused.
    static let pageLimit = 100
    static let characterLimit = pageLimit * pageCharacters

    enum Field: String, Equatable {
        case background = "The patient background"
        case notes = "The session notes"
        case comments = "The margin comments"
        case question = "The question"
    }

    /// A field over `characterLimit`.
    struct TooLong: LocalizedError, Equatable {
        let field: Field

        var errorDescription: String? {
            "\(field.rawValue) is too long for the assistant to read: the limit is about "
                + "\(TherapistInput.pageLimit) pages (\(TherapistInput.characterLimit.formatted()) characters). "
                + "Shorten it and try again."
        }
    }

    /// Throws `TooLong` for the first field over `characterLimit`.
    static func check(_ fields: [(text: String, field: Field)]) throws {
        for entry in fields where entry.text.count > characterLimit {
            throw TooLong(field: entry.field)
        }
    }

    /// How much one field may take before only its matching parts go in: a
    /// quarter of what `budget` can read, so the source material keeps the rest.
    static func room(in budget: ContextBudget) -> Int {
        budget.availableCharacters(reserving: 0) / 4
    }

    /// A field as it goes into the prompt, and whether only part of it did.
    struct Fitted: Equatable {
        let text: String
        let excerpted: Bool
    }

    /// `text` whole when it is within `room`; otherwise the passages search
    /// finds in it for `query` (its opening when nothing matches), within
    /// `room`, after a line saying only part of it is included.
    static func fit(_ text: String, room: Int, query: String) -> Fitted {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > room else { return Fitted(text: trimmed, excerpted: false) }
        let pages = max(1, Int((Double(trimmed.count) / Double(pageCharacters)).rounded()))
        let lead = "(About \(pages) page\(pages == 1 ? "" : "s"), too long to include whole: only the parts "
            + "that match the question are below; [\u{2026}] marks what is skipped.)"
        let limit = max(0, room - lead.count - 1)
        // Searched line by line (the transcript kind): the other kinds index whole
        // paragraphs, and a long single-spaced text is one paragraph.
        let document = SessionSearch.Document(date: Date(), tag: "", kind: .transcript, text: trimmed)
        let lines = trimmed.components(separatedBy: "\n")
        var blocks: [String] = []
        var taken = Set<Int>()
        var used = 0
        for hit in SessionSearch.search([document], question: query, characterBudget: limit).hits
        where hit.lineIndex < lines.count && !taken.contains(hit.lineIndex) {
            // The matching line with two lines either side, or the line alone
            // when that is too long.
            let window = Array(max(0, hit.lineIndex - 2)..<min(lines.count, hit.lineIndex + 3)).filter { !taken.contains($0) }
            var block = window.map { lines[$0] }.joined(separator: "\n")
            var rows = window
            if used + block.count + 5 > limit {
                block = lines[hit.lineIndex]
                rows = [hit.lineIndex]
            }
            guard used + block.count + 5 <= limit else { continue }
            blocks.append(block)
            taken.formUnion(rows)
            used += block.count + 5
        }
        if blocks.isEmpty {
            blocks = [opening(of: trimmed, limit: limit)]
        }
        return Fitted(text: lead + "\n" + blocks.joined(separator: "\n[\u{2026}]\n"), excerpted: true)
    }

    /// The start of `text`, cut at a line break within `limit`.
    private static func opening(of text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let cut = text.prefix(max(0, limit - 4))
        let whole = cut.lastIndex(of: "\n").map { String(cut[..<$0]) } ?? String(cut)
        return whole + "\n[\u{2026}]"
    }

    /// The sentence for a coverage line naming the fields that went in only in part.
    static func coverageNote(_ fields: [Field]) -> String? {
        guard !fields.isEmpty else { return nil }
        let names = fields.map(\.rawValue.lowercasedFirst)
        let list = names.count == 1 ? names[0] : names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
        return "Only the parts of \(list) that match were read: \(fields.count == 1 ? "it is" : "they are") too long to send whole."
    }
}

private extension String {
    var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}

/// A session's therapist-written fields, checked against the limit and fitted
/// to their share of the budget (`TherapistInput`), as a note or answer reads
/// them.
struct TherapistFields: Equatable {
    let notes: String
    let comments: [String]
    let background: String
    /// The fields that went in only in part.
    let excerpted: [TherapistInput.Field]

    /// Throws `TherapistInput.TooLong` when a field (or `question`) is over the limit.
    init(
        notes: String, comments: [String], background: String, question: String = "",
        query: String, budget: ContextBudget
    ) throws {
        let joinedComments = comments.joined(separator: "\n")
        try TherapistInput.check([
            (question, .question), (notes, .notes), (joinedComments, .comments), (background, .background),
        ])
        let room = TherapistInput.room(in: budget)
        var excerpted: [TherapistInput.Field] = []
        func fitted(_ text: String, _ field: TherapistInput.Field) -> String {
            let result = TherapistInput.fit(text, room: room, query: query)
            if result.excerpted { excerpted.append(field) }
            return result.text
        }
        self.notes = fitted(notes, .notes)
        let commentText = fitted(joinedComments, .comments)
        self.comments = excerpted.last == .comments ? [commentText] : comments
        self.background = fitted(background, .background)
        self.excerpted = excerpted
    }

    var coverageNote: String? { TherapistInput.coverageNote(excerpted) }
}
