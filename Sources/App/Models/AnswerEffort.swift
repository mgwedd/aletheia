import Foundation

/// How much work the assistant puts into a note or answer, remembered per
/// feature (`noteEffort`, `sessionChatEffort`, `patientChatEffort` in `AppSettings`).
enum AnswerEffort: String, CaseIterable, Identifiable, Codable, Hashable {
    case fast
    case normal
    case focus

    static let `default`: AnswerEffort = .normal

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .fast: return "Fast"
        case .normal: return "Normal"
        case .focus: return "Focus"
        }
    }

    /// What the level does, in every place it applies (notes, a session's chat,
    /// the patient chat). Pinned to the numbers below by `AnswerEffortTests`.
    var blurb: String {
        switch self {
        case .fast:
            return "Quickest. Short sessions are read in full. For long sessions and questions across sessions it uses "
                + "a compact set of summaries and search matches, with no follow-up lookups, so detail can be missed."
        case .normal:
            return "Short sessions are read in full. For long sessions and questions across sessions it uses summaries "
                + "and as many search matches as fit; questions also get up to 4 follow-up lookups."
        case .focus:
            return "Slowest. Like Normal, with up to 10 follow-up lookups in two rounds and more room for them; "
                + "a long session's note is also checked against the transcript when there is room."
        }
    }

    /// Characters kept for follow-up lookups in a question across sessions
    /// whose material may run to `budget` characters.
    func patientLookupReserve(budget: Int) -> Int {
        let budget = max(0, budget)
        switch self {
        case .fast: return 0
        case .normal: return min(4_800, budget / 4)
        case .focus: return min(9_600, budget / 3)
        }
    }

    /// Characters kept for follow-up lookups in a long session's chat with
    /// `total` characters of room for material.
    func sessionLookupReserve(total: Int) -> Int {
        let total = max(0, total)
        switch self {
        case .fast: return 0
        case .normal: return min(3_600, total / 3)
        case .focus: return min(7_200, total / 2)
        }
    }

    /// The most one lookup's result may take: the reserve shared by the calls
    /// allowed, between 600 and 2,400 characters. 0 when no lookups run.
    func lookupCharacters(reserve: Int) -> Int {
        guard maxToolCalls > 0 else { return 0 }
        return min(2_400, max(600, reserve / maxToolCalls))
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
