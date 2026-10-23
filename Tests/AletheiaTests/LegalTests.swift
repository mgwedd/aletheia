import XCTest
@testable import Aletheia

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

    /// The Terms cover the license key and what expiry or revocation blocks,
    /// and the Privacy Policy discloses the revocation-list download.
    func testPoliciesDescribeTheLicenseKeyAndRevocationList() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let terms = try String(contentsOf: root.appendingPathComponent("TERMS.md"), encoding: .utf8)
        for phrase in ["License key", "do not share, transfer, or publish", "revoke", "Pre-release versions",
                       "open, read, search, export, and\ndelete"] {
            XCTAssertTrue(terms.contains(phrase), phrase)
        }
        let privacy = try String(contentsOf: root.appendingPathComponent("PRIVACY.md"), encoding: .utf8)
        XCTAssertTrue(privacy.contains("License revocation list"))
        XCTAssertTrue(privacy.contains("`astrealabs.com`"))
        XCTAssertTrue(privacy.contains("contains no license key or other identifier"))
        XCTAssertTrue(terms.contains("14-day grace period"))
        // Revocation is not instant: it waits for the next daily list.
        XCTAssertTrue(terms.contains("when the\nApp next receives the list") || terms.contains("when the App next receives the list"))
        XCTAssertTrue(terms.contains("a revoked key has no grace period"))
        XCTAssertTrue(terms.contains("never require a license key, with no time limit"))
        XCTAssertFalse(terms.contains("end your use of the App"))
        // The license backend exists, so the policy must not deny having one.
        XCTAssertFalse(privacy.contains("developer backend"))
        XCTAssertFalse(privacy.contains("developer\nbackend"))
        XCTAssertFalse(privacy.contains("cannot see who uses"))
    }

    /// The acceptance version must move whenever a policy's "Last updated" date
    /// does, or users keep an acceptance of the old text.
    func testCurrentVersionIsNotOlderThanThePublishedPolicies() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["TERMS.md", "PRIVACY.md"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            let date = try XCTUnwrap(
                text.firstMatch(of: /_Last updated: (\d{4}-\d{2}-\d{2})_/)?.1, path)
            XCTAssertGreaterThanOrEqual(Legal.currentVersion, String(date), path)
        }
    }

    func testPublishedPrivacyAndSafeguardDocsDescribeCurrentBackupState() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["PRIVACY.md", "docs/HIPAA-SAFEGUARDS.md"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("iCloud backup"), path)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("end-to-end encrypted backup to your own iCloud"), path)
        }
    }

    /// The security and encryption docs must match what the app does: no
    /// archive backup is offered, the app lock does not engage on hide, the
    /// encryption pane is titled "Encryption", and the plaintext search index
    /// is disclosed.
    func testSecurityAndEncryptionDocsMatchShippedBehavior() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["PRIVACY.md", "SECURITY.md", "docs/ENCRYPTION.md", "docs/HIPAA-SAFEGUARDS.md"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("iCloud backup"), path)
            XCTAssertFalse(text.contains("Extra Encryption"), path)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("re-locks when it's hidden"), path)
            XCTAssertFalse(text.contains("Backup also offers"), path)
        }
        // Ollama support was removed; the built-in engine is the only AI path.
        for path in ["PRIVACY.md", "TERMS.md", "SECURITY.md", "README.md", "docs/ENCRYPTION.md",
                     "docs/HIPAA-SAFEGUARDS.md", "docs/DESIGN-DECISIONS.md"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("ollama"), path)
            XCTAssertFalse(text.contains("11434"), path)
        }
        XCTAssertEqual(SettingsPane.encryption.title, "Encryption")
        XCTAssertEqual(SettingsPane.backups.title, "Backups")
        XCTAssertFalse(LocalEncryptedBackupService.isWired)
        XCTAssertFalse(ICloudEncryptedBackupService.isProvisioned)
        for path in ["SECURITY.md", "docs/ENCRYPTION.md", "docs/HIPAA-SAFEGUARDS.md"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(text.contains("search.sqlite"), path)
        }
    }

    /// Support questions go to a private address, never a public issue tracker,
    /// and the Terms name a governing law.
    func testSupportIsPrivateAndTermsNameAGoverningLaw() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["TERMS.md", "PRIVACY.md", "docs/SETUP-GUIDE.md"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertFalse(text.localizedCaseInsensitiveContains("open an issue"), path)
            XCTAssertFalse(text.contains("github.com/mgwedd/aletheia/issues"), path)
            XCTAssertTrue(text.contains("support@astrealabs.com"), path)
        }
        let terms = try String(contentsOf: root.appendingPathComponent("TERMS.md"), encoding: .utf8)
        XCTAssertTrue(terms.contains("laws of the State of Wyoming"))
        XCTAssertFalse(terms.contains("Specify the governing jurisdiction"))
    }

    // MARK: - Documents match shipped behavior

    private func doc(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// The privacy policy must disclose the feedback form and name only the
    /// query fields the link can actually carry.
    func testPrivacyPolicyDisclosesTheFeedbackForm() throws {
        let privacy = try doc("PRIVACY.md")
        XCTAssertEqual(FeedbackLink.formURL.absoluteString, "https://astrealabs.com/feedback")
        XCTAssertTrue(privacy.contains("astrealabs.com/feedback"))
        XCTAssertEqual(FeedbackLink.allowedQueryKeys, ["project", "type", "environment"])
        let setup = try doc("docs/SETUP-GUIDE.md")
        XCTAssertTrue(setup.contains("Report a Bug"))
    }

    /// The network description in every document matches the helper design:
    /// the app has no network entitlement and the helper makes the only calls.
    func testDocsDescribeTheNetworkHelperConsistently() throws {
        let entitlements = try doc("Sources/App/Resources/Aletheia.entitlements")
        XCTAssertFalse(entitlements.contains("<key>com.apple.security.network.client</key>"))
        for path in ["PRIVACY.md", "SECURITY.md", "docs/HIPAA-SAFEGUARDS.md"] {
            let text = try doc(path)
            XCTAssertTrue(text.localizedCaseInsensitiveContains("helper"), path)
            XCTAssertTrue(text.contains("Hugging Face"), path)
        }
        XCTAssertTrue(try doc("docs/SETUP-GUIDE.md").contains("network helper"))
    }

    /// Export All Records is documented wherever backups or exports are, and
    /// the control it names exists.
    func testDocsNameTheExportAllRecordsControl() throws {
        let settings = try doc("Sources/App/Views/SettingsView.swift")
        XCTAssertTrue(settings.contains("Export All Records"))
        for path in ["PRIVACY.md", "SECURITY.md", "TERMS.md", "docs/HIPAA-SAFEGUARDS.md", "docs/SETUP-GUIDE.md"] {
            XCTAssertTrue(try doc(path).contains("Export All Records"), path)
        }
    }

    /// Numbers quoted in the documents come from the code that enforces them.
    func testDocsQuoteTheEnforcedPassphraseMinimumAndIdleLock() throws {
        XCTAssertEqual(PassphraseStrength.requiredLength, 12)
        XCTAssertEqual(IdleAutoLockTimeout.defaultTimeout, .fifteenMinutes)
        for path in ["SECURITY.md", "docs/ENCRYPTION.md"] {
            XCTAssertTrue(try doc(path).contains("12 characters"), path)
        }
        for path in ["SECURITY.md", "docs/HIPAA-SAFEGUARDS.md"] {
            XCTAssertTrue(try doc(path).contains("15 minutes"), path)
        }
    }

    /// The audit-log description names the ledger, not the old text file, and
    /// does not promise events the app never records.
    func testAuditLogDocsMatchTheLedger() throws {
        let never: [AuditAction] = [.phiViewed, .phiCreated, .phiAmended, .phiDeleted, .aiInference,
                                    .phiCopied, .backupRun, .backupRestored, .noteSigned]
        XCTAssertEqual(never.count, 9)
        for path in ["SECURITY.md", "docs/HIPAA-SAFEGUARDS.md"] {
            let text = try doc(path)
            XCTAssertTrue(text.contains("audit_events") || text.localizedCaseInsensitiveContains("tamper-evident"), path)
            XCTAssertFalse(text.contains("no tamper-evident"), path)
            XCTAssertFalse(text.contains("no integrity seal"), path)
        }
        XCTAssertFalse(try doc("docs/ENCRYPTION.md").contains("audit.log`, which"))
    }

    /// Statements that used to be true and are not any more.
    func testDocsHaveNoStaleClaims() throws {
        for path in ["PRIVACY.md", "SECURITY.md", "docs/HIPAA-SAFEGUARDS.md", "docs/ENCRYPTION.md", "docs/SETUP-GUIDE.md"] {
            let text = try doc(path)
            XCTAssertFalse(text.contains("can't verify"), path)
            XCTAssertFalse(text.contains("cannot verify"), path)
        }
    }
}
