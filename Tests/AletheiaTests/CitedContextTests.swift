import XCTest
import AletheiaCore
@testable import Aletheia

final class CitedContextTests: XCTestCase {
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

    func testCitedContextTagsSessionsNewestFirstAndMapsThem() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let jan = try store.createSession(for: patient, on: date(2026, 1, 5))
        try store.saveTranscript("A weekend of kayaking.", for: patient, session: jan)
        let mar = try store.createSession(for: patient, on: date(2026, 3, 5))
        try store.saveTranscript("She spoke about her grief.", for: patient, session: mar)

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "grief")

        // Newest session is S1.
        XCTAssertEqual(context.sources.first?.tag, "S1")
        XCTAssertEqual(context.sources.first?.folderName, mar.folderName)
        XCTAssertEqual(context.sources.map(\.tag), ["S1", "S2"])

        // The tag is embedded in the context the model sees.
        XCTAssertTrue(context.text.contains("[S1]"))

        // And it round-trips: a model answer citing [S1] resolves to March.
        let cited = Citations.citedSources(in: "Per [S1].", from: context.sources)
        XCTAssertEqual(cited.first?.folderName, mar.folderName)
    }

    func testCitedContextSkipsEmptyTranscripts() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        _ = try store.createSession(for: patient, on: date(2026, 2, 1)) // no transcript saved
        let withText = try store.createSession(for: patient, on: date(2026, 2, 2))
        try store.saveTranscript("Discussed medication.", for: patient, session: withText)

        let context = store.gatherCitedPatientContext(for: patient, relevantTo: "medication")
        XCTAssertEqual(context.sources.map(\.tag), ["S1"], "only sessions with transcripts get tags")
        XCTAssertEqual(context.sources.first?.folderName, withText.folderName)
    }
}
