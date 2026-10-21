import Foundation

// Global search results: one row per place a query matched.

/// What a global-search hit is. The order is the order results are grouped in:
/// who and when first, then the therapist's own words, then the long text.
enum SearchKind: String, CaseIterable, Identifiable {
    case patient
    /// A session found by its date (and the patient's name).
    case session
    /// The therapist's own notes on a session ("My Notes").
    case sessionNotes
    /// A generated progress note, one per format.
    case note
    case comment
    case transcript

    var id: String { rawValue }

    /// The badge on a result row.
    var badge: String {
        switch self {
        case .patient: return "Patient"
        case .session: return "Session"
        case .sessionNotes: return "My notes"
        case .note: return "Note"
        case .comment: return "Comment"
        case .transcript: return "Transcript"
        }
    }

    /// The label of this kind's group of results.
    var filterLabel: String {
        switch self {
        case .patient: return "Patients"
        case .session: return "Sessions"
        case .sessionNotes: return "My notes"
        case .note: return "Progress notes"
        case .comment: return "Comments"
        case .transcript: return "Transcripts"
        }
    }
}

/// One global-search result: a single match in one place. Patients match by
/// name; sessions by date; "my notes" by the therapist's session notes;
/// transcripts by transcript text; notes by a generated progress note;
/// comments by a transcript comment (its text or the passage it's on).
struct SearchHit: Identifiable, Equatable {
    let id: String
    let kind: SearchKind
    let patient: Patient
    /// The session to open; nil for a patient hit.
    let session: SessionRecord?
    /// For a progress-note hit, the format's short name ("SOAP", "Summary").
    let noteLabel: String?
    /// For a progress-note hit, the format to open.
    let noteFormat: ProgressNoteFormat?
    /// For a comment hit, the comment's identifier in the rail.
    let commentID: String?
    /// For a comment hit, seconds into the session the comment is anchored at.
    let commentSeconds: Double?
    let snippet: String

    init(
        id: String,
        kind: SearchKind,
        patient: Patient,
        session: SessionRecord?,
        noteLabel: String? = nil,
        noteFormat: ProgressNoteFormat? = nil,
        commentID: String? = nil,
        commentSeconds: Double? = nil,
        snippet: String
    ) {
        self.id = id
        self.kind = kind
        self.patient = patient
        self.session = session
        self.noteLabel = noteLabel
        self.noteFormat = noteFormat
        self.commentID = commentID
        self.commentSeconds = commentSeconds
        self.snippet = snippet
    }

    /// "<Patient>, <Mon d, yyyy>", plus " (<Format>)" for a progress note and
    /// " at m:ss" for a comment. A patient hit is just the name.
    var title: String {
        guard let session else { return patient.name }
        var text = "\(patient.name), \(Self.dateText(session.date))"
        if kind == .note, let noteLabel { text += " (\(noteLabel))" }
        if kind == .comment, let commentSeconds { text += " at \(Self.clockText(commentSeconds))" }
        return text
    }

    /// "Oct 8, 2026" (field order follows the user's region).
    static func dateText(_ date: Date) -> String {
        dateFormatter.string(from: date)
    }

    /// Seconds as m:ss ("0:57", "61:05").
    static func clockText(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let remainder = total % 60
        return "\(total / 60):" + (remainder < 10 ? "0" : "") + "\(remainder)"
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.setLocalizedDateFormatFromTemplate("MMM d yyyy")
        return f
    }()

    /// Hits per kind, for the chips' counts.
    static func counts(_ hits: [SearchHit]) -> [SearchKind: Int] {
        var counts: [SearchKind: Int] = [:]
        for hit in hits { counts[hit.kind, default: 0] += 1 }
        return counts
    }

    /// How many different patients the hits belong to.
    static func patientCount(_ hits: [SearchHit]) -> Int {
        Set(hits.map { $0.patient.id }).count
    }
}
