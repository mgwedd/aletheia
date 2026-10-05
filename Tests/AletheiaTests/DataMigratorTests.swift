import CryptoKit
import XCTest
@testable import Aletheia

final class DataMigratorTests: XCTestCase {
    private var root: URL!
    private let key = SymmetricKey(size: .bits256)
    private var keyed: FileProtector { FileProtector(key: key) }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DataMigratorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// Populates a plaintext folder and returns the patient/session plus the fake
    /// audio bytes written, so a round-trip can assert they come back intact.
    private func seedPlaintextFolder() throws -> (Patient, SessionRecord, Data) {
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Dana Cole")
        let session = try store.createSession(for: patient)
        try store.saveTranscript("hello transcript", for: patient, session: session)
        try store.saveSummary("a short summary", for: patient, session: session)

        let audioBytes = Data((0..<3000).map { _ in UInt8.random(in: 0...255) })
        try audioBytes.write(to: store.micRecordingURL(for: patient, session: session))

        let comments = try XCTUnwrap(CommentStore(root: root))
        comments.saveNote(sessionID: session.id, text: "private note")
        _ = comments.addComment(sessionID: session.id,
                                quotedText: "felt stuck", body: "revisit goals")
        return (patient, session, audioBytes)
    }

    func testEnableThenDisableRoundTripsAllPHI() throws {
        let (patient, session, audioBytes) = try seedPlaintextFolder()
        let store = Store(root: root)
        let transcriptURL = store.sessionDir(for: patient, session: session).appendingPathComponent("transcript.txt")
        let micURL = store.micRecordingURL(for: patient, session: session)

        // Enable: plaintext → sealed.
        let enable = DataMigrator.migrate(root: root, from: .passthrough, to: keyed)
        XCTAssertTrue(enable.isComplete, "no items should fail to seal")
        XCTAssertTrue(DataCipher.isEnvelope(try Data(contentsOf: transcriptURL)))
        XCTAssertTrue(ChunkedCipher.isEnvelope(fileAt: micURL))

        // Readable under the key.
        let keyedStore = Store(root: root, protector: keyed)
        XCTAssertEqual(keyedStore.transcript(for: patient, session: session), "hello transcript")
        XCTAssertEqual(keyedStore.summary(for: patient, session: session), "a short summary")
        XCTAssertEqual(try keyedStore.listPatients().map(\.name), ["Dana Cole"])
        let keyedComments = try XCTUnwrap(CommentStore(root: root, protector: keyed))
        XCTAssertEqual(keyedComments.note(sessionID: session.id), "private note")

        // Disable: sealed → plaintext, everything restored byte-for-byte.
        let disable = DataMigrator.migrate(root: root, from: keyed, to: .passthrough)
        XCTAssertTrue(disable.isComplete)
        XCTAssertFalse(DataCipher.isEnvelope(try Data(contentsOf: transcriptURL)))
        XCTAssertFalse(ChunkedCipher.isEnvelope(fileAt: micURL))
        XCTAssertEqual(try Data(contentsOf: micURL), audioBytes, "audio survives the round trip")

        let plainStore = Store(root: root)
        XCTAssertEqual(plainStore.transcript(for: patient, session: session), "hello transcript")
        let plainComments = try XCTUnwrap(CommentStore(root: root))
        XCTAssertEqual(plainComments.note(sessionID: session.id), "private note")
        XCTAssertEqual(plainComments.comments(sessionID: session.id).first?.body, "revisit goals")
    }

    /// The safety snapshot taken before a bulk rewrite is sealed under the
    /// *source* protector, so enabling encryption used to leave a plaintext copy
    /// of every note/comment/chat in `.backups/snapshots/` for good. Once the live DB is
    /// converted, that copy must not linger.
    func testEnableDoesNotLeavePlaintextPreImageBehind() throws {
        let (_, session, _) = try seedPlaintextFolder()

        let enable = DataMigrator.migrate(root: root, from: .passthrough, to: keyed)
        XCTAssertTrue(enable.isComplete)

        let leftovers = DatabaseSnapshotManager(root: root).snapshots()
        XCTAssertTrue(leftovers.isEmpty, "no plaintext pre-image should survive a successful enable")

        // The live DB was converted and is readable under the key.
        let keyedComments = try XCTUnwrap(CommentStore(root: root, protector: keyed))
        XCTAssertEqual(keyedComments.note(sessionID: session.id), "private note")
    }

