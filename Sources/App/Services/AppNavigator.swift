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
        /// A search match to scroll to and flash (a transcript or note hit).
        let initialSearchFocus: SearchMatchFocus?

        init(
            patientID: UUID,
            sessionID: UUID? = nil,
            sessionFolderName: String? = nil,
            initialTab: SessionTab? = nil,
            initialNoteFormat: ProgressNoteFormat? = nil,
            initialShowingMyNotes: Bool = false,
            initialFocusedCommentID: String? = nil,
            initialSearchFocus: SearchMatchFocus? = nil
        ) {
            self.patientID = patientID
            self.sessionID = sessionID
            self.sessionFolderName = sessionFolderName
            self.initialTab = initialTab
            self.initialNoteFormat = initialNoteFormat
            self.initialShowingMyNotes = initialShowingMyNotes
            self.initialFocusedCommentID = initialFocusedCommentID
            self.initialSearchFocus = initialSearchFocus
        }
    }

    @Published var pendingSession: PendingSession?

    /// Something to show inside Settings once its window is up (set by the
    /// Doctor's fix buttons). `SettingsView` consumes it.
    @Published var pendingSettings: SettingsRequest?

    private init() {}

    func requestSettings(_ request: SettingsRequest) {
        pendingSettings = request
    }

    /// Takes (and clears) the pending Settings request, so only one Settings
    /// view acts on it.
    func takeSettingsRequest() -> SettingsRequest? {
        defer { pendingSettings = nil }
        return pendingSettings
    }

    /// Asks the patient view for `patientID` to select a session. The caller
    /// selects the patient itself; this only carries the session through.
    func requestOpenSession(
        patientID: UUID,
        sessionID: UUID? = nil,
        sessionFolderName: String? = nil,
        initialTab: SessionTab? = nil,
        initialNoteFormat: ProgressNoteFormat? = nil,
        initialShowingMyNotes: Bool = false,
        initialFocusedCommentID: String? = nil,
        initialSearchFocus: SearchMatchFocus? = nil
    ) {
        pendingSession = PendingSession(
            patientID: patientID,
            sessionID: sessionID,
            sessionFolderName: sessionFolderName,
            initialTab: initialTab,
            initialNoteFormat: initialNoteFormat,
            initialShowingMyNotes: initialShowingMyNotes,
            initialFocusedCommentID: initialFocusedCommentID,
            initialSearchFocus: initialSearchFocus
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

/// A part of Settings that something outside it asks to have shown.
enum SettingsRequest: Equatable {
    /// The Setup Assistant sheet (opened from the General pane).
    case setupAssistant

    /// The pane that holds what is being asked for.
    var pane: SettingsPane {
        switch self {
        case .setupAssistant: return .general
        }
    }
}
