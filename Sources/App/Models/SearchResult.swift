import Foundation

enum MatchField: String {
    case transcript
    case summary

    var label: String {
        switch self {
        case .transcript: return "Transcript"
        case .summary: return "Summary"
        }
    }
}

/// One session that matched a search, with a short excerpt showing where.
struct SessionSearchResult: Identifiable {
    /// The session's stable id, so this doubles as the list identity.
    let id: UUID
    let session: SessionRecord
    let matchedIn: MatchField
    let snippet: String
}

/// A patient plus their sessions that matched a search. The patient itself
/// can match (by name) with no matching sessions.
struct PatientSearchResult: Identifiable {
    let id: UUID
    let patient: Patient
    let nameMatched: Bool
    let sessionResults: [SessionSearchResult]
}
