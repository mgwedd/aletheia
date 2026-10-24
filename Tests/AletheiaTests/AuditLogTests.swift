import CryptoKit
import XCTest
@testable import Aletheia

/// The audit log is the HIPAA §164.312(b) "record and examine" control: an append-only,
/// tamper-evident ledger with HMAC hash-chaining and user identity.
final class AuditLogTests: XCTestCase {
    private var root: URL!
    private var testKey: SymmetricKey!
    private var log: AuditLog!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        testKey = SymmetricKey(size: .bits256)
        log = AuditLog(root: root, keyProvider: { [weak self] in self?.testKey })
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testUpdateAndDeleteAreRejectedByTrigger() throws {
        try log.record(.appUnlocked, detail: "initial")
        XCTAssertEqual(log.entries().count, 1)

        // Attempting to UPDATE any row in audit_events must be aborted by trigger
        XCTAssertThrowsError(
            try log.core?.executeRaw("UPDATE audit_events SET detail = 'tampered' WHERE seq = 1;")
        ) { error in
            let desc = String(describing: error)
            XCTAssertTrue(desc.contains("audit log is append-only"), "Expected trigger abort message, got: \(desc)")
        }

        // Attempting to DELETE any row in audit_events must be aborted by trigger
        XCTAssertThrowsError(
            try log.core?.executeRaw("DELETE FROM audit_events WHERE seq = 1;")
        ) { error in
            let desc = String(describing: error)
            XCTAssertTrue(desc.contains("audit log is append-only"), "Expected trigger abort message, got: \(desc)")
        }

        // Row was not modified or deleted
        let entries = log.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.detail, "initial")
    }

    func testChainVerifiesAndDetectsTamper() throws {
        try log.record(.appUnlocked, detail: "first")
        try log.record(.phiCreated, subjectID: "patient-123", detail: "second")
        try log.record(.phiViewed, subjectID: "patient-123", detail: "third")

        // 1. Initial chain verifies cleanly
        let verified = log.verifyIntegrity()
        XCTAssertEqual(verified, .verified(count: 3))

        // 2. Simulate attacker tampering by dropping trigger and altering row 2
        try log.core?.executeRaw("DROP TRIGGER IF EXISTS audit_no_update;")
        try log.core?.executeRaw("UPDATE audit_events SET detail = 'tampered-payload' WHERE seq = 2;")

        // 3. Verification must fail at sequence 2
        let broken = log.verifyIntegrity()
        guard case let .broken(seq, _) = broken else {
            return XCTFail("Expected broken chain at seq 2, got: \(broken)")
        }
        XCTAssertEqual(seq, 2)
    }

    func testAuditWriteFailureIsSurfaced() throws {
        var states: [Bool] = []
        log.onWriteStateChanged = { states.append($0) }
        XCTAssertFalse(log.lastWriteFailed)

        try log.core?.executeRaw("CREATE TRIGGER block_insert BEFORE INSERT ON audit_events BEGIN SELECT RAISE(ABORT, 'blocked'); END;")
        XCTAssertThrowsError(try log.record(.appUnlocked))
        XCTAssertThrowsError(try log.record(.appUnlocked))
        XCTAssertTrue(log.lastWriteFailed)
        XCTAssertEqual(states, [true], "reported once when it flips, not per failed write")

        try log.core?.executeRaw("DROP TRIGGER block_insert;")
        try log.record(.appUnlocked)
        XCTAssertFalse(log.lastWriteFailed)
        XCTAssertEqual(states, [true, false])
    }

    func testUnavailableDatabaseCountsAsAFailedWrite() throws {
        let broken = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // A directory where the database file should be: it can't be opened.
        try FileManager.default.createDirectory(
            at: broken.appendingPathComponent("Aletheia.sqlite", isDirectory: true), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: broken) }
        let unavailable = AuditLog(root: broken, keyProvider: { self.testKey })
        XCTAssertThrowsError(try unavailable.record(.appUnlocked))
        XCTAssertTrue(unavailable.lastWriteFailed)
    }

    func testMissingKeyRecordsUnverifiableNotSkipped() throws {
        let keylessLog = AuditLog(root: root, keyProvider: { nil })
        let event = try keylessLog.record(.appUnlocked, detail: "key-absent")

        // Action is recorded, never skipped
        let entries = keylessLog.entries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.action, .appUnlocked)
        XCTAssertNil(event.mac)
        XCTAssertNil(entries.first?.mac)

        // Posture / verification reports unverifiable
        let status = keylessLog.verifyIntegrity()
        guard case .unverifiable = status else {
            return XCTFail("Expected unverifiable status when key is absent, got: \(status)")
        }
    }

    func testLegacyLogIsImportedOnce() throws {
        let legacyDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: legacyDir) }

        // Write legacy audit.log
        let legacyURL = legacyDir.appendingPathComponent(AuditLog.legacyFileName)
        // Lines exactly as the old text log wrote them (no actor, no seq/mac).
        let line1 = #"{"action":"appUnlocked","appVersion":"1.0","at":"2026-01-01T00:00:00Z","detail":"old1"}"# + "\n"
        let line2 = #"{"action":"recordExported","appVersion":"1.0","at":"2026-01-02T00:00:00Z","detail":"old2","subjectID":"pat-1"}"# + "\n"
        try Data((line1 + line2).utf8).write(to: legacyURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))

        // Initialize AuditLog — must import legacy rows
        let legacyLog1 = AuditLog(root: legacyDir, keyProvider: { [weak self] in self?.testKey })
        let entries = legacyLog1.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].action, .appUnlocked)
        XCTAssertEqual(entries[0].detail, "imported · old1")
        XCTAssertEqual(entries[0].at, "2026-01-01T00:00:00Z")
        XCTAssertEqual(entries[0].actor, AuditLog.unknownActor)
        XCTAssertEqual(entries[1].action, .recordExported)
        XCTAssertEqual(entries[1].detail, "imported · old2")
        XCTAssertEqual(entries[1].subjectID, "pat-1")
        XCTAssertEqual(legacyLog1.verifyIntegrity(), .verified(count: 2))

        // File renamed to audit.log.imported
        let importedURL = legacyDir.appendingPathComponent(AuditLog.legacyImportedFileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedURL.path))

        // Initializing again does not re-import or duplicate rows
        let legacyLog2 = AuditLog(root: legacyDir, keyProvider: { [weak self] in self?.testKey })
        XCTAssertEqual(legacyLog2.entries().count, 2)
    }

    func testActorIsUserAndUID() throws {
        let event = try log.record(.appUnlocked)
        let expectedActor = "\(NSUserName()):\(getuid())"
        XCTAssertEqual(event.actor, expectedActor)
        XCTAssertEqual(log.entries().first?.actor, expectedActor)
    }

    func testDeletePatientKeepsAuditRows() throws {
        let patientID = UUID()
        let sessionID = UUID()

        // 1. Record events relating to this patient
        try log.record(.phiCreated, subjectID: patientID.uuidString, detail: "patient created")
        try log.record(.phiAmended, subjectID: sessionID.uuidString, detail: "session updated")

        // 2. Store records in comment store and then purge
        let commentStore = try CommentStore(opening: root)
        commentStore.addComment(sessionID: sessionID, quotedText: "quote", body: "note")
        XCTAssertFalse(commentStore.comments(sessionID: sessionID).isEmpty)

        // Purge patient records
        let purged = commentStore.purgePatientRecords(patientID: patientID, sessionIDs: [sessionID])
        XCTAssertTrue(purged)
        XCTAssertTrue(commentStore.comments(sessionID: sessionID).isEmpty)

        // 3. Audit ledger rows remain intact
        let remaining = log.entries()
        XCTAssertEqual(remaining.count, 2)
        XCTAssertEqual(remaining.map(\.action), [.phiCreated, .phiAmended])
        XCTAssertEqual(remaining.map(\.subjectID), [patientID.uuidString, sessionID.uuidString])
    }

    func testNoRetentionPurge() throws {
        try log.record(.phiViewed, subjectID: "session-1", detail: "transcript read")
        try log.record(.phiCopied, subjectID: "session-1", detail: "copied note")

        // Retention policy never deletes audit_events
        XCTAssertThrowsError(try log.core?.executeRaw("DELETE FROM audit_events;"))
        XCTAssertEqual(log.entries().count, 2)
    }

    func testEveryActionHasADisplayName() {
        for action in AuditAction.allCases {
            XCTAssertFalse(action.displayName.isEmpty, "\(action) needs a display name")
        }
    }

    func testPassphraseChangeIsRecorded() throws {
        try log.record(.encryptionPassphraseChanged)
        XCTAssertEqual(log.entries().first?.action, .encryptionPassphraseChanged)
        XCTAssertEqual(AuditAction.encryptionPassphraseChanged.rawValue, "encryptionPassphraseChanged")
    }

    func testSubjectAndDetailRoundTrip() throws {
        let id = UUID().uuidString
        try log.record(.recordExported, subjectID: id, detail: "Markdown", appVersion: "1.2")
        let entry = try XCTUnwrap(log.entries().first)
        XCTAssertEqual(entry.subjectID, id)
        XCTAssertEqual(entry.detail, "Markdown")
        XCTAssertEqual(entry.appVersion, "1.2")
    }

    func testExportGeneratesFaithfulReport() throws {
        try log.record(.appUnlocked, appVersion: "1.0")
        try log.record(.encryptionEnabled, appVersion: "1.0")

        let dest = root.appendingPathComponent("exported-audit.txt")
        try log.export(to: dest)

        let report = try String(contentsOf: dest, encoding: .utf8)
        XCTAssertTrue(report.contains("Aletheia security audit log"))
        XCTAssertTrue(report.contains("App unlocked"))
        XCTAssertTrue(report.contains("Encryption enabled"))
    }

    // MARK: - Chain integrity under concurrency, key changes and failures

    func testConcurrentAppendsFromTwoConnectionsKeepOneChain() throws {
        // A second AuditLog on the same folder has its own SQLite connection;
        // interleaved appends must still form one unbroken chain.
        let other = AuditLog(root: root, keyProvider: { [weak self] in self?.testKey })
        let logs: [AuditLog] = [log, other]
        DispatchQueue.concurrentPerform(iterations: 60) { i in
            _ = try? logs[i % 2].record(.appUnlocked, detail: "n\(i)")
        }
        XCTAssertEqual(log.entries().count, 60)
        XCTAssertEqual(log.verifyIntegrity(), .verified(count: 60))
    }

    func testRowsSignedWithDEKFallbackStillVerify() throws {
        let dek = SymmetricKey(size: .bits256)
        var keychainAvailable = false
        let mixed = AuditLog(
            root: root,
            keyProvider: { [weak self] in keychainAvailable ? self?.testKey : nil },
            dekProvider: { dek })
        let first = try mixed.record(.appUnlocked)   // Keychain unreachable: DEK-derived key
        keychainAvailable = true
        let second = try mixed.record(.appLocked)    // Keychain key
        XCTAssertNotNil(first.mac)
        XCTAssertNotEqual(
            AuditLog.computeMAC(key: testKey, prevMac: nil, row: .init(
                at: first.at, actor: first.actor, action: first.action.rawValue,
                subjectID: nil, detail: nil, appVersion: first.appVersion)),
            first.mac, "first row should be signed with the DEK-derived key")
        XCTAssertEqual(second.prevMac, first.mac)
        XCTAssertEqual(mixed.verifyIntegrity(), .verified(count: 2))
    }

    func testAppVersionIsCoveredByTheMAC() throws {
        try log.record(.appUnlocked, appVersion: "1.0")
        try log.core?.executeRaw("DROP TRIGGER IF EXISTS audit_no_update;")
        try log.core?.executeRaw("UPDATE audit_events SET app_version = '9.9' WHERE seq = 1;")
        guard case .broken(let seq, _) = log.verifyIntegrity() else {
            return XCTFail("Editing app_version must break verification")
        }
        XCTAssertEqual(seq, 1)
    }

    func testLegacyLogIsKeptWhenTheDatabaseCannotOpen() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        // A directory where the database file should be: SQLite can't open it.
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Aletheia.sqlite"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let legacyURL = dir.appendingPathComponent(AuditLog.legacyFileName)
        try Data(#"{"action":"appUnlocked","appVersion":"1.0","at":"2026-01-01T00:00:00Z"}"#.utf8).write(to: legacyURL)

        let broken = AuditLog(root: dir, keyProvider: { [weak self] in self?.testKey })
        XCTAssertNil(broken.core)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path),
                      "the old log must stay in place to be imported once the database opens")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: dir.appendingPathComponent(AuditLog.legacyImportedFileName).path))
    }

    func testLegacyImportNeverOverwritesAnEarlierImportedCopy() throws {
        let earlier = root.appendingPathComponent(AuditLog.legacyImportedFileName)
        try Data("earlier".utf8).write(to: earlier)
        try Data(#"{"action":"appUnlocked","appVersion":"1.0","at":"2026-01-01T00:00:00Z"}"#.utf8)
            .write(to: root.appendingPathComponent(AuditLog.legacyFileName))

        let again = AuditLog(root: root, keyProvider: { [weak self] in self?.testKey })
        XCTAssertEqual(again.entries().count, 1)
        XCTAssertEqual(try String(contentsOf: earlier, encoding: .utf8), "earlier")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(AuditLog.legacyImportedFileName + "-2").path))
    }

    // MARK: - Keychain key creation

    func testKeyIsNotReplacedWhenTheKeychainReadFails() {
        var adds = 0
        let key = AuditKeyManager.loadOrCreate(
            load: { (errSecInteractionNotAllowed, nil) },
            add: { _ in adds += 1; return errSecSuccess })
        XCTAssertNil(key)
        XCTAssertEqual(adds, 0, "a locked or refused keychain must not get a new key")
    }

    func testKeyIsCreatedOnlyWhenAbsent() {
        let stored = SymmetricKey(size: .bits256)
        var adds = 0
        XCTAssertEqual(bytes(AuditKeyManager.loadOrCreate(
            load: { (errSecSuccess, stored) },
            add: { _ in adds += 1; return errSecSuccess })), bytes(stored))
        XCTAssertEqual(adds, 0)

        var added: SymmetricKey?
        let made = AuditKeyManager.loadOrCreate(
            load: { (errSecItemNotFound, nil) },
            add: { added = $0; return errSecSuccess })
        XCTAssertNotNil(made)
        XCTAssertEqual(bytes(made), bytes(added))
    }

    func testRacingKeyCreationAdoptsTheStoredKey() {
        let winner = SymmetricKey(size: .bits256)
        var loads = 0
        let key = AuditKeyManager.loadOrCreate(
            load: {
                loads += 1
                return loads == 1 ? (errSecItemNotFound, nil) : (errSecSuccess, winner)
            },
            add: { _ in errSecDuplicateItem })
        XCTAssertEqual(bytes(key), bytes(winner))
    }

    private func bytes(_ key: SymmetricKey?) -> Data? {
        key?.withUnsafeBytes { Data($0) }
    }
}
