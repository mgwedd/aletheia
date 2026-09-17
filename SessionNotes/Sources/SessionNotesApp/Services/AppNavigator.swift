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
}
