import Foundation

/// A small shared bus for navigation requested from outside the normal UI —
/// principally App Intents (Siri/Shortcuts). An intent sets `pendingPatientID`
/// and `RootView` observes it to select that patient.
@MainActor
final class AppNavigator: ObservableObject {
    static let shared = AppNavigator()

    @Published var pendingPatientID: UUID?

    /// A session to open once its patient is on screen (set by global search).
    /// `PatientDetailView` consumes it when its patient matches.
    struct PendingSession: Equatable {
        let patientID: UUID
        let sessionID: UUID
    }

    @Published var pendingSession: PendingSession?

    private init() {}

    /// Asks the patient view for `patientID` to select `sessionID`. The caller
    /// selects the patient itself; this only carries the session through.
    func requestOpenSession(patientID: UUID, sessionID: UUID) {
        pendingSession = PendingSession(patientID: patientID, sessionID: sessionID)
    }

    func requestOpen(patientID: UUID) {
        pendingPatientID = patientID
    }

    /// Opens the target of a Spotlight hit. Session hits currently land on the
    /// owning patient (the session list is right there); patient hits open the
    /// patient directly.
    func open(_ route: SpotlightRoute) {
        switch route {
        case .patient(let id):
            requestOpen(patientID: id)
        case .session(let patientID, _):
            requestOpen(patientID: patientID)
        }
    }
}
