import XCTest
@testable import SessionNotes

final class SessionNotificationsTests: XCTestCase {
    private let date = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 9, day: 16))!

    func testTranscriptionCompleteMentionsPatientAndDate() {
        let content = SessionNotifications.transcriptionComplete(patientName: "Jane Doe", date: date)
        XCTAssertEqual(content.title, "Transcript ready")
        XCTAssertTrue(content.body.contains("Jane Doe"))
        XCTAssertTrue(content.body.contains("2026"))
        XCTAssertTrue(content.identifier.hasPrefix("transcription-"))
    }

    func testSummaryReadyMentionsPatientAndDate() {
        let content = SessionNotifications.summaryReady(patientName: "John Smith", date: date)
        XCTAssertEqual(content.title, "Summary ready")
        XCTAssertTrue(content.body.contains("John Smith"))
        XCTAssertTrue(content.identifier.hasPrefix("summary-"))
    }

    func testIdentifiersAreStableForSamePatientAndDate() {
        let a = SessionNotifications.transcriptionComplete(patientName: "Jane", date: date)
        let b = SessionNotifications.transcriptionComplete(patientName: "Jane", date: date)
        XCTAssertEqual(a.identifier, b.identifier)
    }
}
