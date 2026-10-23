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

    func testTheKeyLinkIsTheBetaPageOnAstreaLabs() {
        let url = LicenseLinks.requestKey
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "astrealabs.com")
        XCTAssertEqual(url.path, "/aletheia/beta")
        XCTAssertNil(url.query, "the link carries nothing about the user or the key")
    }

    func testExportRequestOpensTheBackupsPane() {
        XCTAssertEqual(SettingsRequest.exportAllRecords.pane, .backups)
        XCTAssertEqual(SettingsRequest.license.pane, .license)
    }
}
