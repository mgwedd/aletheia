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

    /// Maximum tokens a reply for this task may generate.
    var maxTokens: Int {
        switch self {
        case .note, .chat: return ContextBudget.replyHeadroomTokens
        case .digest: return 768
        case .compaction: return 512
        }
    }
}
