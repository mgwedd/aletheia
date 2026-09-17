import XCTest
@testable import SessionNotes

/// End-to-end coverage across the storage, search, retrieval, and export
/// layers working together against a real temp-directory store. Headless, so
/// it runs reliably in CI (unlike UI automation).
final class IntegrationTests: XCTestCase {
    private var tempRoot: URL!
    private var store: Store!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = Store(root: tempRoot)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date {
        Calendar(identifier: .gregorian).date(from: DateComponents(year: y, month: m, day: d))!
    }

    func testRecordToReviewLifecycle() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        try store.saveTranscript("[00:00] Therapist: We discussed her sleep and her medication.", for: patient, session: session)
        try store.saveSummary("Focused on sleep and a medication change.", for: patient, session: session)

        // Search finds it (by content, across all patients).
        let hits = store.searchAllPatients(query: "medication")
        XCTAssertEqual(hits.map(\.patient.id), [patient.id])
        XCTAssertEqual(hits.first?.sessionResults.count, 1)

        // Retrieval assembles a context that includes the transcript.
        let context = store.gatherPatientContext(for: patient, relevantTo: "medication")
        XCTAssertTrue(context.contains("medication"))

        // Export carries both transcript and summary.
        let markdown = store.exportPatientHistoryMarkdown(patient: patient)
        XCTAssertTrue(markdown.contains("We discussed her sleep"))
        XCTAssertTrue(markdown.contains("Focused on sleep"))

        // Timeline lookup points back at the session.
        XCTAssertEqual(store.firstMention(of: "medication", for: patient)?.folderName, session.folderName)

        // Reloading the folder still lists the patient and session.
        let reopened = Store(root: tempRoot)
        XCTAssertEqual(try reopened.listPatients().map(\.name), ["Jane Doe"])
        XCTAssertEqual(try reopened.listSessions(for: patient).count, 1)
    }

    func testMultiSessionSearchAndExportOrdering() throws {
        let patient = try store.createPatient(name: "Jane Doe")

        let jan = try store.createSession(for: patient, on: date(2026, 1, 5))
        try store.saveTranscript("A weekend of kayaking and hiking.", for: patient, session: jan)

        let mar = try store.createSession(for: patient, on: date(2026, 3, 5))
        try store.saveTranscript("She spoke about her grief for the first time.", for: patient, session: mar)

        // Content search isolates the matching session.
        let griefHits = store.searchSessions(for: patient, query: "grief")
        XCTAssertEqual(griefHits.count, 1)
        XCTAssertEqual(griefHits.first?.session.folderName, mar.folderName)

        // Export lists sessions newest-first.
        let markdown = store.exportPatientHistoryMarkdown(patient: patient)
        let griefRange = try XCTUnwrap(markdown.range(of: "grief"))
        let kayakRange = try XCTUnwrap(markdown.range(of: "kayaking"))
        XCTAssertLessThan(griefRange.lowerBound, kayakRange.lowerBound)
    }
}
