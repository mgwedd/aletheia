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
        XCTAssertEqual(navigator.pendingSession?.patientID, patientID)
        XCTAssertEqual(navigator.pendingSession?.sessionFolderName, folderName)
        navigator.pendingSession = nil
    }

    func testRequestOpenSessionCarriesPatientAndSession() {
        let navigator = AppNavigator.shared
        let patientID = UUID()
        let sessionID = UUID()
        navigator.requestOpenSession(patientID: patientID, sessionID: sessionID)
        XCTAssertEqual(navigator.pendingSession, AppNavigator.PendingSession(patientID: patientID, sessionID: sessionID))
        navigator.pendingSession = nil
    }

    func testRequestOpenSessionWithInitialTabAndNoteFormat() {
        let navigator = AppNavigator.shared
        let patientID = UUID()
        let sessionID = UUID()
        navigator.requestOpenSession(
            patientID: patientID,
            sessionID: sessionID,
            initialTab: .notes,
            initialNoteFormat: .soap
        )
        XCTAssertEqual(navigator.pendingSession?.initialTab, .notes)
        XCTAssertEqual(navigator.pendingSession?.initialNoteFormat, .soap)
        XCTAssertFalse(navigator.pendingSession?.initialShowingMyNotes ?? true)
        navigator.pendingSession = nil
    }

    func testRequestOpenSessionWithFocusedComment() {
        let navigator = AppNavigator.shared
        let patientID = UUID()
        let sessionID = UUID()
        navigator.requestOpenSession(
            patientID: patientID,
            sessionID: sessionID,
            initialTab: .transcript,
            initialFocusedCommentID: "comment-abc"
        )
        XCTAssertEqual(navigator.pendingSession?.initialTab, .transcript)
        XCTAssertEqual(navigator.pendingSession?.initialFocusedCommentID, "comment-abc")
        navigator.pendingSession = nil
    }

    func testRequestOpenSessionWithShowingMyNotes() {
        let navigator = AppNavigator.shared
        let patientID = UUID()
        let sessionID = UUID()
        navigator.requestOpenSession(
            patientID: patientID,
            sessionID: sessionID,
            initialTab: .notes,
            initialShowingMyNotes: true
        )
        XCTAssertEqual(navigator.pendingSession?.initialTab, .notes)
        XCTAssertTrue(navigator.pendingSession?.initialShowingMyNotes ?? false)
        navigator.pendingSession = nil
    }
}