    /// `Store.createSession` names a second session on the same day
    /// `<date>_Session-2`. The migrator once matched only the `_Session` suffix,
    /// so those folders were never sealed on enable and — the dangerous half —
    /// never decrypted on disable, which then deleted the keystore and left their
    /// transcripts unreadable forever.
    func testSameDaySecondSessionIsConvertedBothWays() throws {
        let store = Store(root: root)
        let patient = try store.createPatient(name: "Dana Cole")
        let day = Date()
        let first = try store.createSession(for: patient, on: day)
        let second = try store.createSession(for: patient, on: day)
        XCTAssertTrue(second.folderName.hasSuffix("_Session-2"), "precondition: collision-suffixed folder")
        try store.saveTranscript("first transcript", for: patient, session: first)
        try store.saveTranscript("second transcript", for: patient, session: second)
        let secondURL = store.sessionDir(for: patient, session: second).appendingPathComponent("transcript.txt")

        let enable = DataMigrator.migrate(root: root, from: .passthrough, to: keyed)
        XCTAssertTrue(enable.isComplete)
        XCTAssertTrue(DataCipher.isEnvelope(try Data(contentsOf: secondURL)), "second same-day session is sealed on enable")

        let disable = DataMigrator.migrate(root: root, from: keyed, to: .passthrough)
        XCTAssertTrue(disable.isComplete)
        XCTAssertFalse(DataCipher.isEnvelope(try Data(contentsOf: secondURL)), "and decrypted on disable")
        XCTAssertEqual(Store(root: root).transcript(for: patient, session: second), "second transcript")
        XCTAssertEqual(Store(root: root).transcript(for: patient, session: first), "first transcript")
    }

    func testIsSessionFolderRecognisesSuffixedNamesAndSessionJSON() throws {
        let fm = FileManager.default
        func makeDir(_ name: String, sessionJSON: Bool = false) throws -> URL {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if sessionJSON { try Data("{}".utf8).write(to: dir.appendingPathComponent("session.json")) }
            return dir
        }
        let plain = try makeDir("2026-01-05_Session")
        let suffixed = try makeDir("2026-01-05_Session-2")
        let renamed = try makeDir("renamed-by-user", sessionJSON: true)
        let chatThreads = try makeDir("ChatThreads")
        XCTAssertTrue(DataMigrator.isSessionFolder(plain))
        XCTAssertTrue(DataMigrator.isSessionFolder(suffixed))
        XCTAssertTrue(DataMigrator.isSessionFolder(renamed))
        XCTAssertFalse(DataMigrator.isSessionFolder(chatThreads))
        // A plain file is never a session folder, even if it has a matching name.
        let file = root.appendingPathComponent("2026-01-05_Session-9")
        try Data("x".utf8).write(to: file)
        XCTAssertFalse(DataMigrator.isSessionFolder(file))
    }

    func testManagerEnableSealsAndDisableRestores() throws {
        let (patient, session, _) = try seedPlaintextFolder()
        let store = Store(root: root)
        let transcriptURL = store.sessionDir(for: patient, session: session).appendingPathComponent("transcript.txt")

        let manager = EncryptionManager(dataRootProvider: { [root] in root })
        let result = try manager.enable(passphrase: "recovery phrase", iterations: 1_000)
        XCTAssertTrue(result.isComplete)
        XCTAssertEqual(manager.state, .unlocked)
        XCTAssertTrue(DataCipher.isEnvelope(try Data(contentsOf: transcriptURL)), "existing transcript is sealed on enable")

        try manager.disable()
        XCTAssertEqual(manager.state, .disabled)
        XCTAssertFalse(Keystore.exists(at: root))
        XCTAssertFalse(DataCipher.isEnvelope(try Data(contentsOf: transcriptURL)), "transcript is plaintext again after disable")
    }

    func testDisableWhileLockedThrows() throws {
        _ = try seedPlaintextFolder()
        let manager = EncryptionManager(dataRootProvider: { [root] in root })
        _ = try manager.enable(passphrase: "pw", iterations: 1_000)
        manager.lock()
        XCTAssertThrowsError(try manager.disable()) { error in
            XCTAssertEqual(error as? EncryptionManager.ManagerError, .locked)
        }
        XCTAssertTrue(Keystore.exists(at: root), "keystore is kept when disable can't run")
    }
}
