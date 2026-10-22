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
        let legacyEvent1 = AuditEvent(at: "2026-01-01T00:00:00Z", action: .appUnlocked, subjectID: nil, detail: "old1", appVersion: "1.0")
        let legacyEvent2 = AuditEvent(at: "2026-01-02T00:00:00Z", action: .recordExported, subjectID: "pat-1", detail: "old2", appVersion: "1.0")
        let line1 = AuditLog.encodeLine(legacyEvent1)!
        let line2 = AuditLog.encodeLine(legacyEvent2)!
        try (line1 + line2).write(to: legacyURL)

        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))

        // Initialize AuditLog — must import legacy rows
        let legacyLog1 = AuditLog(root: legacyDir, keyProvider: { [weak self] in self?.testKey })
        let entries = legacyLog1.entries()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(entries[0].action, .appUnlocked)
        XCTAssertEqual(entries[0].detail, "imported")
        XCTAssertEqual(entries[1].action, .recordExported)
        XCTAssertEqual(entries[1].detail, "imported")

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
}
