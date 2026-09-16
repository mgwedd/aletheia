import XCTest
@testable import SessionNotes

final class StoreTests: XCTestCase {
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

    func testCreatePatientPersistsToDisk() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        XCTAssertEqual(patient.name, "Jane Doe")
        XCTAssertEqual(patient.slug, "Jane-Doe")

        let reloaded = try store.listPatients()
        XCTAssertEqual(reloaded.map(\.id), [patient.id])
        XCTAssertEqual(reloaded.first?.name, "Jane Doe")
    }

    func testDuplicatePatientNameGetsUniqueSlug() throws {
        let first = try store.createPatient(name: "Jane Doe")
        let second = try store.createPatient(name: "Jane Doe")

        XCTAssertEqual(first.slug, "Jane-Doe")
        XCTAssertEqual(second.slug, "Jane-Doe-2")
        XCTAssertNotEqual(first.id, second.id)

        let all = try store.listPatients()
        XCTAssertEqual(all.count, 2)
    }

    func testPatientsAreListedAlphabetically() throws {
        _ = try store.createPatient(name: "Zoe")
        _ = try store.createPatient(name: "Amir")
        let names = try store.listPatients().map(\.name)
        XCTAssertEqual(names, ["Amir", "Zoe"])
    }

    func testCreateSessionUsesDateFolderNaming() throws {
        let patient = try store.createPatient(name: "Test Patient")
        let calendar = Calendar(identifier: .gregorian)
        let date = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 14))!

        let session = try store.createSession(for: patient, on: date)
        XCTAssertEqual(session.folderName, "2026-09-16_Session")
    }

    func testSecondSessionOnSameDayGetsSuffixedFolder() throws {
        let patient = try store.createPatient(name: "Test Patient")
        let date = Date()

        let first = try store.createSession(for: patient, on: date)
        let second = try store.createSession(for: patient, on: date)

        XCTAssertEqual(first.folderName.hasSuffix("_Session"), true)
        XCTAssertTrue(second.folderName.hasSuffix("_Session-2"))
        XCTAssertNotEqual(first.folderName, second.folderName)
    }

    func testSessionIdIsStableAcrossReloads() throws {
        let patient = try store.createPatient(name: "Test Patient")
        let created = try store.createSession(for: patient)

        let firstList = try store.listSessions(for: patient)
        let secondList = try store.listSessions(for: patient)

        XCTAssertEqual(firstList.first?.id, created.id)
        XCTAssertEqual(firstList.first?.id, secondList.first?.id)
    }

    func testTranscriptAndSummaryRoundTrip() throws {
        let patient = try store.createPatient(name: "Test Patient")
        let session = try store.createSession(for: patient)

        XCTAssertNil(store.transcript(for: patient, session: session))

        try store.saveTranscript("Hello world.", for: patient, session: session)
        XCTAssertEqual(store.transcript(for: patient, session: session), "Hello world.")

        try store.saveSummary("A brief summary.", for: patient, session: session)
        XCTAssertEqual(store.summary(for: patient, session: session), "A brief summary.")

        let reloaded = try store.listSessions(for: patient).first
        XCTAssertEqual(reloaded?.hasTranscript, true)
        XCTAssertEqual(reloaded?.hasSummary, true)
    }

    func testSlugStripsPunctuationAndCollapsesSeparators() throws {
        let patient = try store.createPatient(name: "O'Brien,  Mary-Kate")
        XCTAssertEqual(patient.slug, "O-Brien-Mary-Kate")
    }

    func testBlankPatientNameStillGetsAUsableSlug() throws {
        let patient = try store.createPatient(name: "   ")
        XCTAssertEqual(patient.slug, "Patient")
    }

    func testHasRecordingReflectsEitherAudioFile() throws {
        let patient = try store.createPatient(name: "Test Patient")
        let session = try store.createSession(for: patient)

        XCTAssertEqual(try store.listSessions(for: patient).first?.hasRecording, false)

        // Only the mic track present should still count as "has recording".
        try Data("fake audio".utf8).write(to: store.micRecordingURL(for: patient, session: session))
        XCTAssertEqual(try store.listSessions(for: patient).first?.hasRecording, true)
    }

    func testGatherPatientContextOrdersNewestFirstAndSkipsEmptyTranscripts() throws {
        let patient = try store.createPatient(name: "Test Patient")
        let calendar = Calendar(identifier: .gregorian)
        let earlier = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1))!
        let later = calendar.date(from: DateComponents(year: 2026, month: 6, day: 1))!

        let earlierSession = try store.createSession(for: patient, on: earlier)
        try store.saveTranscript("First session content.", for: patient, session: earlierSession)

        // No transcript saved for this one — should be skipped entirely.
        _ = try store.createSession(for: patient, on: calendar.date(from: DateComponents(year: 2026, month: 3, day: 1))!)

        let laterSession = try store.createSession(for: patient, on: later)
        try store.saveTranscript("Second session content.", for: patient, session: laterSession)

        let context = try store.gatherPatientContext(for: patient)
        let firstRange = context.range(of: "Second session content.")
        let secondRange = context.range(of: "First session content.")

        XCTAssertNotNil(firstRange)
        XCTAssertNotNil(secondRange)
        XCTAssertLessThan(firstRange!.lowerBound, secondRange!.lowerBound, "newest transcript should appear first")
        XCTAssertFalse(context.contains("March"), "the session with no transcript shouldn't contribute a header at all")
    }

    func testChatHistoryRoundTrips() throws {
        let patient = try store.createPatient(name: "Test Patient")
        let session = try store.createSession(for: patient)

        XCTAssertEqual(store.loadSessionChat(for: patient, session: session), [])

        let messages = [
            ChatMessage(role: .user, text: "What did we discuss?"),
            ChatMessage(role: .assistant, text: "You discussed sleep habits."),
        ]
        try store.saveSessionChat(messages, for: patient, session: session)

        let reloaded = store.loadSessionChat(for: patient, session: session)
        // Compare role/text rather than full equality: JSON round-tripping
        // a Date through ISO8601 only preserves millisecond precision, so
        // asserting exact Date equality here would be testing formatter
        // precision, not the behavior this test actually cares about.
        let describe = { (list: [ChatMessage]) in list.map { "\($0.role.rawValue)|\($0.text)" } }
        XCTAssertEqual(describe(reloaded), describe(messages))
    }
}
