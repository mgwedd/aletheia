import XCTest
@testable import Aletheia

@MainActor
final class AppNavigatorTests: XCTestCase {
    func testRequestOpenUpdatesPendingPatientID() {
        let navigator = AppNavigator.shared
        let patientID = UUID()
        navigator.requestOpen(patientID: patientID)
        XCTAssertEqual(navigator.pendingPatientID, patientID)
    }

    func testOpenSpotlightPatientRoute() {
        let navigator = AppNavigator.shared
        let patientID = UUID()
        navigator.open(.patient(patientID))
        XCTAssertEqual(navigator.pendingPatientID, patientID)
    }

    func testOpenSpotlightSessionRoute() {
        let navigator = AppNavigator.shared
        let patientID = UUID()
        let folderName = "2026-09-30_Session"
        navigator.open(.session(patientID: patientID, folderName: folderName))
        XCTAssertEqual(navigator.pendingPatientID, patientID)
    }

    func testRequestOpenSessionCarriesPatientAndSession() {
        let navigator = AppNavigator.shared
        let patientID = UUID()
        let sessionID = UUID()
        navigator.requestOpenSession(patientID: patientID, sessionID: sessionID)
        XCTAssertEqual(navigator.pendingSession, AppNavigator.PendingSession(patientID: patientID, sessionID: sessionID))
        navigator.pendingSession = nil
    }
}
