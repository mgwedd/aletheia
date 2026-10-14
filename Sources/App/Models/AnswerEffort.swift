import Foundation

/// How much work the assistant puts into a note or answer. Stored per feature
/// (see `AppSettings`); nothing reads it yet. The control and the behaviour
/// land together in a later step.
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

    var blurb: String {
        switch self {
        case .fast: return "Quickest. Works from summaries and search, so some detail may be missed."
        case .normal: return "Reads the whole session when it fits, otherwise summaries plus a closer look."
        case .focus: return "Slowest. Reads as much of the original as memory allows and checks its draft."
        }
    }
}
