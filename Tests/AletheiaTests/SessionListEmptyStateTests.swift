@testable import Aletheia
import XCTest

final class SessionListEmptyStateTests: XCTestCase {
    func testShownOnlyWhenThereAreNoSessions() {
        XCTAssertTrue(SessionListEmptyState.isShown(sessionCount: 0))
        XCTAssertFalse(SessionListEmptyState.isShown(sessionCount: 1))
    }

    func testCopy() {
        XCTAssertEqual(SessionListEmptyState.title, "No Sessions Yet")
        XCTAssertEqual(SessionListEmptyState.newSessionButton, "New session")
    }

    func testThePatientPageReadsItsEmptyStateFromHere() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try String(
            contentsOf: repo.appendingPathComponent("Sources/App/Views/PatientDetailView.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("SessionListEmptyState.isShown(sessionCount: sessions.count)"))
        XCTAssertTrue(view.contains("Label(SessionListEmptyState.title"))
        XCTAssertTrue(view.contains("Button(SessionListEmptyState.newSessionButton)"))
    }
}
