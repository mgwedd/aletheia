import Foundation

/// A small shared bus for navigation requested from outside the normal UI —
/// principally App Intents (Siri/Shortcuts). An intent sets `pendingPatientID`
/// and `RootView` observes it to select that patient.
@MainActor
final class AppNavigator: ObservableObject {
    static let shared = AppNavigator()

    @Published var pendingPatientID: UUID?

    /// A session to open once its patient is on screen (set by global search or Spotlight).
    /// `PatientDetailView` consumes it when its patient matches.
    struct PendingSession: Equatable {
        let patientID: UUID
        let sessionID: UUID?
        let sessionFolderName: String?
        let initialTab: SessionTab?
        let initialNoteFormat: ProgressNoteFormat?
        let initialShowingMyNotes: Bool
        let initialFocusedCommentID: String?

        init(
            patientID: UUID,
            sessionID: UUID? = nil,
            sessionFolderName: String? = nil,
            initialTab: SessionTab? = nil,
            initialNoteFormat: ProgressNoteFormat? = nil,
            initialShowingMyNotes: Bool = false,
            initialFocusedCommentID: String? = nil
        ) {
            self.patientID = patientID
            self.sessionID = sessionID
            self.sessionFolderName = sessionFolderName
            self.initialTab = initialTab
            self.initialNoteFormat = initialNoteFormat
            self.initialShowingMyNotes = initialShowingMyNotes
            self.initialFocusedCommentID = initialFocusedCommentID
        }
    }

    @Published var pendingSession: PendingSession?

    private init() {}

    /// Asks the patient view for `patientID` to select a session. The caller
    /// selects the patient itself; this only carries the session through.
    func requestOpenSession(
        patientID: UUID,
        sessionID: UUID? = nil,
        sessionFolderName: String? = nil,
        initialTab: SessionTab? = nil,
        initialNoteFormat: ProgressNoteFormat? = nil,
        initialShowingMyNotes: Bool = false,
        initialFocusedCommentID: String? = nil
    ) {
        pendingSession = PendingSession(
            patientID: patientID,
            sessionID: sessionID,
            sessionFolderName: sessionFolderName,
            initialTab: initialTab,
            initialNoteFormat: initialNoteFormat,
            initialShowingMyNotes: initialShowingMyNotes,
            initialFocusedCommentID: initialFocusedCommentID
        )
    }

    func requestOpen(patientID: UUID) {
        pendingPatientID = patientID
    }

    /// Opens the target of a Spotlight hit. Session hits open the owning patient
    /// and request selecting the matched session; patient hits open the patient directly.
    func open(_ route: SpotlightRoute) {
        switch route {
        case .patient(let id):
            requestOpen(patientID: id)
        case .session(let patientID, let folderName):
            requestOpen(patientID: patientID)
            requestOpenSession(patientID: patientID, sessionFolderName: folderName)
        }
    }
}
