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

    /// The security and encryption docs must match what the app does: backups
    /// are local only (Back Up Now), the app lock does not engage on hide, the
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
        for path in ["SECURITY.md", "docs/ENCRYPTION.md", "docs/HIPAA-SAFEGUARDS.md"] {
            let text = try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
            XCTAssertTrue(text.contains("search.sqlite"), path)
        }
    }

    /// The legal documents describe backups as local-only: no iCloud backup is offered.
    func testDocumentsDoNotOfferAnICloudBackup() throws {
        for name in ["PRIVACY.md", "TERMS.md", "SECURITY.md"] {
            let text = try doc(name).lowercased()
            XCTAssertFalse(text.contains("icloud backup"), "\(name) must not offer an iCloud backup")
            XCTAssertFalse(text.contains("backup to your own"), "\(name) must not describe an upload")
        }
        XCTAssertFalse(try doc("TERMS.md").contains("does not back up your data on its own"))
    }

    /// The docs describe the local Back Up Now feature and its limits.
    func testDocsDescribeLocalBackUpNow() throws {
        for path in ["PRIVACY.md", "SECURITY.md", "TERMS.md", "docs/HIPAA-SAFEGUARDS.md"] {
            let text = try doc(path)
            XCTAssertTrue(text.localizedCaseInsensitiveContains("Back Up Now"), path)
        }
        XCTAssertFalse(try doc("SECURITY.md").contains("not connected to the app"))
        XCTAssertFalse(try doc("docs/HIPAA-SAFEGUARDS.md").contains("not connected to the user interface"))
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

    /// The threat model exists, SECURITY.md links it, and it names the
    /// boundaries the code enforces.
    func testThreatModelExistsAndSecurityLinksIt() throws {
        XCTAssertTrue(try doc("SECURITY.md").contains("docs/THREAT-MODEL.md"))
        let text = try doc("docs/THREAT-MODEL.md")
        for needle in ["Sources/NetworkHelper", "no network entitlement", "SHA-256", "FileVault", "Out of scope"] {
            XCTAssertTrue(text.contains(needle), needle)
        }
    }

    /// The data folder must be on this Mac, so no document may say the picker
    /// opens in or suggests iCloud Drive.
    func testDocsDoNotSuggestICloudForTheDataFolder() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let docsDir = root.appendingPathComponent("docs")
        let extra = try FileManager.default.contentsOfDirectory(atPath: docsDir.path)
            .filter { $0.hasSuffix(".md") }.map { "docs/\($0)" }
        let paths = ["README.md", "PRIVACY.md", "SECURITY.md"] + extra
        XCTAssertTrue(paths.contains("docs/SETUP-GUIDE.md"))
        let banned = ["opens in icloud drive", "suggests icloud", "suggests it", "icloud drive or any folder",
                      "icloud drive when it is available", "keep downloaded"]
        for path in paths {
            let text = try doc(path).lowercased()
            for phrase in banned {
                XCTAssertFalse(text.contains(phrase), "\(path) contains \"\(phrase)\"")
            }
        }
        XCTAssertTrue(try doc("README.md").contains("Use the standard location"))
    }

    /// The entitlement comments must not describe the picker as opening in iCloud Drive.
    func testEntitlementsCommentsDoNotMentionICloudDrive() throws {
        for path in ["Sources/App/Resources/Aletheia.entitlements", "Sources/App/Resources/AletheiaDev.entitlements"] {
            let text = try doc(path).lowercased()
            XCTAssertFalse(text.contains("icloud"), path)
        }
    }

    /// Ollama was removed; no document may offer it.
    func testConsentDocsMentionNoOllama() throws {
        let docsDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs")
        let extra = try FileManager.default.contentsOfDirectory(atPath: docsDir.path)
            .filter { $0.hasSuffix(".md") }.map { "docs/\($0)" }
        for path in ["CONSENT.md", "Sources/App/Views/ConsentGuideView.swift"] + extra {
            XCTAssertFalse(try doc(path).localizedCaseInsensitiveContains("ollama"), path)
        }
    }

    func testConsentGuideAvoidsAbsoluteClaims() throws {
        let text = try doc("Sources/App/Views/ConsentGuideView.swift")
        XCTAssertFalse(text.contains("100%"))
        XCTAssertFalse(text.lowercased().contains("strictly"))
        XCTAssertFalse(text.contains("never sent"))
        XCTAssertTrue(text.contains("Time Machine"))
    }

    private let consentKeyPhrases = [
        "California Penal Code §632",
        "Washington RCW 9.73.030",
        "Connecticut Gen. Stat. §52-570d",
        "not a complete list",
        "Before we start, I would like to record today's session so that I can write my clinical notes.",
        "The recording is stored on my computer and is used only for documentation.",
        "Do you agree to be recorded?",
        "you can ask me to pause or stop at any time",
    ]

    func testConsentDocsListExampleAllPartyStatutes() throws {
        for path in ["CONSENT.md", "Sources/App/Views/ConsentGuideView.swift"] {
            let text = try doc(path)
            for phrase in consentKeyPhrases.prefix(4) {
                XCTAssertTrue(text.contains(phrase), "\(path) lacks \"\(phrase)\"")
            }
            XCTAssertTrue(text.localizedCaseInsensitiveContains("examples"), path)
        }
    }

    func testConsentGuideMatchesConsentMd() throws {
        let md = try doc("CONSENT.md").replacingOccurrences(of: "\n> ", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        let view = try doc("Sources/App/Views/ConsentGuideView.swift")
        for phrase in consentKeyPhrases {
            XCTAssertTrue(view.contains(phrase), "ConsentGuideView lacks \"\(phrase)\"")
            XCTAssertTrue(md.contains(phrase), "CONSENT.md lacks \"\(phrase)\"")
        }
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
