import AletheiaCore
import XCTest
@testable import Aletheia

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

    /// A `chat.json` from a build before the SQLite offload is imported into the
    /// DB on first load and the file is retired.
    func testLegacySessionChatFileMigratesToDatabase() throws {
        let patient = try store.createPatient(name: "Legacy Chat")
        let session = try store.createSession(for: patient)

        let legacyFile = store.sessionDir(for: patient, session: session).appendingPathComponent("chat.json")
        let messages = [
            ChatMessage(role: .user, text: "legacy question"),
            ChatMessage(role: .assistant, text: "legacy answer"),
        ]
        try JSONEncoder.aletheia.encode(messages).write(to: legacyFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyFile.path))

        let loaded = store.loadSessionChat(for: patient, session: session)
        XCTAssertEqual(loaded.map(\.text), ["legacy question", "legacy answer"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path), "legacy chat.json should be removed after import")
    }

    // MARK: - Stable opaque identity (issue #64)

    func testSessionIdentityIsPersistedNotDerivedFromFolder() throws {
        let patient = try store.createPatient(name: "Persisted ID")
        let session = try store.createSession(for: patient)

        // The identity lives in session.json, written at creation.
        let metaURL = store.sessionDir(for: patient, session: session).appendingPathComponent("session.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: metaURL.path), "createSession persists session.json")

        // Re-listing yields the same id (read back from disk, not re-derived).
        let relisted = try XCTUnwrap(try store.listSessions(for: patient).first)
        XCTAssertEqual(relisted.id, session.id)
    }

    /// The heart of #64: annotations key on the session's persisted UUID, so
    /// renaming/moving the folder (even to a name that breaks the "…_Session"
    /// convention) keeps a session's chat, notes, and comments attached.
    func testAnnotationsFollowSessionAcrossFolderRename() throws {
        let patient = try store.createPatient(name: "Mover")
        let session = try store.createSession(for: patient)

        let messages = [
            ChatMessage(role: .user, text: "before the move"),
            ChatMessage(role: .assistant, text: "still attached after"),
        ]
        try store.saveSessionChat(messages, for: patient, session: session)
        // Notes/comments go through the same SQLite file the Store owns.
        let comments = try XCTUnwrap(CommentStore(root: tempRoot))
        comments.saveNote(sessionID: session.id, text: "kept note")
        _ = comments.addComment(sessionID: session.id, quotedText: "q", body: "kept comment")

        // Rename the folder on disk to a non-conventional name.
        let oldDir = store.sessionDir(for: patient, session: session)
        let newDir = store.patientDir(for: patient).appendingPathComponent("Renamed Folder", isDirectory: true)
        try FileManager.default.moveItem(at: oldDir, to: newDir)

        let relisted = try XCTUnwrap(try store.listSessions(for: patient).first)
        XCTAssertEqual(relisted.id, session.id, "the session keeps its id across a folder rename")
        XCTAssertEqual(relisted.folderName, "Renamed Folder")

        XCTAssertEqual(store.loadSessionChat(for: patient, session: relisted).map(\.text), messages.map(\.text))
        XCTAssertEqual(comments.note(sessionID: relisted.id), "kept note")
        XCTAssertEqual(comments.comments(sessionID: relisted.id).map(\.body), ["kept comment"])
    }

    /// A folder created without a session.json (dropped in by hand, or from
    /// before this scheme) is minted a stable id on first listing and keeps it.
    func testFolderWithoutMetadataIsMintedStableID() throws {
        let patient = try store.createPatient(name: "Hand Made")
        let folder = store.patientDir(for: patient).appendingPathComponent("2026-05-01_Session", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let first = try XCTUnwrap(try store.listSessions(for: patient).first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("session.json").path),
                      "listing mints and persists an id for a metadata-less folder")

        let second = try XCTUnwrap(try store.listSessions(for: patient).first)
        XCTAssertEqual(first.id, second.id, "the minted id is stable on subsequent listings")
    }
}
