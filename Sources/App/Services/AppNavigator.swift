import Foundation

/// A small shared bus for navigation requested from outside the normal UI —
/// principally App Intents (Siri/Shortcuts). An intent sets `pendingPatientID`
/// and `RootView` observes it to select that patient.
@MainActor
final class AppNavigator: ObservableObject {
    static let shared = AppNavigator()

    @Published var pendingPatientID: UUID?

    private init() {}

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
