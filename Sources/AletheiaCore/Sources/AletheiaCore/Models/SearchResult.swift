import Foundation

public enum MatchField: String {
    case transcript
    case summary

    public var label: String {
        switch self {
        case .transcript: return "Transcript"
        case .summary: return "Summary"
        }
    }
}

/// One session that matched a search, with a short excerpt showing where.
public struct SessionSearchResult: Identifiable {
    /// The session's stable id, so this doubles as the list identity.
    public let id: UUID
    public let session: SessionRecord
    public let matchedIn: MatchField
    public let snippet: String

    public init(id: UUID, session: SessionRecord, matchedIn: MatchField, snippet: String) {
        self.id = id
        self.session = session
        self.matchedIn = matchedIn
        self.snippet = snippet
    }
}

/// A patient plus their sessions that matched a search. The patient itself
/// can match (by name) with no matching sessions.
public struct PatientSearchResult: Identifiable {
    public let id: UUID
    public let patient: Patient
    public let nameMatched: Bool
    public let sessionResults: [SessionSearchResult]

    public init(id: UUID, patient: Patient, nameMatched: Bool, sessionResults: [SessionSearchResult]) {
        self.id = id
        self.patient = patient
        self.nameMatched = nameMatched
        self.sessionResults = sessionResults
    }
}
