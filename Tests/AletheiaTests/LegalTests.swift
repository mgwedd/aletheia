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
        XCTAssertTrue(terms.contains("never require a license key, with no time limit"))
        XCTAssertFalse(terms.contains("end your use of the App"))
        // The license backend exists, so the policy must not deny having one.
        XCTAssertFalse(privacy.contains("developer backend"))
        XCTAssertFalse(privacy.contains("developer\nbackend"))
        XCTAssertFalse(privacy.contains("cannot see who uses"))
    }
}
