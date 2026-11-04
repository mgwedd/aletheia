import Foundation

/// What a request is for. Notes, digests and factual chat want the same
/// answer every time, so they run cool; this is the one place that says how cool.
enum AITask: String {
    case note, digest, chat, compaction

    var temperature: Double {
        switch self {
        case .note, .digest, .compaction: return 0.2
        case .chat: return 0.3
        }
    }

    /// Maximum tokens a reply for this task may generate. A note, an answer
    /// or a summary gets all the room the context budget keeps for a reply
    /// (`ContextBudget.replyHeadroomTokens`): a cap below what the prompt asks
    /// for cuts the reply off, and a cut-off summary silently replaces the
    /// conversation it was meant to keep.
    var maxTokens: Int {
        switch self {
        case .note, .chat, .compaction: return ContextBudget.replyHeadroomTokens
        case .digest: return 768
        }
    }
}
