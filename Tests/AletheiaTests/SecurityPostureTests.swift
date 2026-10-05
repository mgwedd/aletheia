import XCTest
@testable import Aletheia

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
        localEncryptedBackup: Bool = true,
        localBackupActive: Bool = true,
        iCloudBackupEnabled: Bool = false,
        iCloudBackupConfigured: Bool = false,
        networkOnline: Bool? = nil
    ) -> [PostureItem] {
        SecurityPosture.evaluate(
            appLockEnabled: appLockEnabled,
            canAuthenticate: canAuthenticate,
            idleAutoLockMinutes: idleAutoLockMinutes,
            encryptionEnabled: encryptionEnabled,
            encryptionUnlocked: encryptionUnlocked,
            auditLogActive: auditLogActive,
            localEncryptedBackup: localEncryptedBackup,
            localBackupActive: localBackupActive,
            iCloudBackupEnabled: iCloudBackupEnabled,
            iCloudBackupConfigured: iCloudBackupConfigured,
            networkOnline: networkOnline
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

    func testLocalBackupOnlySecureWhenEnabledAndActuallyWritten() {
        // Toggle on and the app really writes archives: secure.
        XCTAssertEqual(
            item("encryptedBackup", in: evaluate(localEncryptedBackup: true, localBackupActive: true))?.level,
            .secure)
        // Toggle on but nothing writes archives (this build): a saved preference
        // only, so it must not read as a protection that exists.
        let inactive = item("encryptedBackup", in: evaluate(localEncryptedBackup: true, localBackupActive: false))
        XCTAssertEqual(inactive?.level, .informational)
        XCTAssertTrue(inactive?.detail.contains("nothing is being backed up") ?? false)
        XCTAssertFalse(inactive?.detail.contains("is kept") ?? true)
        // Toggle off: an option, never secure.
        XCTAssertEqual(
            item("encryptedBackup", in: evaluate(localEncryptedBackup: false, localBackupActive: true))?.level,
            .informational)
    }

    func testInactiveLocalBackupNeverDrivesActionable() {
        for enabled in [true, false] {
            let items = evaluate(localEncryptedBackup: enabled, localBackupActive: false)
            XCTAssertNotEqual(item("encryptedBackup", in: items)?.level, .actionRecommended)
        }
    }

    func testShippedBuildDoesNotClaimLocalBackupIsActive() {
        // Guards the wiring flag: flipping it to true must come with the change
        // that actually calls BackupCoordinator, and with this test's update.
        XCTAssertFalse(LocalEncryptedBackupService.isWired)
    }

    func testICloudBackupOnlySecureWhenEnabledAndProvisioned() {
        // Enabled + provisioned: an active, sealed off-device copy.
        XCTAssertEqual(
            item("cloudBackup", in: evaluate(iCloudBackupEnabled: true, iCloudBackupConfigured: true))?.level,
            .secure)
        // Enabled but not provisioned (current build): the choice is saved but
        // nothing is uploaded yet — informational, never "secure".
        XCTAssertEqual(
            item("cloudBackup", in: evaluate(iCloudBackupEnabled: true, iCloudBackupConfigured: false))?.level,
            .informational)
        // Off: an available option, informational.
        XCTAssertEqual(
            item("cloudBackup", in: evaluate(iCloudBackupEnabled: false))?.level,
            .informational)
    }

    func testICloudBackupNeverDrivesActionable() {
        // Neither the saved-but-inactive toggle nor its absence should ask for action.
        for enabled in [true, false] {
            let items = evaluate(iCloudBackupEnabled: enabled, iCloudBackupConfigured: false)
            XCTAssertNotEqual(item("cloudBackup", in: items)?.level, .actionRecommended)
        }
    }

    func testNetworkItemIsAlwaysInformational() {
        for state: Bool? in [true, false, nil] {
            let items = evaluate(networkOnline: state)
            let network = item("network", in: items)
            XCTAssertNotNil(network, "network item should always be present")
            XCTAssertEqual(network?.level, .informational)
        }
    }

    func testNetworkDetailReflectsReachability() {
        XCTAssertTrue(item("network", in: evaluate(networkOnline: true))?.detail.contains("online") ?? false)
        XCTAssertTrue(item("network", in: evaluate(networkOnline: false))?.detail.contains("offline") ?? false)
        // Unknown state must not assert either online or offline.
        let unknown = item("network", in: evaluate(networkOnline: nil))?.detail ?? ""
        XCTAssertFalse(unknown.contains("online"))
        XCTAssertFalse(unknown.contains("offline"))
    }

    func testNetworkAndCloudDoNotDowngradeHardenedHeadline() {
        // Online, iCloud saved-but-inactive, and no local backup: all informational.
        let items = evaluate(
            localEncryptedBackup: false,
            iCloudBackupEnabled: true,
            iCloudBackupConfigured: false,
            networkOnline: true)
        XCTAssertFalse(items.contains { $0.level == .actionRecommended })
        XCTAssertEqual(SecurityPosture.overall(items), .secure)
    }
}
