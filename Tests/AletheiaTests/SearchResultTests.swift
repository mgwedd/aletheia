import XCTest
@testable import Aletheia

final class SearchResultTests: XCTestCase {
    func testMatchFieldLabels() {
        XCTAssertEqual(MatchField.transcript.label, "Transcript")
        XCTAssertEqual(MatchField.summary.label, "Summary")
    }

    func testSessionSearchResultInitialization() {
        let sessionID = UUID()
        let record = SessionRecord(
            id: sessionID,
            patientId: UUID(),
            date: Date(),
            folderName: "2026-09-30_Session",
            hasRecording: false,
            hasTranscript: true,
            hasSummary: true
        )
        let result = SessionSearchResult(
            id: sessionID,
            session: record,
            matchedIn: .transcript,
            snippet: "Sample snippet"
        )

        XCTAssertEqual(result.id, sessionID)
        XCTAssertEqual(result.session.id, sessionID)
        XCTAssertEqual(result.matchedIn, .transcript)
        XCTAssertEqual(result.snippet, "Sample snippet")
    }

    func testPatientSearchResultInitialization() {
        let patientID = UUID()
        let patient = Patient(id: patientID, name: "Jane Doe", slug: "Jane-Doe")
        let sessionResult = SessionSearchResult(
            id: UUID(),
            session: SessionRecord(
                id: UUID(),
                patientId: patientID,
                date: Date(),
                folderName: "2026-09-30_Session"
            ),
            matchedIn: .summary,
            snippet: "s"
        )
        let patientResult = PatientSearchResult(
            id: patientID,
            patient: patient,
            nameMatched: true,
            sessionResults: [sessionResult]
        )

        XCTAssertEqual(patientResult.id, patientID)
        XCTAssertEqual(patientResult.patient.name, "Jane Doe")
        XCTAssertTrue(patientResult.nameMatched)
        XCTAssertEqual(patientResult.sessionResults.count, 1)
    }
}
