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

    /// The legal documents describe backups as local-only: no iCloud backup is offered.
    func testDocumentsDoNotOfferAnICloudBackup() throws {
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for name in ["PRIVACY.md", "TERMS.md", "SECURITY.md"] {
            let text = try String(contentsOf: repo.appendingPathComponent(name), encoding: .utf8).lowercased()
            XCTAssertFalse(text.contains("icloud backup"), "\(name) must not offer an iCloud backup")
            XCTAssertFalse(text.contains("backup to your own"), "\(name) must not describe an upload")
        }
        let terms = try String(contentsOf: repo.appendingPathComponent("TERMS.md"), encoding: .utf8)
        XCTAssertFalse(terms.contains("does not back up your data"))
    }
}
