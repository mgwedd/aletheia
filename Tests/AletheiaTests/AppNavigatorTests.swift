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
        XCTAssertNil(navigator.pendingSession?.initialSearchFocus)
        navigator.pendingSession = nil
    }

    func testRequestOpenSessionAtASearchMatch() {
        let navigator = AppNavigator.shared
        let focus = SearchMatchFocus(query: "garden", passage: 4)
        navigator.requestOpenSession(patientID: UUID(), sessionID: UUID(), initialTab: .transcript, initialSearchFocus: focus)
        XCTAssertEqual(navigator.pendingSession?.initialSearchFocus, focus)
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

    // MARK: - Settings requests

    func testSettingsRequestIsTakenOnceThenCleared() {
        let navigator = AppNavigator.shared
        navigator.pendingSettings = nil
        navigator.requestSettings(.setupAssistant)
        XCTAssertEqual(navigator.pendingSettings, .setupAssistant)
        XCTAssertEqual(navigator.takeSettingsRequest(), .setupAssistant)
        XCTAssertNil(navigator.pendingSettings)
        XCTAssertNil(navigator.takeSettingsRequest())
    }

    func testTakingWithNothingPendingReturnsNil() {
        let navigator = AppNavigator.shared
        navigator.pendingSettings = nil
        XCTAssertNil(navigator.takeSettingsRequest())
    }

    func testSetupAssistantRequestOpensTheGeneralPane() {
        // The Setup Assistant button lives in the General pane.
        XCTAssertEqual(SettingsRequest.setupAssistant.pane, .general)
    }
}

final class DoctorActionRouteTests: XCTestCase {
    func testSetupAssistantOpensSettingsAtTheAssistant() {
        XCTAssertEqual(DoctorAction.setupAssistant.route, .settings(.setupAssistant))
    }

    func testOpenSettingsOpensSettingsWithoutARequest() {
        XCTAssertEqual(DoctorAction.openSettings.route, .settings(nil))
    }

    func testOtherActionsRoute() {
        XCTAssertEqual(DoctorAction.openSystemSettings.route, .systemSettings)
        XCTAssertEqual(DoctorAction.reviewRecords.route, .reviewRecords)
        XCTAssertEqual(DoctorAction.checkForUpdates.route, .updateCheck)
    }

    /// The Doctor once sent AppKit selectors nothing handled, so its buttons
    /// did nothing. Every action now resolves to a route the view handles;
    /// `DoctorAction.route` is an exhaustive switch, so a new action must add one.
    func testEveryActionHasARoute() {
        let all: [DoctorAction] = [.openSettings, .openSystemSettings, .reviewRecords, .setupAssistant, .checkForUpdates]
        // No two actions share a route (openSettings and setupAssistant differ by their request).
        XCTAssertEqual(Set(all.map { "\($0.route)" }).count, all.count)
    }
}
