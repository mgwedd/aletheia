import Foundation

/// What a chat prompt carries of the conversation so far. Nothing is dropped
/// silently: the latest compaction summary stands in for everything before it,
/// and every message after it goes in whole. Once those outgrow the budget the
/// conversation is compacted again (the view does this before sending, and the
/// therapist can at any time with /compact).
enum ChatMemory {
    /// Characters of messages since the last compaction before the next send
    /// compacts first (about 4,000 tokens), leaving the window to the source
    /// material, which is what answers should rest on.
    static let budget = 12_000

    /// The latest summary, if any, and the messages after it.
    static func remembered(_ messages: [ChatMessage]) -> (summary: String?, recent: [ChatMessage]) {
        guard let index = messages.lastIndex(where: { $0.role == .summary }) else { return (nil, messages) }
        return (messages[index].text, Array(messages[(index + 1)...]))
    }

    static func needsCompaction(_ messages: [ChatMessage]) -> Bool {
        remembered(messages).recent.reduce(0) { $0 + $1.text.count } > budget
    }

    /// The `/compact` command and its optional focus, or nil for a question.
    static func compactCommand(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "/compact" || trimmed.hasPrefix("/compact ") else { return nil }
        return String(trimmed.dropFirst("/compact".count)).trimmingCharacters(in: .whitespaces)
    }

    /// Whether there is anything to compact yet (a message, or an earlier summary).
    static func hasHistory(_ messages: [ChatMessage]) -> Bool {
        let (summary, recent) = remembered(messages)
        return summary != nil || !recent.isEmpty
    }
}
