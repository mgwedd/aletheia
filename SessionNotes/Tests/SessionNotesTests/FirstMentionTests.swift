import XCTest
@testable import SessionNotes

final class FirstMentionTests: XCTestCase {
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

    func testReturnsEarliestSessionThatMentionsTheTerm() throws {
        let patient = try store.createPatient(name: "Jane")

        let jan = try store.createSession(for: patient, on: date(2026, 1, 10))
        try store.saveTranscript("General check-in about work.", for: patient, session: jan)

        let feb = try store.createSession(for: patient, on: date(2026, 2, 10))
        try store.saveTranscript("She first mentioned her grief today.", for: patient, session: feb)

        let mar = try store.createSession(for: patient, on: date(2026, 3, 10))
        try store.saveTranscript("We returned to the grief again.", for: patient, session: mar)

        let first = store.firstMention(of: "grief", for: patient)
        XCTAssertEqual(first?.folderName, feb.folderName)
    }

    func testReturnsNilWhenNeverMentioned() throws {
        let patient = try store.createPatient(name: "Jane")
        let s = try store.createSession(for: patient)
        try store.saveTranscript("Nothing relevant here.", for: patient, session: s)
        XCTAssertNil(store.firstMention(of: "medication", for: patient))
    }

    func testEmptyQueryReturnsNil() throws {
        let patient = try store.createPatient(name: "Jane")
        let s = try store.createSession(for: patient)
        try store.saveTranscript("Some content.", for: patient, session: s)
        XCTAssertNil(store.firstMention(of: "   ", for: patient))
    }
}
