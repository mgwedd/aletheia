import CryptoKit
import XCTest
@testable import Aletheia

@MainActor
final class LicenseBannerTests: XCTestCase {
    private var suite: String!
    private var defaults: UserDefaults!

    override func tearDown() {
        if let suite { defaults.removePersistentDomain(forName: suite) }
    }

    /// A real token, installed and read back.
    private func sampleToken() throws -> LicenseToken {
        let (key, ring) = LicenseTestMint.freshKeyring()
        suite = "LicenseBannerTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        let state = LicenseState(settings: AppSettings(defaults: defaults), keyring: ring, now: { LicenseTestMint.now })
        let text = try LicenseTestMint.token(
            LicenseTestMint.payload(lid: LicenseTestMint.sampleLID, exp: LicenseTestMint.now.addingTimeInterval(80 * LicenseTestMint.day)),
            key: key)
        guard case .success(let token) = state.install(text) else { throw XCTSkip("token refused") }
        return token
    }

    func testExportIsOfferedExactlyWhenNewWorkIsPaused() throws {
        let token = try sampleToken()
        let paused: [LicenseStatus] = [.expired(token), .revoked(token), .unlicensed, .invalid(.badSignature)]
        let working: [LicenseStatus] = [
            .valid(token), .expiringSoon(token, daysLeft: 3), .gracePeriod(token, daysLeft: 3), .grandfathered,
        ]
        for status in paused { XCTAssertTrue(LicenseBanner.offersExport(for: status), "\(status)") }
        for status in working { XCTAssertFalse(LicenseBanner.offersExport(for: status), "\(status)") }
    }

    func testAKeyLinkIsOfferedWheneverTheBannerShows() throws {
        let token = try sampleToken()
        let all: [LicenseStatus] = [
            .valid(token), .expiringSoon(token, daysLeft: 3), .gracePeriod(token, daysLeft: 3),
            .expired(token), .revoked(token), .unlicensed, .grandfathered, .invalid(.badSignature),
        ]
        for status in all {
            XCTAssertEqual(LicenseBanner.offersNewKey(for: status), LicenseBanner.text(for: status) != nil, "\(status)")
        }
    }

    func testTheExpiryWarningSaysTheRenewedKeyIsEmailed() throws {
        let text = try XCTUnwrap(LicenseBanner.text(for: .expiringSoon(try sampleToken(), daysLeft: 5)))
        XCTAssertTrue(text.contains("emailed"), text)
        XCTAssertTrue(text.contains("Settings > License key"), text)
    }

    private func emailParts(_ url: URL) throws -> (to: String, subject: String, body: String) {
        let parts = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let item = { (name: String) in parts.queryItems?.first { $0.name == name }?.value ?? "" }
        XCTAssertEqual(parts.scheme, "mailto")
        XCTAssertEqual(parts.queryItems?.map(\.name), ["subject", "body"], "nothing but a subject and body")
        return (parts.path, item("subject"), item("body"))
    }

    func testGetAKeyDraftsARenewalEmailNamingOnlyTheLicenseIDAndEndDate() throws {
        let token = try sampleToken()
        let email = try emailParts(LicenseLinks.keyRequestEmail(for: token))
        XCTAssertEqual(email.to, "support@astrealabs.com")
        XCTAssertEqual(email.subject, "Aletheia license renewal")
        XCTAssertTrue(email.body.contains("Please renew my Aletheia license."), email.body)
        XCTAssertTrue(email.body.contains("License ID: \(token.lid)"), email.body)
        if let expiresAt = token.expiresAt {
            XCTAssertTrue(email.body.contains("Ends: \(expiresAt.licenseText)"), email.body)
        }
        XCTAssertFalse(email.body.contains(token.sub), "the licensee's email is not repeated")
        XCTAssertFalse(email.body.contains(token.kid))
    }

    func testWithoutALicenseGetAKeyAsksForOne() throws {
        let email = try emailParts(LicenseLinks.keyRequestEmail(for: nil))
        XCTAssertEqual(email.to, "support@astrealabs.com")
        XCTAssertEqual(email.subject, "Aletheia license key")
        XCTAssertFalse(email.body.contains("License ID"), email.body)
    }

    func testTheSettingsCaptionSaysWhatTheEmailIncludes() {
        XCTAssertTrue(LicensePane.requestCaption.contains("support@astrealabs.com"))
        XCTAssertTrue(LicensePane.requestCaption.contains("license ID and end date, nothing else"))
    }

    func testExportRequestOpensTheBackupsPane() {
        XCTAssertEqual(SettingsRequest.exportAllRecords.pane, .backups)
        XCTAssertEqual(SettingsRequest.license.pane, .license)
    }

    func testTheLicenseStripCanBeClosed() {
        XCTAssertEqual(LicenseBanner.dismissHelp, "Dismiss")
    }

    /// The top strips sit on the detail column. Set on the split view, they covered
    /// the search field once a query moved it to the top of the pane.
    func testTopStripsAreSetOnTheDetailColumn() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/Views/RootView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let detail = try XCTUnwrap(source.range(of: "} detail: {"))
        let inset = try XCTUnwrap(source.range(of: ".safeAreaInset(edge: .top, spacing: 0) { dataSafetyNotices }"))
        XCTAssertLessThan(detail.lowerBound, inset.lowerBound)
        XCTAssertEqual(source.components(separatedBy: "{ dataSafetyNotices }").count, 2, "set once")
    }
}
