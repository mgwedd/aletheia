import XCTest
@testable import Aletheia

/// Tokens and a revocation list signed by the license backend with its test key
/// (`Fixtures/license-backend-fixtures.json`, copied from the backend's
/// `apps/web/tests/fixtures/licensing/fixtures.json`). They prove the app reads
/// exactly what the backend writes. The clock is pinned to the file's `now`.
///
/// The fixture file must stay byte-for-byte identical to the site repo's
/// `apps/web/tests/fixtures/licensing/fixtures.json` (astrea-labs-ui). Update it by
/// copying that file over, never by editing it here. It covers the token kinds
/// valid, expired, badSignature, unknownKid, revoked and perpetual (no `exp`).
@MainActor
final class LicenseBackendFixtureTests: XCTestCase {
    private struct Fixtures: Decodable {
        let now: Int
        let publicKeys: [String: String]
        let tokens: [String: String]
        let revokedLid: String
        let revocations: String
    }

    private var fixtures: Fixtures!
    private var ring: LicenseKeyring!
    private var now: Date!
    private var suite: String!
    private var defaults: UserDefaults!
    private var settings: AppSettings!

    override func setUpWithError() throws {
        let url = URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/license-backend-fixtures.json")
        fixtures = try JSONDecoder().decode(Fixtures.self, from: Data(contentsOf: url))
        ring = LicenseKeyring(encoded: fixtures.publicKeys)
        now = Date(timeIntervalSince1970: TimeInterval(fixtures.now))
        suite = "LicenseBackendFixtureTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        settings = AppSettings(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func token(_ name: String) throws -> String {
        try XCTUnwrap(fixtures.tokens[name], "missing fixture token \(name)")
    }

    private func makeState() -> LicenseState {
        LicenseState(settings: settings, keyring: ring, now: { [now] in now! })
    }

    func testTheBackendTestKeyLoads() {
        XCTAssertEqual(Set(ring.keys.keys), ["test-1"])
    }

    func testValidTokenVerifies() throws {
        let license = try LicenseVerifier.verify(token("valid"), keyring: ring, now: now)
        XCTAssertEqual(license.kid, "test-1")
        XCTAssertEqual(license.sub, "valid@example.com")
        XCTAssertEqual(license.tier, "beta")
        XCTAssertEqual(license.lid, "54317e8e-ae1b-47ad-8176-7b6b5a257f07")
        XCTAssertGreaterThan(try XCTUnwrap(license.expiresAt), now)
    }

    func testValidTokenInstallsAndAllowsNewWork() throws {
        let state = makeState()
        guard case .success = state.install(try token("valid")) else { return XCTFail("valid token was refused") }
        XCTAssertNil(state.newWorkRefusal)
    }

    func testTheFixtureCoversEveryTokenKind() {
        XCTAssertEqual(Set(fixtures.tokens.keys),
                       ["valid", "expired", "badSignature", "unknownKid", "revoked", "perpetual"])
    }

    func testPerpetualTokenHasNoExpiryAndNeverLapses() throws {
        let license = try LicenseVerifier.verify(token("perpetual"), keyring: ring, now: now)
        XCTAssertEqual(license.sub, "perpetual@example.com")
        XCTAssertNil(license.expiresAt)
        XCTAssertFalse(license.isExpired(at: now))
        XCTAssertNil(license.daysRemaining(at: now))
        XCTAssertFalse(license.isExpiringSoon(at: now))
        XCTAssertFalse(license.isInGracePeriod(at: now))
        // Still a good license a century later.
        let later = now.addingTimeInterval(100 * 365 * 86_400)
        guard case .valid = LicenseState.evaluate(token: try token("perpetual"), keyring: ring, now: later, revoked: [])
        else { return XCTFail("perpetual token lapsed") }
    }

    func testPerpetualTokenInstallsWithNoBannerAndAllowsNewWork() throws {
        let state = makeState()
        guard case .success = state.install(try token("perpetual")) else { return XCTFail("perpetual token was refused") }
        guard case .valid = state.status else { return XCTFail("status is \(state.status)") }
        XCTAssertNil(state.newWorkRefusal)
        XCTAssertNil(LicenseBanner.text(for: state.status))
    }

    func testPerpetualTokenCanStillBeRevoked() throws {
        let lid = try LicenseVerifier.verify(token("perpetual"), keyring: ring, now: now).lid
        guard case .revoked(let revoked) = LicenseState.evaluate(
            token: try token("perpetual"), keyring: ring, now: now, revoked: [lid])
        else { return XCTFail("a revoked perpetual token stayed valid") }
        XCTAssertNotNil(LicenseBanner.text(for: .revoked(revoked)))
    }

    func testExpiredTokenIsRefused() throws {
        XCTAssertThrowsError(try LicenseVerifier.verify(token("expired"), keyring: ring, now: now)) { error in
            guard case LicenseError.expired = error else { return XCTFail("\(error)") }
        }
        guard case .expired = LicenseState.evaluate(token: try token("expired"), keyring: ring, now: now, revoked: []) else {
            return XCTFail("expired token did not evaluate as expired")
        }
    }

    func testBadSignatureIsRefused() throws {
        XCTAssertThrowsError(try LicenseVerifier.verify(token("badSignature"), keyring: ring, now: now)) { error in
            XCTAssertEqual(error as? LicenseError, .badSignature)
        }
    }

    func testUnknownKidIsRefused() throws {
        XCTAssertThrowsError(try LicenseVerifier.verify(token("unknownKid"), keyring: ring, now: now)) { error in
            XCTAssertEqual(error as? LicenseError, .unknownKey)
        }
    }

    func testRevocationListVerifiesAndNamesTheRevokedLicense() throws {
        let list = try RevocationVerifier.verify(fixtures.revocations, keyring: ring)
        XCTAssertEqual(list.kid, "test-1")
        XCTAssertEqual(list.revoked, [fixtures.revokedLid])
        XCTAssertEqual(list.issuedAt, now)
        XCTAssertGreaterThan(list.next, list.issuedAt)
    }

    func testRevokedTokenIsValidUntilTheListArrivesThenBlocked() throws {
        let revoked = try token("revoked")
        XCTAssertEqual(try LicenseVerifier.verify(revoked, keyring: ring, now: now).lid, fixtures.revokedLid)

        let state = makeState()
        guard case .success = state.install(revoked) else { return XCTFail("token was refused before revocation") }
        XCTAssertNil(state.newWorkRefusal)

        XCTAssertTrue(try state.applyRevocationList(fixtures.revocations))
        guard case .revoked = state.status else { return XCTFail("status is \(state.status)") }
        XCTAssertNotNil(state.newWorkRefusal)
        // Other licenses are untouched by the list.
        guard case .valid = LicenseState.evaluate(
            token: try token("valid"), keyring: ring, now: now, revoked: Set(settings.revokedLicenseIDs))
        else { return XCTFail("valid token was affected by the list") }
    }

    func testRevokedTokenCannotBeInstalledAfterTheList() throws {
        let state = makeState()
        XCTAssertTrue(try state.applyRevocationList(fixtures.revocations))
        guard case .failure(.revoked) = state.install(try token("revoked")) else {
            return XCTFail("a revoked token was installed")
        }
    }

    /// None of the backend's test tokens verifies against the keys this build trusts.
    func testBackendTestTokensDoNotVerifyAgainstTheShippedKeys() throws {
        for (name, text) in fixtures.tokens {
            XCTAssertThrowsError(try LicenseVerifier.verifySignature(text, keyring: .active), name)
        }
        XCTAssertThrowsError(try RevocationVerifier.verify(fixtures.revocations, keyring: .active))
    }
}
