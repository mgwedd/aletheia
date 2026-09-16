import XCTest
@testable import SessionNotes

final class StoreSearchTests: XCTestCase {
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

    func testSearchSessionsMatchesTranscriptAndReturnsSnippet() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        try store.saveTranscript("The client mentioned trouble sleeping most nights.", for: patient, session: session)

        let results = store.searchSessions(for: patient, query: "sleeping")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.matchedIn, .transcript)
        XCTAssertTrue(results.first?.snippet.localizedCaseInsensitiveContains("sleeping") ?? false)
    }

    func testSearchPrefersTranscriptOverSummary() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        try store.saveTranscript("anxiety came up repeatedly", for: patient, session: session)
        try store.saveSummary("anxiety was the main theme", for: patient, session: session)

        let results = store.searchSessions(for: patient, query: "anxiety")
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.matchedIn, .transcript)
    }

    func testSearchFallsBackToSummaryWhenTranscriptDoesNotMatch() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        try store.saveTranscript("small talk about the weather", for: patient, session: session)
        try store.saveSummary("client is planning a vacation", for: patient, session: session)

        let results = store.searchSessions(for: patient, query: "vacation")
        XCTAssertEqual(results.first?.matchedIn, .summary)
    }

    func testSearchAllPatientsIncludesNameMatchesAndContentMatches() throws {
        let jane = try store.createPatient(name: "Jane Doe")
        let john = try store.createPatient(name: "John Smith")
        let session = try store.createSession(for: john)
        try store.saveTranscript("discussed medication changes", for: john, session: session)

        // Name match, no session content.
        let byName = store.searchAllPatients(query: "Jane")
        XCTAssertEqual(byName.map(\.patient.id), [jane.id])
        XCTAssertTrue(byName.first?.nameMatched ?? false)
        XCTAssertTrue(byName.first?.sessionResults.isEmpty ?? false)

        // Content match on a different patient.
        let byContent = store.searchAllPatients(query: "medication")
        XCTAssertEqual(byContent.map(\.patient.id), [john.id])
        XCTAssertEqual(byContent.first?.sessionResults.count, 1)
    }

    func testEmptyQueryReturnsNothing() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let session = try store.createSession(for: patient)
        try store.saveTranscript("some content", for: patient, session: session)
        XCTAssertTrue(store.searchSessions(for: patient, query: "   ").isEmpty)
        XCTAssertTrue(store.searchAllPatients(query: "").isEmpty)
    }
}
