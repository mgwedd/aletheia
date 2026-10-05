import CryptoKit
import XCTest
@testable import Aletheia

/// Proves the wiring: with a keyed `FileProtector`, `Store` and `CommentStore`
/// write ciphertext at rest yet round-trip plaintext, and a passthrough reader
/// (encryption off / locked) cannot recover the content — while legacy
/// plaintext written before encryption stays readable.
final class EncryptedStoreTests: XCTestCase {
    private var tempRoot: URL!
    private let key = SymmetricKey(size: .bits256)
    private var keyed: FileProtector { FileProtector(key: key) }

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("EncryptedStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    // MARK: - Store (files)

    func testTranscriptIsSealedOnDiskButRoundTrips() throws {
        let store = Store(root: tempRoot, protector: keyed)
        let patient = try store.createPatient(name: "Alex Doe")
        let session = try store.createSession(for: patient)
        let text = "[00:00] Therapist: How was your week?"
        try store.saveTranscript(text, for: patient, session: session)

        // On disk: an envelope, not the plaintext.
        let url = store.sessionDir(for: patient, session: session).appendingPathComponent("transcript.txt")
        let onDisk = try Data(contentsOf: url)
        XCTAssertTrue(DataCipher.isEnvelope(onDisk))
        XCTAssertNil(onDisk.range(of: Data("How was your week".utf8)), "plaintext must not appear on disk")

        // Read back through the keyed store.
        XCTAssertEqual(store.transcript(for: patient, session: session), text)
    }

    func testPatientJSONIsSealedButListsBack() throws {
        let store = Store(root: tempRoot, protector: keyed)
        _ = try store.createPatient(name: "Jordan Rivera")

        let file = tempRoot.appendingPathComponent("Patients/Jordan-Rivera/patient.json")
        let onDisk = try Data(contentsOf: file)
        XCTAssertTrue(DataCipher.isEnvelope(onDisk))
        XCTAssertNil(onDisk.range(of: Data("Jordan".utf8)), "the patient name must not be readable on disk")

        let listed = try store.listPatients()
        XCTAssertEqual(listed.map(\.name), ["Jordan Rivera"])
    }

    func testLockedStoreCannotReadEncryptedTranscript() throws {
        let keyedStore = Store(root: tempRoot, protector: keyed)
        let patient = try keyedStore.createPatient(name: "Sam")
        let session = try keyedStore.createSession(for: patient)
        try keyedStore.saveTranscript("secret notes", for: patient, session: session)

        // A passthrough store models the folder while locked / encryption off:
        // it must not surface the plaintext (the read throws, so transcript→nil).
        let lockedStore = Store(root: tempRoot, protector: .passthrough)
        XCTAssertNil(lockedStore.transcript(for: patient, session: session))
    }

    func testLegacyPlaintextStaysReadableUnderKey() throws {
        // Write with encryption off, then read with a key held (mid-migration).
        let plainStore = Store(root: tempRoot, protector: .passthrough)
        let patient = try plainStore.createPatient(name: "Casey")
        let session = try plainStore.createSession(for: patient)
        try plainStore.saveTranscript("older plaintext transcript", for: patient, session: session)

        let keyedStore = Store(root: tempRoot, protector: keyed)
        XCTAssertEqual(keyedStore.transcript(for: patient, session: session), "older plaintext transcript")
    }

    // MARK: - CommentStore (database)

    func testCommentColumnsAreEncryptedAtRest() throws {
        let store = try XCTUnwrap(CommentStore(root: tempRoot, protector: keyed))
        let session = UUID()
        _ = store.addComment(sessionID: session,
                             quotedText: "felt anxious", body: "explore triggers next time")
        XCTAssertEqual(store.note(sessionID: session), "")
        store.saveNote(sessionID: session, text: "private note body")

        // Keyed reader recovers plaintext.
        let comment = try XCTUnwrap(store.comments(sessionID: session).first)
        XCTAssertEqual(comment.quotedText, "felt anxious")
        XCTAssertEqual(comment.body, "explore triggers next time")
        XCTAssertEqual(store.note(sessionID: session), "private note body")

        // A passthrough reader over the same DB cannot recover the plaintext.
        let locked = try XCTUnwrap(CommentStore(root: tempRoot, protector: .passthrough))
        let lockedComment = try XCTUnwrap(locked.comments(sessionID: session).first)
        XCTAssertNotEqual(lockedComment.body, "explore triggers next time")
        XCTAssertNotEqual(locked.note(sessionID: session), "private note body")
    }

    func testLegacyPlaintextCommentsStayReadableUnderKey() throws {
        let session = UUID()
        let plain = try XCTUnwrap(CommentStore(root: tempRoot, protector: .passthrough))
        plain.saveNote(sessionID: session, text: "written before encryption")

        let keyedReader = try XCTUnwrap(CommentStore(root: tempRoot, protector: keyed))
        XCTAssertEqual(keyedReader.note(sessionID: session), "written before encryption")
    }
}
