import Foundation

/// How much the Summary note says. Every level puts clarity first: the setting
/// sets a length to aim for, never a length to pad to.
///
///     concise  ── ~80–150 words: what's needed to recall the session at a glance
///     natural  ── ~150–300 words: the session and its context (default)
///     detailed ── ~300–600 words: sequence, notable statements and nuance
///
/// Applies to the Summary format only; SOAP/DAP/BIRP/GIRP keep their own
/// section structure.
enum SummaryVerbosity: String, CaseIterable, Identifiable, Codable, Hashable {
    case concise
    case natural
    case detailed

    static let `default`: SummaryVerbosity = .natural

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .concise: return "Concise"
        case .natural: return "Natural"
        case .detailed: return "Detailed"
        }
    }

    /// One line for Settings, under the picker.
    var blurb: String {
        switch self {
        case .concise: return "A short summary you can take in at a glance."
        case .natural: return "The session and its context, without extra detail."
        case .detailed: return "A fuller account, including the order of events and notable statements."
        }
    }

    /// The length instruction the Summary prompt carries.
    var promptGuidance: String {
        switch self {
        case .concise:
            return "Length: concise. Aim for roughly 80–150 words: only what a clinician needs to recall the session at a glance."
        case .natural:
            return "Length: natural. Aim for roughly 150–300 words: enough to recall the session and its context, and no more."
        case .detailed:
            return "Length: detailed. Aim for roughly 300–600 words: include the order of events, notable statements and the nuance a later reader would need."
        }
    }

    /// Carried at every level, so a longer setting never means a wordier note.
    static let clarityRule = """
    Clarity comes before length at every setting: plain words, one idea per \
    sentence, no filler, no repetition. Never pad to reach a length; if the \
    session was short or thin, the summary is short.
    """
}
