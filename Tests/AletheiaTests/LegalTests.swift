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
        for path in ["PRIVACY.md", "SECURITY.md", "README.md", "docs/ENCRYPTION.md",
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
}
