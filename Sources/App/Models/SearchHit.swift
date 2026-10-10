import Foundation

// The flat global-search list: one row per place a query matched.

/// What a global-search hit is. The order is the order of the filter chips.
enum SearchKind: String, CaseIterable, Identifiable {
    case patient
    case session
    case transcript
    case note
    case comment

    var id: String { rawValue }

    /// The badge on a result row.
    var badge: String {
        switch self {
        case .patient: return "Patient"
        case .session: return "Session"
        case .transcript: return "Transcript"
        case .note: return "Note"
        case .comment: return "Comment"
        }
    }

    /// The filter chip's label.
    var filterLabel: String {
        switch self {
        case .patient: return "Patients"
        case .session: return "Sessions"
        case .transcript: return "Transcripts"
        case .note: return "Notes"
        case .comment: return "Comments"
        }
    }
}

/// One row of the flat global-search list: a single match in one place.
/// Patients match by name; sessions by the therapist's session notes;
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
    /// For a comment hit, seconds into the session the comment is anchored at.
    let commentSeconds: Double?
    let snippet: String

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
