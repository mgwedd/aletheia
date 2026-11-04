import XCTest
@testable import Aletheia

/// The code side of the policies. What the documents say is checked by
/// scripts/check-docs.py, which reads the values below from this source.
final class LegalTests: XCTestCase {
    func testNotAcceptedWhenRecordIsEmpty() {
        XCTAssertFalse(Legal.isAccepted(""))
    }

    func testAcceptedWhenRecordMatchesCurrentVersion() {
        XCTAssertTrue(Legal.isAccepted(Legal.currentVersion))
    }

    func testNotAcceptedWhenRecordedVersionIsOlder() {
        // A stale acceptance (terms changed since) must re-trigger the gate.
        XCTAssertFalse(Legal.isAccepted("1970-01-01"))
        XCTAssertNotEqual(Legal.currentVersion, "1970-01-01")
    }

    func testTermsAndPrivacyURLsResolveToRepoDocuments() {
        XCTAssertTrue(Legal.termsURL.absoluteString.hasSuffix("/TERMS.md"))
        XCTAssertTrue(Legal.privacyURL.absoluteString.hasSuffix("/PRIVACY.md"))
    }

    /// The documents name these panes.
    func testSettingsPaneTitlesTheDocsName() {
        XCTAssertEqual(SettingsPane.encryption.title, "Encryption")
        XCTAssertEqual(SettingsPane.backups.title, "Backups")
    }

    /// The privacy policy names only the query fields the feedback link can carry.
    func testFeedbackLinkMatchesThePrivacyPolicy() {
        XCTAssertEqual(FeedbackLink.formURL.absoluteString, "https://astrealabs.com/feedback")
        XCTAssertEqual(FeedbackLink.allowedQueryKeys, ["project", "type", "environment"])
    }

    /// The documents quote "12 characters" and "15 minutes"; these are the
    /// values they quote.
    func testEnforcedPassphraseMinimumAndIdleLockMatchTheDocs() {
        XCTAssertEqual(PassphraseStrength.requiredLength, 12)
        XCTAssertEqual(IdleAutoLockTimeout.defaultTimeout, .fifteenMinutes)
    }

    /// The audit-log documents do not promise events the app never records.
    func testAuditActionsTheDocsDoNotPromise() {
        let never: [AuditAction] = [.phiViewed, .aiInference, .phiCopied, .backupRestored, .noteSigned]
        XCTAssertEqual(never.count, 5)
    }
}
