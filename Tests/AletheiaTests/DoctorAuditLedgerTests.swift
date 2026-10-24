import CryptoKit
import XCTest
@testable import Aletheia

/// Doctor's audit check opens the SQLite ledger and verifies its hash chain.
final class DoctorAuditLedgerTests: XCTestCase {
    private var root: URL!
    private var key: SymmetricKey!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        key = SymmetricKey(size: .bits256)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func status(of log: AuditLog?) -> DoctorCheck {
        let probe = LiveDoctorProbes.probeAuditLedger(log, dataRoot: root)
        return DoctorRunner.auditLogChecks(probe)[0]
    }

    func testHealthyLedgerIsOK() throws {
        let log = AuditLog(root: root, keyProvider: { [weak self] in self?.key })
        try log.record(.appUnlocked)
        try log.record(.appLocked)
        let check = status(of: log)
        XCTAssertEqual(check.id, "records.auditLog")
        XCTAssertEqual(check.status, .ok)
    }

    func testProbeDoesNotAppendRows() throws {
        let log = AuditLog(root: root, keyProvider: { [weak self] in self?.key })
        try log.record(.appUnlocked)
        _ = status(of: log)
        XCTAssertEqual(log.entries().count, 1)
    }

    func testTamperedRowFails() throws {
        let log = AuditLog(root: root, keyProvider: { [weak self] in self?.key })
        try log.record(.appUnlocked)
        try log.record(.appLocked)
        try log.core?.executeRaw("DROP TRIGGER IF EXISTS audit_no_update;")
        try log.core?.executeRaw("UPDATE audit_events SET mac = zeroblob(32) WHERE seq = 1;")
        let check = status(of: log)
        XCTAssertEqual(check.status, .failed)
        XCTAssertNotNil(check.nextStep)
    }

    func testUnopenableLedgerFails() throws {
        // A directory where the database file should be: SQLite can't open it.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Aletheia.sqlite"), withIntermediateDirectories: true)
        let log = AuditLog(root: root, keyProvider: { [weak self] in self?.key })
        XCTAssertEqual(status(of: log).status, .failed)
    }

    func testMissingLedgerFails() {
        XCTAssertEqual(status(of: nil).status, .failed)
    }

    func testUnwritableLedgerFails() {
        let check = DoctorRunner.auditLogChecks(.checked(.verified(count: 1), writable: false))[0]
        XCTAssertEqual(check.status, .failed)
    }

    func testUnverifiableLedgerWarns() {
        let check = DoctorRunner.auditLogChecks(.checked(.unverifiable(reason: "Signing key is unavailable"), writable: true))[0]
        XCTAssertEqual(check.status, .warning)
    }
}
