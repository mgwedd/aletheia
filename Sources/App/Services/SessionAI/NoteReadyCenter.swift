import Foundation

/// The note that has just finished writing, for the "note ready" notice the main
/// window shows wherever the therapist is (`NoteReadyToast`). The notice stays
/// until it is opened or dismissed, or the next note replaces it.
@MainActor
final class NoteReadyCenter: ObservableObject {
    struct Notice: Equatable {
        let patientID: UUID
        let sessionID: UUID
        /// In the app's own window, so the full name (`PatientLabel`, `.inApp`).
        let patientName: String
        let sessionDate: Date
        let format: ProgressNoteFormat

        /// "SOAP note ready". No name, so it is safe to speak aloud.
        var title: String { NoteReadyCenter.title(format: format) }
        var detail: String {
            "\(patientName) · \(sessionDate.formatted(date: .abbreviated, time: .omitted))"
        }
    }

    @Published private(set) var notice: Notice?

    nonisolated static func title(format: ProgressNoteFormat) -> String { "\(format.shortName) note ready" }
    static let openButton = "Open Note"
    static let dismissButton = "Dismiss"

    func announce(patient: Patient, session: SessionRecord, format: ProgressNoteFormat) {
        notice = Notice(
            patientID: patient.id, sessionID: session.id,
            patientName: PatientLabel.text(for: patient, surface: .inApp,
                                           policy: .current(showFullName: false)),
            sessionDate: session.date, format: format)
    }

    func dismiss() { notice = nil }

    /// Opens the note's session on its Notes tab, showing that format.
    func open() {
        guard let notice else { return }
        let navigator = AppNavigator.shared
        navigator.requestOpen(patientID: notice.patientID)
        navigator.requestOpenSession(
            patientID: notice.patientID, sessionID: notice.sessionID,
            initialTab: .notes, initialNoteFormat: notice.format)
        self.notice = nil
    }
}
