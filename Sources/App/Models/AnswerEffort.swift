import Foundation

/// How much work the assistant puts into a note or answer, remembered per
/// feature (`noteEffort`, `sessionChatEffort`, `patientChatEffort` in `AppSettings`).
enum AnswerEffort: String, CaseIterable, Identifiable, Codable, Hashable {
    case fast
    case normal
    case focus

    static let `default`: AnswerEffort = .normal

    /// What the selector is called wherever it appears.
    static let label = "AI effort"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .normal: return "Normal"
        case .focus: return "Focus"
        }
    }

    var blurb: String {
        switch self {
        case .fast: return "Quickest. Works from summaries and search, so some detail may be missed."
        case .normal: return "Reads the whole session when it fits, otherwise summaries plus a closer look."
        case .focus: return "Slowest. Reads as much of the original as memory allows and checks its draft."
        }
    }

    /// Maximum read-only tool calls allowed when refining a long-session or patient-wide answer.
    var maxToolCalls: Int {
        switch self {
        case .fast: return 0
        case .normal: return 4
        case .focus: return 10
        }
    }

    /// Maximum second-pass tool rounds before writing the final answer.
    var maxRefinementRounds: Int {
        switch self {
        case .fast: return 0
        case .normal: return 1
        case .focus: return 2
        }
    }
}
