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
        encryptionOffered: Bool = true,
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
            encryptionOffered: encryptionOffered,
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

    func testEncryptionItemIsOmittedWhenTheBuildDoesNotOfferIt() {
        let items = evaluate(encryptionEnabled: false, encryptionOffered: false)
        XCTAssertNil(item("encryption", in: items), "nothing to turn on, so no advice to turn it on")
        XCTAssertFalse(items.contains { $0.level == .actionRecommended })
        XCTAssertEqual(SecurityPosture.overall(items), .secure)
    }

    func testEncryptionItemStaysWhenOfferedOrAlreadyOn() {
        XCTAssertEqual(item("encryption", in: evaluate(encryptionEnabled: false, encryptionOffered: true))?.level, .actionRecommended)
        // An already-encrypted folder reports its state whatever the build offers.
        XCTAssertEqual(item("encryption", in: evaluate(encryptionEnabled: true, encryptionOffered: false))?.level, .secure)
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

    func testIdleAutoLockOffIsInformationalNotAWarning() {
        let items = evaluate(idleAutoLockMinutes: 0)
        XCTAssertEqual(item("idleAutoLock", in: items)?.level, .informational)
        XCTAssertTrue(item("idleAutoLock", in: items)?.detail.contains("Lock Screen") == true)
        XCTAssertFalse(items.contains { $0.level == .actionRecommended })
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

    func testLocalBackupIsListedOnlyOnceItIsActuallyWritten() {
        // Toggle on and the app really writes archives: secure.
        XCTAssertEqual(
            item("encryptedBackup", in: evaluate(localEncryptedBackup: true, localBackupActive: true))?.level,
            .secure)
        // Toggle off but available: an option, never secure.
        XCTAssertEqual(
            item("encryptedBackup", in: evaluate(localEncryptedBackup: false, localBackupActive: true))?.level,
            .informational)
        // Nothing writes archives (this build): no row about a copy that cannot exist,
        // whatever the saved preference says.
        for enabled in [true, false] {
            XCTAssertNil(item("encryptedBackup", in: evaluate(localEncryptedBackup: enabled, localBackupActive: false)))
        }
    }

    func testShippedBuildDoesNotClaimLocalBackupIsActive() {
        // Guards the wiring flag: flipping it to true must come with the change
        // that actually calls BackupCoordinator, and with this test's update.
        XCTAssertFalse(LocalEncryptedBackupService.isWired)
    }

    func testICloudBackupIsListedOnlyWhenOnAndProvisioned() {
        XCTAssertEqual(
            item("cloudBackup", in: evaluate(iCloudBackupEnabled: true, iCloudBackupConfigured: true))?.level,
            .secure)
        // Not provisioned (this build) or off: nothing to report.
        XCTAssertNil(item("cloudBackup", in: evaluate(iCloudBackupEnabled: true, iCloudBackupConfigured: false)))
        XCTAssertNil(item("cloudBackup", in: evaluate(iCloudBackupEnabled: false, iCloudBackupConfigured: true)))
        XCTAssertNil(item("cloudBackup", in: evaluate(iCloudBackupEnabled: false)))
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

    func testNetworkDetailMentionsBackupsOnlyWhenOneUploads() {
        let none = item("network", in: evaluate(networkOnline: true))?.detail ?? ""
        XCTAssertFalse(none.lowercased().contains("backup"))
        let cloud = item("network", in: evaluate(iCloudBackupEnabled: true, iCloudBackupConfigured: true, networkOnline: true))?.detail ?? ""
        XCTAssertTrue(cloud.contains("end-to-end-encrypted backups"))
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
