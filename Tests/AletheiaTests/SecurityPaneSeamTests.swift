import AppKit
import CryptoKit
import XCTest
@testable import Aletheia

/// The pieces of the Security pane that views used to build inline.
final class SecurityPaneSeamTests: XCTestCase {
    private struct NoopSpotlight: SpotlightIndexing {
        func replaceIndex(with entries: [SpotlightEntry]) {}
        func clear() {}
    }

    private final class MemoryDeviceKeys: DeviceKeyStoring {
        private var keys: [String: SymmetricKey] = [:]
        func save(_ key: SymmetricKey, for id: String) throws { keys[id] = key }
        func load(for id: String) -> SymmetricKey? { keys[id] }
        func delete(for id: String) { keys[id] = nil }
    }

    func testStatusMessagesNameTheCountOrTheEntry() {
        XCTAssertEqual(IntegrityVerificationResult.verified(count: 3).statusMessage,
                       "Integrity verified: all 3 entries intact.")
        XCTAssertEqual(IntegrityVerificationResult.broken(seq: 2, reason: "mac mismatch").statusMessage,
                       "Integrity check failed at entry #2: mac mismatch")
        XCTAssertEqual(IntegrityVerificationResult.unverifiable(reason: "no key").statusMessage,
                       "Audit log unverifiable: no key")
    }

    func testHeadlinesFollowTheWorstItem() {
        XCTAssertEqual(SecurityPosture.headline(for: .actionRecommended), "Some protections could be stronger")
        XCTAssertEqual(SecurityPosture.headline(for: .secure), "Your data is well protected on this Mac")
    }

    func testCopyingTheVerifyCommandPutsItOnThePasteboard() {
        let board = NSPasteboard(name: .init("aletheia-seam-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        NetworkHelperDisclosure.copyVerifyCommand(to: board)
        XCTAssertEqual(board.string(forType: .string), NetworkHelperDisclosure.verifyCommand())
    }

    func testVerifyingAFolderWithATamperedEntryReportsAndRecordsTheBreak() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "SecurityPaneSeamTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.dataRootURL = root
        let encryption = EncryptionManager(dataRootProvider: { root }, deviceKeys: MemoryDeviceKeys(), defaults: defaults)
        let key = SymmetricKey(size: .bits256)
        let model = AppModel(settings: settings, encryption: encryption, spotlightIndexer: NoopSpotlight())
        model.auditKeyProvider = { key }
        model.rebuildStore()
        model.recordAudit(.appUnlocked)
        model.recordAudit(.appLocked)

        let clean = try XCTUnwrap(model.verifyAuditLog())
        XCTAssertTrue(clean.message.hasPrefix("Integrity verified"), clean.message)
        XCTAssertTrue(clean.report.contains(clean.message))

        let audit = try XCTUnwrap(model.audit)
        try audit.core?.executeRaw("DROP TRIGGER IF EXISTS audit_no_update;")
        try audit.core?.executeRaw("UPDATE audit_events SET detail = 'edited' WHERE seq = 1;")

        let broken = try XCTUnwrap(model.verifyAuditLog())
        XCTAssertTrue(broken.message.hasPrefix("Integrity check failed at entry #1"), broken.message)
        XCTAssertTrue(model.securityAlerts.contains { $0.id == "auditLogBroken" })
        XCTAssertTrue(broken.report.contains("Integrity check failed"))
    }
}
