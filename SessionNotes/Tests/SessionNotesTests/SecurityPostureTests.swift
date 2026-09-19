import XCTest
@testable import SessionNotes

/// The posture evaluator turns raw security state into the advice a clinician
/// reads, so the tests pin each mapping and — importantly — that only truly
/// actionable gaps set the headline to "action recommended"; informational
/// states (encryption locked, no backup) never cry wolf.
final class SecurityPostureTests: XCTestCase {
    /// Fully hardened baseline; individual tests override one axis at a time.
    private func evaluate(
        appLockEnabled: Bool = true,
        canAuthenticate: Bool = true,
        idleAutoLockMinutes: Int = 15,
        encryptionEnabled: Bool = true,
        encryptionUnlocked: Bool = true,
        auditLogActive: Bool = true,
        localEncryptedBackup: Bool = true
    ) -> [PostureItem] {
        SecurityPosture.evaluate(
            appLockEnabled: appLockEnabled,
            canAuthenticate: canAuthenticate,
            idleAutoLockMinutes: idleAutoLockMinutes,
            encryptionEnabled: encryptionEnabled,
            encryptionUnlocked: encryptionUnlocked,
            auditLogActive: auditLogActive,
            localEncryptedBackup: localEncryptedBackup
        )
    }

    private func item(_ id: String, in items: [PostureItem]) -> PostureItem? {
        items.first { $0.id == id }
    }

    func testFullyHardenedHasNoActionItems() {
        let items = evaluate()
        XCTAssertFalse(items.contains { $0.level == .actionRecommended })
        XCTAssertEqual(SecurityPosture.overall(items), .secure)
        // The standing on-device guarantee is always present and secure.
        XCTAssertEqual(item("onDevice", in: items)?.level, .secure)
    }

    func testAppLockOffIsActionable() {
        let items = evaluate(appLockEnabled: false)
        XCTAssertEqual(item("appLock", in: items)?.level, .actionRecommended)
        XCTAssertEqual(SecurityPosture.overall(items), .actionRecommended)
        // Idle auto-lock is not shown at all when app lock is off.
        XCTAssertNil(item("idleAutoLock", in: items))
    }

    func testAppLockOnButCannotAuthenticateIsActionable() {
        let items = evaluate(canAuthenticate: false)
        XCTAssertEqual(item("appLock", in: items)?.level, .actionRecommended)
    }

    func testIdleAutoLockNeverIsActionableWhenAppLockOn() {
        let items = evaluate(idleAutoLockMinutes: 0)
        XCTAssertEqual(item("idleAutoLock", in: items)?.level, .actionRecommended)
    }

    func testEncryptionStates() {
        XCTAssertEqual(item("encryption", in: evaluate(encryptionEnabled: false))?.level, .actionRecommended)
        XCTAssertEqual(item("encryption", in: evaluate(encryptionEnabled: true, encryptionUnlocked: false))?.level, .informational)
        XCTAssertEqual(item("encryption", in: evaluate(encryptionEnabled: true, encryptionUnlocked: true))?.level, .secure)
    }

    func testAuditLogReflectsActivation() {
        XCTAssertEqual(item("auditLog", in: evaluate(auditLogActive: true))?.level, .secure)
        XCTAssertEqual(item("auditLog", in: evaluate(auditLogActive: false))?.level, .informational)
    }

    func testInformationalItemsDoNotDowngradeOverall() {
        // Everything actionable is satisfied; only informational gaps remain
        // (no backup, encryption locked). Headline must stay secure.
        let items = evaluate(encryptionUnlocked: false, localEncryptedBackup: false)
        XCTAssertFalse(items.contains { $0.level == .actionRecommended })
        XCTAssertEqual(SecurityPosture.overall(items), .secure)
    }
}
