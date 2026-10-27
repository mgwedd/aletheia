import Foundation

/// The wording shown before a patient is permanently deleted. Kept apart from
/// the view so the copy and the last-session line can be tested directly.
struct DeletePatientConfirmation: Equatable {
    let patientName: String
    let lastSessionDate: Date?

    static let permanenceNotice =
        "This deletes this patient and all of their recorded sessions, clinical notes, transcripts, audio, and AI conversations from Aletheia. It cannot be undone from within the app."

    static let copiesNotice =
        "Copies can remain outside the live data: the database snapshots Aletheia keeps in the hidden .backups folder (the five newest rolling snapshots, including one taken just before this delete, which newer ones later replace, and copies made before database changes, which are kept until removed), and any Time Machine or other backups and exports you made. Deleting files on a Mac does not securely erase them."

    static let retentionNotice =
        "Clinical records are usually required to be kept for a set period, set by state rules and often several years after the last visit. Check the rules that apply to you before deleting."

    static let keepNotice = "Cancel keeps everything as it is."

    var title: String { "Delete \(patientName)?" }

    /// The most recent session date, or nil when the patient has none.
    init(patientName: String, sessionDates: [Date]) {
        self.patientName = patientName
        self.lastSessionDate = sessionDates.max()
    }

    var lastSessionLine: String {
        guard let date = lastSessionDate else { return "No sessions are recorded for this patient." }
        return "Last session: \(date.formatted(date: .long, time: .omitted))."
    }

    /// Everything the sheet says, in reading order.
    var paragraphs: [String] {
        [Self.permanenceNotice, Self.copiesNotice, Self.retentionNotice, lastSessionLine, Self.keepNotice]
    }
}
