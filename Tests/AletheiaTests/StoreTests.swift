import CryptoKit
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
        XCTAssertEqual(patient.slug, patient.id.uuidString)

        let reloaded = try store.listPatients()
        XCTAssertEqual(reloaded.map(\.id), [patient.id])
        XCTAssertEqual(reloaded.first?.name, "Jane Doe")
    }

    func testDuplicatePatientNameGetsDistinctUUIDFolders() throws {
        let first = try store.createPatient(name: "Jane Doe")
        let second = try store.createPatient(name: "Jane Doe")

        XCTAssertEqual(first.slug, first.id.uuidString)
        XCTAssertEqual(second.slug, second.id.uuidString)
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

    /// A new session's folder appears with its identity file already inside, so
    /// a listing running at the same moment can't give it a second id.
    func testNewSessionFolderAppearsWithItsIdentityAndLeavesNothingBehind() throws {
        let patient = try store.createPatient(name: "Test Patient")
        let created = try store.createSession(for: patient)
        let folder = store.sessionDir(for: patient, session: created)

        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("session.json").path))
        let siblings = try FileManager.default.contentsOfDirectory(atPath: folder.deletingLastPathComponent().path)
        XCTAssertFalse(siblings.contains { $0.hasPrefix(".new-session-") }, "\(siblings)")
    }

    func testAHalfCreatedSessionFolderIsNotListed() throws {
        let patient = try store.createPatient(name: "Test Patient")
        let created = try store.createSession(for: patient)
        let patientDir = store.sessionDir(for: patient, session: created).deletingLastPathComponent()
        let staged = patientDir.appendingPathComponent(".new-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: store.sessionDir(for: patient, session: created).appendingPathComponent("session.json"),
            to: staged.appendingPathComponent("session.json"))

        XCTAssertEqual(try store.listSessions(for: patient).map(\.id), [created.id])
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

    func testPatientNameDoesNotAppearInFolder() throws {
        let patient = try store.createPatient(name: "O'Brien,  Mary-Kate")
        XCTAssertEqual(patient.slug, patient.id.uuidString)
        XCTAssertFalse(patient.slug.contains("Mary"))
    }

    func testBlankPatientNameIsRefusedAndASymbolOnlyNameGetsAUsableFolder() throws {
        XCTAssertThrowsError(try store.createPatient(name: "   "))
        XCTAssertTrue(try store.listPatients().isEmpty)
        let patient = try store.createPatient(name: "???")
        XCTAssertEqual(patient.slug, patient.id.uuidString)
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

    func testDeletePatientRemovesFolderAndRecordsAndCreatesSnapshot() throws {
        let patient = try store.createPatient(name: "Deletable Patient")
        let session = try store.createSession(for: patient)

        // Add comments, notes, session chats, and chat threads
        let commentStore = try XCTUnwrap(CommentStore(root: tempRoot))
        commentStore.saveNote(sessionID: session.id, text: "Some notes")
        _ = commentStore.addComment(sessionID: session.id, quotedText: "quote", body: "A comment")
        commentStore.saveChatThread(ChatThread(title: "Thread 1", messages: [ChatMessage(role: .user, text: "Hello")]), patientID: patient.id)
        commentStore.saveSessionChat([ChatMessage(role: .assistant, text: "Session chat")], sessionID: session.id)

        let patientDir = store.patientDir(for: patient)
        XCTAssertTrue(FileManager.default.fileExists(atPath: patientDir.path))

        // Perform deletion
        try store.deletePatient(patient)

        // 1. Patient folder is deleted
        XCTAssertFalse(FileManager.default.fileExists(atPath: patientDir.path))
        XCTAssertFalse(try store.listPatients().contains(where: { $0.id == patient.id }))

        // 2. Database records are purged
        XCTAssertEqual(commentStore.note(sessionID: session.id), "")
        XCTAssertTrue(commentStore.comments(sessionID: session.id).isEmpty)
        XCTAssertTrue(commentStore.chatThreads(patientID: patient.id).isEmpty)
        XCTAssertTrue(commentStore.sessionChat(sessionID: session.id).isEmpty)

        // 3. Pre-delete snapshot was taken in .backups/snapshots
        let snapshotDir = BackupLayout.directory(.snapshots, dataRoot: tempRoot)
        let snapshots = (try? FileManager.default.contentsOfDirectory(at: snapshotDir, includingPropertiesForKeys: nil)) ?? []
        XCTAssertTrue(snapshots.contains(where: { $0.lastPathComponent.contains("pre-delete-patient") }))

        // 4. Repeated deletion throws patientNotFound
        XCTAssertThrowsError(try store.deletePatient(patient)) { error in
            guard case StoreError.patientNotFound = error else {
                XCTFail("Expected patientNotFound, got \(error)")
                return
            }
        }
    }

    func testFastSessionMeta() throws {
        let patient = try store.createPatient(name: "Fast Meta")
        // Initially 0 sessions
        let meta0 = store.fastSessionMeta(for: patient)
        XCTAssertEqual(meta0.count, 0)
        XCTAssertNil(meta0.newestDate)

        // Create two sessions
        let calendar = Calendar(identifier: .gregorian)
        let date1 = calendar.date(from: DateComponents(year: 2026, month: 9, day: 16))!
        let date2 = calendar.date(from: DateComponents(year: 2026, month: 10, day: 1))!
        _ = try store.createSession(for: patient, on: date1)
        _ = try store.createSession(for: patient, on: date2)

        let meta2 = store.fastSessionMeta(for: patient)
        XCTAssertEqual(meta2.count, 2)
        XCTAssertEqual(meta2.newestDate, date2)
    }

    // MARK: - Unreadable notes and traversal

    /// A store over the same folder whose key can't open what `store` sealed.
    private func sealedNote(_ text: String) throws -> (Store, Patient, SessionRecord, URL) {
        let writer = Store(root: tempRoot, protector: FileProtector(key: SymmetricKey(size: .bits256)))
        let patient = try writer.createPatient(name: "Sealed Case")
        let session = try writer.createSession(for: patient)
        try writer.saveNote(text, for: patient, session: session, format: .soap)
        let reader = Store(root: tempRoot, protector: FileProtector(key: SymmetricKey(size: .bits256)))
        let url = reader.sessionDir(for: patient, session: session).appendingPathComponent(Store.noteFileName(for: .soap))
        return (reader, patient, session, url)
    }

    func testNoteEditStateReportsUnreadable() throws {
        let (reader, patient, session, _) = try sealedNote("edited by hand")
        XCTAssertEqual(reader.noteEditState(for: patient, session: session, format: .soap), .unreadable)
    }

    func testSaveGeneratedNoteThrowsWhenExistingNoteUnreadable() throws {
        let (reader, patient, session, url) = try sealedNote("edited by hand")
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try reader.saveGeneratedNote("new text", for: patient, session: session, format: .soap))
        XCTAssertEqual(try Data(contentsOf: url), before, "the unreadable note is byte-identical")
        let previous = reader.sessionDir(for: patient, session: session)
            .appendingPathComponent(Store.noteSidecarFileName(for: .soap, .previous))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previous.path))
    }

    func testRestorePreviousNoteDoesNotOverwriteUnreadable() throws {
        let keyed = Store(root: tempRoot, protector: FileProtector(key: SymmetricKey(size: .bits256)))
        let patient = try keyed.createPatient(name: "Sealed Case")
        let session = try keyed.createSession(for: patient)
        try keyed.saveGeneratedNote("v1", for: patient, session: session, format: .soap)
        try keyed.saveEditedNote("hand edit", for: patient, session: session, format: .soap)
        try keyed.saveGeneratedNote("v2", for: patient, session: session, format: .soap)
        XCTAssertEqual(keyed.previousNote(for: patient, session: session, format: .soap), "hand edit")
        // The note file is replaced by one sealed under another key, so `keyed` can't read it.
        let foreign = Store(root: tempRoot, protector: FileProtector(key: SymmetricKey(size: .bits256)))
        try foreign.saveNote("foreign", for: patient, session: session, format: .soap)
        let url = keyed.sessionDir(for: patient, session: session).appendingPathComponent(Store.noteFileName(for: .soap))
        let before = try Data(contentsOf: url)

        XCTAssertThrowsError(try keyed.restorePreviousNote(for: patient, session: session, format: .soap))
        XCTAssertEqual(try Data(contentsOf: url), before)
        XCTAssertEqual(keyed.previousNote(for: patient, session: session, format: .soap), "hand edit")
    }

    func testUndecodableRecordIsReportedNotDropped() throws {
        let comments = try XCTUnwrap(CommentStore(root: tempRoot))
        let sessionID = UUID()
        let core = try SQLitePersistenceCore(opening: CommentStore.databaseURL(root: tempRoot))
        XCTAssertTrue(core.put(PersistedRecord(
            id: sessionID.uuidString, kind: "note", itemID: sessionID,
            payload: Data("not json".utf8), createdAt: Date(), updatedAt: Date())))
        let reporting = Store(root: tempRoot, commentStore: comments)
        XCTAssertTrue(reporting.unreadableEntries.isEmpty)

        XCTAssertEqual(comments.note(sessionID: sessionID), "")
        XCTAssertEqual(reporting.unreadableEntries.map(\.kind), [.storedRecord])
        XCTAssertNotNil(core.record(kind: "note", id: sessionID.uuidString), "the record is left in place")
    }

    func testUndecodableLegacyChatIsReportedAndKept() throws {
        let patient = try store.createPatient(name: "Chat Case")
        let session = try store.createSession(for: patient)
        let file = store.sessionDir(for: patient, session: session).appendingPathComponent("chat.json")
        try Data("{ broken".utf8).write(to: file)
        _ = store.loadSessionChat(for: patient, session: session)
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "an unreadable chat file isn't retired")
        XCTAssertEqual(store.unreadableEntries.map(\.kind), [.storedRecord])
    }

    func testLoadSessionRejectsTraversal() throws {
        let patient = try store.createPatient(name: "Jane Doe")
        let other = try store.createPatient(name: "John Roe")
        let otherSession = try store.createSession(for: other)
        for name in ["../\(other.slug)/\(otherSession.folderName)", "..", ".", "", "a/b", "/etc"] {
            XCTAssertThrowsError(try store.loadSession(for: patient, folderName: name), name)
        }
    }
}
