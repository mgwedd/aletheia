import Foundation

/// One saved conversation in a patient's cross-session chat. The patient chat
/// used to be a single `patient_chat.json`; a therapist naturally has several
/// distinct lines of inquiry about the same patient (risk review, medication
/// history, a specific incident), so each is its own thread — ChatGPT-style —
/// persisted as a file the user can browse, rename, and delete.
///
/// Persisted as a row in the local SQLite store (`CommentStore`), keyed by the
/// patient's slug, with the title and message payload sealed per-field like any
/// other PHI. (Earlier builds kept one JSON file per thread under
/// `<patientDir>/ChatThreads/`; those are imported into the DB on first access.)
public struct ChatThread: Identifiable, Codable, Equatable {
    public let id: UUID
    /// The therapist's chosen title. Empty means "untitled" — `displayTitle`
    /// then derives one from the first question, so a thread is never nameless.
    public var title: String
    public let createdAt: Date
    /// Bumped on every message so the thread list can sort by recent activity.
    public var updatedAt: Date
    public var messages: [ChatMessage]

    public init(
        id: UUID = UUID(),
        title: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        messages: [ChatMessage] = []
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.messages = messages
    }

    /// The name to show: the user's title if set, otherwise one derived from the
    /// first question, otherwise a neutral placeholder for an empty thread.
    public var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        return ChatThread.autoTitle(from: messages)
    }

    /// A short title inferred from the first user message in a conversation.
    public static func autoTitle(from messages: [ChatMessage]) -> String {
        guard let firstQuestion = messages.first(where: { $0.role == .user })?.text else {
            return "New chat"
        }
        return deriveTitle(from: firstQuestion)
    }

    /// Turns a question into a compact, single-line title: whitespace collapsed,
    /// clipped to `maxLength` on a word boundary with an ellipsis. Pure string
    /// logic, so it's unit-tested.
    public static func deriveTitle(from text: String, maxLength: Int = 40) -> String {
        let collapsed = text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        guard !collapsed.isEmpty else { return "New chat" }
        guard collapsed.count > maxLength else { return collapsed }

        let clipped = collapsed.prefix(maxLength)
        if let lastSpace = clipped.lastIndex(of: " "), lastSpace > clipped.startIndex {
            return collapsed[..<lastSpace].trimmingCharacters(in: .whitespaces) + "…"
        }
        return clipped.trimmingCharacters(in: .whitespaces) + "…"
    }
}
