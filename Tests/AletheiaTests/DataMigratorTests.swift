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

    /// Every PHI file and database row under `root` is either its original
    /// plaintext or a sealed envelope that opens, with `key`, to the original.
    /// Never a partial or unreadable mix.
    private func assertEveryItemIsOriginalOrSealed(
        _ patient: Patient, _ session: SessionRecord, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let store = Store(root: root)
        let dir = store.sessionDir(for: patient, session: session)
        let protector = keyed
        for (name, expected) in [("transcript.txt", "hello transcript"), ("summary.txt", "a short summary")] {
            let raw = try Data(contentsOf: dir.appendingPathComponent(name))
            if DataCipher.isEnvelope(raw) {
                XCTAssertEqual(String(decoding: try protector.open(raw), as: UTF8.self), expected, file: file, line: line)
            } else {
                XCTAssertEqual(String(decoding: raw, as: UTF8.self), expected, file: file, line: line)
            }
        }
    }

    /// Locking drops the key while the pass is running. Items it had not reached
    /// stay as they were, items it had reached are sealed, and the pass reports
    /// what it could not do instead of writing anything readable-but-wrong.
    func testLockBeforeEnableLeavesEverythingUntouchedAndReportsFailures() throws {
        let (patient, session, audioBytes) = try seedPlaintextFolder()
        let store = Store(root: root)
        let micURL = store.micRecordingURL(for: patient, session: session)
        let dbURL = CommentStore.databaseURL(root: root)
        let dbBefore = try Data(contentsOf: dbURL)

        let protectionKey = ProtectionKey(key)
        protectionKey.revoke()
        let revoked = FileProtector(keyReference: protectionKey, requiresKey: true)
        let result = DataMigrator.migrate(root: root, from: .passthrough, to: revoked)

        XCTAssertFalse(result.isComplete, "a revoked key must fail the pass, not skip it silently")
        XCTAssertFalse(result.failures.isEmpty)
        XCTAssertEqual(Store(root: root).transcript(for: patient, session: session), "hello transcript")
        XCTAssertEqual(try Data(contentsOf: micURL), audioBytes)
        XCTAssertEqual(try Data(contentsOf: dbURL), dbBefore, "the database is not rewritten")
        let comments = try XCTUnwrap(CommentStore(root: root))
        XCTAssertEqual(comments.note(sessionID: session.id), "private note")

        // The pass is safe to re-run once the folder is unlocked again.
        let rerun = DataMigrator.migrate(root: root, from: .passthrough, to: keyed)
        XCTAssertTrue(rerun.isComplete)
        XCTAssertTrue(DataCipher.isEnvelope(try Data(contentsOf:
            store.sessionDir(for: patient, session: session).appendingPathComponent("transcript.txt"))))
    }

    /// Locks on an exact key read (the k-th), so where the lock lands is fixed.
    /// k = 0 never locks; a large k lands after the last item.
    func testLockDuringEnableDoesNotLeavePlaintext() throws {
        for lockAtRead in [1, 3, 7, 20, 1_000_000] {
            try? FileManager.default.removeItem(at: root)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = Store(root: root)
            var sessions: [(Patient, SessionRecord)] = []
            for i in 0..<4 {
                let patient = try store.createPatient(name: "Patient \(i)")
                let session = try store.createSession(for: patient)
                try store.saveTranscript("hello transcript", for: patient, session: session)
                try store.saveSummary("a short summary", for: patient, session: session)
                sessions.append((patient, session))
            }
            let comments = try XCTUnwrap(CommentStore(root: root))
            XCTAssertTrue(comments.saveNote(sessionID: sessions[0].1.id, text: "private note"))

            let protectionKey = ProtectionKey(key)
            let reads = ReadCounter()
            protectionKey.onRead = { [unowned protectionKey] in
                if reads.next() == lockAtRead { protectionKey.revoke() }
            }
            let sealing = FileProtector(keyReference: protectionKey, requiresKey: true)
            let outcome = DataMigrator.migrate(root: root, from: .passthrough, to: sealing)

            for (patient, session) in sessions {
                try assertEveryItemIsOriginalOrSealed(patient, session)
            }
            if lockAtRead <= 20 {
                XCTAssertFalse(outcome.isComplete, "lock at read \(lockAtRead) must be reported")
            }
            if outcome.isComplete {
                for (patient, session) in sessions {
                    let url = store.sessionDir(for: patient, session: session).appendingPathComponent("transcript.txt")
                    XCTAssertTrue(DataCipher.isEnvelope(try Data(contentsOf: url)), "lock at read \(lockAtRead)")
                }
            }
            // Still readable with the key, sealed or not.
            let keyedStore = Store(root: root, protector: keyed)
            for (patient, session) in sessions {
                XCTAssertEqual(keyedStore.transcript(for: patient, session: session), "hello transcript", "lock at read \(lockAtRead)")
            }
            let keyedComments = try XCTUnwrap(CommentStore(root: root, protector: keyed))
            XCTAssertEqual(keyedComments.note(sessionID: sessions[0].1.id), "private note", "lock at read \(lockAtRead)")
        }
    }

    private final class ReadCounter: @unchecked Sendable {
        private var count = 0
        func next() -> Int { count += 1; return count }
    }

    func testManagerEnableSealsAndDisableRestores() throws {
        let (patient, session, _) = try seedPlaintextFolder()
        let store = Store(root: root)
        let transcriptURL = store.sessionDir(for: patient, session: session).appendingPathComponent("transcript.txt")

        let manager = EncryptionManager(dataRootProvider: { [root] in root })
        let result = try manager.enable(passphrase: "recovery phrase", iterations: 100_000)
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
        _ = try manager.enable(passphrase: "test-passphrase-1", iterations: 100_000)
        manager.lock()
        XCTAssertThrowsError(try manager.disable()) { error in
            XCTAssertEqual(error as? EncryptionManager.ManagerError, .locked)
        }
        XCTAssertTrue(Keystore.exists(at: root), "keystore is kept when disable can't run")
    }

    // MARK: pre-migration JSON bundles

    /// Plants a pre-migration JSON bundle the way `SQLitePersistenceCore` does,
    /// from the folder's current (plaintext) patient.json files.
    private func plantPreImageBundle() throws -> URL {
        let snapshot = MigrationBackup.directory(for: CommentStore.databaseURL(root: root))
            .appendingPathComponent("Aletheia-pre-v2-20240101T000000Z.sqlite")
        let bundle = MigrationBackup.filesBundleURL(forSnapshot: snapshot)
        try MigrationBackup.copyStructuredJSON(fromDataRoot: root, to: bundle)
        return bundle
    }

    func testEnablingEncryptionAlsoSealsThePreImageJSON() throws {
        _ = try seedPlaintextFolder()
        let bundle = try plantPreImageBundle()
        let copy = try XCTUnwrap(patientJSON(in: bundle))
        XCTAssertFalse(DataCipher.isEnvelope(try Data(contentsOf: copy)), "fixture should start as plaintext")

        let result = DataMigrator.migrate(root: root, from: .passthrough, to: keyed)

        XCTAssertTrue(result.isComplete)
        XCTAssertTrue(DataCipher.isEnvelope(try Data(contentsOf: copy)),
                      "a plaintext patient.json left in .backups would expose PHI beside the encrypted folder")
        let live = try XCTUnwrap(patientJSON(in: root))
        XCTAssertEqual(try keyed.data(contentsOf: copy), try keyed.data(contentsOf: live))
    }

    func testDisablingEncryptionRestoresThePreImageJSONToPlaintext() throws {
        _ = try seedPlaintextFolder()
        let bundle = try plantPreImageBundle()
        let copy = try XCTUnwrap(patientJSON(in: bundle))
        let original = try Data(contentsOf: copy)

        DataMigrator.migrate(root: root, from: .passthrough, to: keyed)
        let disable = DataMigrator.migrate(root: root, from: keyed, to: .passthrough)

        XCTAssertTrue(disable.isComplete)
        XCTAssertEqual(try Data(contentsOf: copy), original,
                       "removing the key must not strand a sealed pre-image that can no longer be restored")
    }

    func testMigratingWithoutAPreImageIsUnaffected() throws {
        _ = try seedPlaintextFolder()
        XCTAssertTrue(MigrationBackup.fileBundles(inDataRoot: root).isEmpty)
        XCTAssertTrue(DataMigrator.migrate(root: root, from: .passthrough, to: keyed).isComplete)
    }

    private func patientJSON(in base: URL) -> URL? {
        let patients = base.appendingPathComponent("Patients", isDirectory: true)
        let dirs = (try? FileManager.default.contentsOfDirectory(at: patients, includingPropertiesForKeys: nil)) ?? []
        return dirs.map { $0.appendingPathComponent("patient.json") }
            .first { FileManager.default.fileExists(atPath: $0.path) }
    }

    // MARK: older plaintext database copies

    func testEnableRemovesOlderPlaintextSnapshots() throws {
        _ = try seedPlaintextFolder()
        let comments = try XCTUnwrap(CommentStore(root: root))
        let snapshot = try XCTUnwrap(DatabaseSnapshotManager(root: root).makeSnapshot(of: comments, reason: "manual"))
        let migrationsDir = BackupLayout.directory(.migrations, dataRoot: root)
        try FileManager.default.createDirectory(at: migrationsDir, withIntermediateDirectories: true)
        let migrationCopy = migrationsDir.appendingPathComponent("Aletheia-pre-v2-20240101T000000Z.sqlite")
        XCTAssertTrue(comments.snapshot(to: migrationCopy))
        XCTAssertTrue(FileManager.default.fileExists(atPath: snapshot.path))

        let manager = EncryptionManager(dataRootProvider: { [root] in root }, defaults: UserDefaults(suiteName: "DataMigratorTests-\(UUID().uuidString)")!)
        let result = try manager.enable(passphrase: "test-passphrase-1", iterations: 100_000)

        XCTAssertTrue(result.isComplete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: snapshot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: migrationCopy.path))
        XCTAssertTrue(DatabaseSnapshotManager(root: root).snapshots().isEmpty)
    }
}
