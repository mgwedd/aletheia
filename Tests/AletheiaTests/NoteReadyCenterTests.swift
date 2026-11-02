import XCTest
@testable import Aletheia

/// NOTE-22: a finished note is announced in the main window and opens on its Notes tab.
@MainActor
final class NoteReadyCenterTests: XCTestCase {
    private var tempRoot: URL!
    private var store: Store!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = Store(root: tempRoot)
    }

    override func tearDownWithError() throws {
        AppNavigator.shared.pendingPatientID = nil
        AppNavigator.shared.pendingSession = nil
        try? FileManager.default.removeItem(at: tempRoot)
    }

    func testAnnouncesTheFormatWithoutTheNameInItsTitle() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        let center = NoteReadyCenter()

        center.announce(patient: patient, session: session, format: .soap)

        XCTAssertEqual(center.notice?.title, "SOAP note ready")
        XCTAssertFalse(center.notice?.title.contains("Jane") ?? true)
        XCTAssertEqual(center.notice?.detail.hasPrefix("Jane Doe · "), true)
    }

    func testOpenGoesToTheNoteAndClearsTheNotice() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        let center = NoteReadyCenter()
        center.announce(patient: patient, session: session, format: .dap)

        center.open()

        XCTAssertNil(center.notice)
        XCTAssertEqual(AppNavigator.shared.pendingPatientID, patient.id)
        XCTAssertEqual(AppNavigator.shared.pendingSession, AppNavigator.PendingSession(
            patientID: patient.id, sessionID: session.id, initialTab: .notes, initialNoteFormat: .dap))
    }

    func testDismissClearsTheNotice() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let center = NoteReadyCenter()
        center.announce(patient: patient, session: try store.createSession(for: patient), format: .soap)

        center.dismiss()

        XCTAssertNil(center.notice)
    }
}
