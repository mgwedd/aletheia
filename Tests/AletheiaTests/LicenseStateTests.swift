import CryptoKit
import XCTest
@testable import Aletheia

@MainActor
final class LicenseStateTests: XCTestCase {
    private let now = LicenseTestMint.now
    private let day = LicenseTestMint.day
    private var key: Curve25519.Signing.PrivateKey!
    private var ring: LicenseKeyring!
    private var defaults: UserDefaults!
    private var suite: String!
    private var settings: AppSettings!
    private var clock: Date!

    override func setUp() {
        (key, ring) = LicenseTestMint.freshKeyring()
        suite = "LicenseStateTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        settings = AppSettings(defaults: defaults)
        clock = now
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func makeState() -> LicenseState {
        LicenseState(settings: settings, keyring: ring, now: { [unowned self] in self.clock })
    }

    private func token(exp: Date? = nil, lid: String = "lid-1", sub: String = "a@example.com") throws -> String {
        try LicenseTestMint.token(
            LicenseTestMint.payload(lid: lid, sub: sub, exp: exp ?? now.addingTimeInterval(80 * day)), key: key)
    }

    private func list(iat: Date, revoked: [String]) throws -> String {
        try LicenseTestMint.revocationList(iat: iat, revoked: revoked, key: key)
    }

    func testNoTokenIsUnlicensedAndBlocksNewWork() {
        let state = makeState()
        XCTAssertEqual(state.status, .unlicensed)
        XCTAssertNotNil(state.newWorkRefusal)
        XCTAssertThrowsError(try state.authorizeNewWork()) { XCTAssertTrue($0 is LicenseBlockedError) }
    }

    func testInstallStoresAValidTokenAndAllowsNewWork() throws {
        let state = makeState()
        let text = try token()
        guard case .success(let installed) = state.install("  \(text)\n") else { return XCTFail("expected success") }
        XCTAssertEqual(installed.sub, "a@example.com")
        XCTAssertEqual(settings.licenseToken, text, "stored trimmed, in preferences")
        XCTAssertEqual(defaults.string(forKey: "licenseToken"), text)
        XCTAssertEqual(state.status, .valid(installed))
        XCTAssertNil(state.newWorkRefusal)
        XCTAssertNoThrow(try state.authorizeNewWork())
    }

    func testStoredTokenSurvivesARelaunch() throws {
        _ = makeState().install(try token())
        let relaunched = LicenseState(
            settings: AppSettings(defaults: defaults), keyring: ring, now: { [unowned self] in self.clock })
        XCTAssertTrue(relaunched.status.isActive)
    }

    func testAFailingTokenNeverReplacesTheOneInUse() throws {
        let state = makeState()
        let good = try token()
        state.install(good)
        let expired = try token(exp: now.addingTimeInterval(-day))
        guard case .failure(let error) = state.install(expired) else { return XCTFail("expected failure") }
        XCTAssertEqual(error, .expired(now.addingTimeInterval(-day)))
        guard case .failure(let bad) = state.install("ALET1.x.y") else { return XCTFail("expected failure") }
        XCTAssertEqual(bad, .malformed)
        XCTAssertEqual(settings.licenseToken, good)
        XCTAssertTrue(state.status.isActive)
    }

    func testWarnsFromFourteenDaysBeforeExpiry() throws {
        let state = makeState()
        state.install(try token(exp: now.addingTimeInterval(20 * day)))
        XCTAssertEqual(state.status.token?.sub, "a@example.com")
        guard case .valid = state.status else { return XCTFail("20 days left should not warn") }
        XCTAssertNil(LicenseBanner.text(for: state.status))

        clock = now.addingTimeInterval(6 * day + 3600)   // 13 days and a bit left
        state.refresh()
        guard case .expiringSoon(_, let days) = state.status else { return XCTFail("should be warning") }
        XCTAssertEqual(days, 14)
        XCTAssertNotNil(LicenseBanner.text(for: state.status))
        XCTAssertNil(state.newWorkRefusal, "a warning never blocks anything")
    }

    func testExpiryBlocksNewWorkButKeepsTheLicenseeVisible() throws {
        let state = makeState()
        state.install(try token(exp: now.addingTimeInterval(2 * day)))
        clock = now.addingTimeInterval(17 * day)   // past the 14-day grace period
        state.refresh()
        guard case .expired(let token) = state.status else { return XCTFail("expected expired") }
        XCTAssertEqual(token.sub, "a@example.com")
        let refusal = try XCTUnwrap(state.newWorkRefusal)
        XCTAssertTrue(refusal.contains("existing records are untouched"))
        XCTAssertTrue(LicenseBanner.text(for: state.status)?.contains("stays open") ?? false)
    }

    func testBadStoredTokenIsInvalidNotCrashing() {
        // A token whose payload is not JSON.
        settings.licenseToken = ["ALET1", Base64URL.encode(Data("notjson".utf8)), "AAAA"].joined(separator: ".")
        let state = makeState()
        XCTAssertEqual(state.status, .invalid(.malformed))
        XCTAssertNotNil(state.newWorkRefusal)
    }

    func testClockWellBehindIssueDateIsInvalid() throws {
        let state = makeState()
        state.install(try token())
        clock = now.addingTimeInterval(-30 * day)   // token was "issued" 20 days in the future
        state.refresh()
        XCTAssertEqual(state.status, .invalid(.issuedInFuture))
    }

    func testExpiryWhileTheAppStaysOpenBlocksNewWork() throws {
        let state = makeState()
        state.install(try token(exp: now.addingTimeInterval(80 * day)))
        XCTAssertNil(state.newWorkRefusal)
        clock = now.addingTimeInterval(95 * day)   // past grace; no refresh(), no app activation
        XCTAssertNotNil(state.newWorkRefusal)
        guard case .expired = state.status else { return XCTFail("expected expired") }
    }

    func testATokenExpiresAtExactlyItsExpiryTime() throws {
        let state = makeState()
        state.install(try token(exp: now.addingTimeInterval(day)))
        clock = now.addingTimeInterval(day - 1)
        guard case .expiringSoon = state.status else { return XCTFail("status is \(state.status)") }
        clock = now.addingTimeInterval(day)
        XCTAssertNil(state.newWorkRefusal, "expiry starts the grace period, not a block")
        guard case .gracePeriod = state.status else { return XCTFail("status is \(state.status)") }
    }

    // MARK: - Grace period

    func testTheGracePeriodKeepsWorkGoingForFourteenDaysWithABanner() throws {
        let state = makeState()
        state.install(try token(exp: now.addingTimeInterval(day)))
        clock = now.addingTimeInterval(day + 3600)   // just expired
        guard case .gracePeriod(let token, let days) = { state.refresh(); return state.status }() else {
            return XCTFail("status is \(state.status)")
        }
        XCTAssertEqual(days, 14)
        XCTAssertEqual(token.sub, "a@example.com")
        XCTAssertTrue(state.status.isActive)
        XCTAssertNil(state.newWorkRefusal)
        XCTAssertNoThrow(try state.authorizeNewWork())
        let banner = try XCTUnwrap(LicenseBanner.text(for: state.status))
        XCTAssertTrue(banner.contains("14 more days"), banner)

        clock = now.addingTimeInterval(14 * day + 3600)   // one day of grace left
        state.refresh()
        guard case .gracePeriod(_, 1) = state.status else { return XCTFail("status is \(state.status)") }
        XCTAssertTrue(LicenseBanner.text(for: state.status)?.contains("1 more day") ?? false)
    }

    func testNewWorkStopsAtExactlyTheEndOfTheGracePeriod() throws {
        let state = makeState()
        state.install(try token(exp: now.addingTimeInterval(day)))
        let graceEnds = now.addingTimeInterval(day + 14 * day)
        clock = graceEnds.addingTimeInterval(-1)
        XCTAssertNil(state.newWorkRefusal)
        clock = graceEnds
        let refusal = try XCTUnwrap(state.newWorkRefusal)
        XCTAssertTrue(refusal.contains("grace period has ended"), refusal)
        guard case .expired = state.status else { return XCTFail("status is \(state.status)") }
        XCTAssertFalse(state.status.isActive)
    }

    func testRevocationHasNoGracePeriod() throws {
        let state = makeState()
        state.install(try token(exp: now.addingTimeInterval(day), lid: "bad-lid"))
        clock = now.addingTimeInterval(2 * day)   // inside grace
        try state.applyRevocationList(try list(iat: now, revoked: ["bad-lid"]))
        guard case .revoked = state.status else { return XCTFail("status is \(state.status)") }
        XCTAssertNotNil(state.newWorkRefusal)
    }

    func testATokenInItsGracePeriodCannotBeInstalled() throws {
        let state = makeState()
        let lapsed = try token(exp: now.addingTimeInterval(-day))
        guard case .failure(.expired) = state.install(lapsed) else { return XCTFail("a lapsed key was installed") }
        XCTAssertEqual(state.status, .unlicensed)
    }

    // MARK: - Installs set up before license keys

    /// Settings for an install that finished setup on a build with no license step.
    private func upgradedInstall() -> AppSettings {
        let fresh = UserDefaults(suiteName: suite + "-upgraded")!
        fresh.removePersistentDomain(forName: suite + "-upgraded")
        fresh.set(true, forKey: "hasCompletedFirstRun")
        addTeardownBlock { fresh.removePersistentDomain(forName: self.suite + "-upgraded") }
        return AppSettings(defaults: fresh)
    }

    func testAnUpgradedInstallWithoutAKeyKeepsWorking() {
        let old = upgradedInstall()
        XCTAssertTrue(old.licenseGrandfathered)
        let state = LicenseState(settings: old, keyring: ring, now: { [unowned self] in self.clock })
        XCTAssertEqual(state.status, .grandfathered)
        XCTAssertNil(state.newWorkRefusal)
        XCTAssertNoThrow(try state.authorizeNewWork())
        XCTAssertNotNil(LicenseBanner.text(for: state.status), "it is still asked for a key")
    }

    func testAFreshInstallIsNeverGrandfathered() {
        XCTAssertFalse(settings.licenseGrandfathered)
        settings.hasCompletedFirstRun = true
        let relaunched = AppSettings(defaults: defaults)
        XCTAssertFalse(relaunched.licenseGrandfathered, "decided once, on the first launch")
        let state = LicenseState(settings: relaunched, keyring: ring, now: { [unowned self] in self.clock })
        XCTAssertEqual(state.status, .unlicensed)
        XCTAssertNotNil(state.newWorkRefusal)
    }

    func testGrandfatheringNeverCoversAnExpiredKey() throws {
        let old = upgradedInstall()
        let state = LicenseState(settings: old, keyring: ring, now: { [unowned self] in self.clock })
        state.install(try token(exp: now.addingTimeInterval(80 * day), lid: "old-lid"))
        clock = now.addingTimeInterval(95 * day)
        XCTAssertNotNil(state.newWorkRefusal)
        guard case .expired = state.status else { return XCTFail("expected expired") }
    }

    // MARK: - Revocation

    func testRevokedLicenseIsTreatedLikeExpired() throws {
        let state = makeState()
        state.install(try token(lid: "bad-lid"))
        XCTAssertTrue(try state.applyRevocationList(try list(iat: now, revoked: ["bad-lid"])))
        guard case .revoked(let token) = state.status else { return XCTFail("expected revoked") }
        XCTAssertEqual(token.lid, "bad-lid")
        XCTAssertNotNil(state.newWorkRefusal)
        XCTAssertFalse(state.status.isActive)
        XCTAssertNotNil(LicenseBanner.text(for: state.status))
    }

    func testRevocationOfAnotherLicenseChangesNothing() throws {
        let state = makeState()
        state.install(try token(lid: "mine"))
        try state.applyRevocationList(try list(iat: now, revoked: ["someone-else"]))
        XCTAssertTrue(state.status.isActive)
    }

    func testRevocationHoldsAfterRelaunchAndBlocksReinstalling() throws {
        let state = makeState()
        let text = try token(lid: "bad-lid")
        state.install(text)
        try state.applyRevocationList(try list(iat: now, revoked: ["bad-lid"]))
        let relaunched = LicenseState(
            settings: AppSettings(defaults: defaults), keyring: ring, now: { [unowned self] in self.clock })
        guard case .revoked = relaunched.status else { return XCTFail("revocation should persist") }
        guard case .failure(let error) = relaunched.install(text) else { return XCTFail("revoked key must not reinstall") }
        XCTAssertEqual(error, .revoked)
        // A re-issued key (new lid) works.
        guard case .success = relaunched.install(try token(lid: "new-lid")) else { return XCTFail("new key should install") }
        XCTAssertTrue(relaunched.status.isActive)
    }

    func testAStaleRevocationListIsIgnored() throws {
        let state = makeState()
        state.install(try token(lid: "bad-lid"))
        XCTAssertTrue(try state.applyRevocationList(try list(iat: now, revoked: [])))
        // An older list that names the license is replayed: refused.
        let old = try list(iat: now.addingTimeInterval(-day), revoked: ["bad-lid"])
        XCTAssertThrowsError(try state.applyRevocationList(old)) { XCTAssertEqual($0 as? RevocationError, .stale) }
        XCTAssertTrue(state.status.isActive)
        XCTAssertEqual(settings.lastRevocationIssuedAt, Int(now.timeIntervalSince1970))
    }

    func testANewerListReplacesTheRevokedSet() throws {
        let state = makeState()
        state.install(try token(lid: "lid-1"))
        try state.applyRevocationList(try list(iat: now, revoked: ["lid-1"]))
        XCTAssertFalse(state.status.isActive)
        XCTAssertTrue(try state.applyRevocationList(try list(iat: now.addingTimeInterval(60), revoked: [])))
        XCTAssertTrue(state.status.isActive, "un-revoked in a later list")
    }

    func testApplyingSignedListText() throws {
        let state = makeState()
        state.install(try token(lid: "bad-lid"))
        let text = try LicenseTestMint.revocationList(revoked: ["bad-lid"], key: key)
        XCTAssertTrue(try state.applyRevocationList(text))
        XCTAssertFalse(state.status.isActive)
        // A forged list is refused and changes nothing.
        let forged = try LicenseTestMint.revocationList(
            iat: now.addingTimeInterval(60), revoked: [], key: Curve25519.Signing.PrivateKey())
        XCTAssertThrowsError(try state.applyRevocationList(forged))
        XCTAssertFalse(state.status.isActive)
        // A replay of an older list is refused.
        let older = try LicenseTestMint.revocationList(iat: now.addingTimeInterval(-60), revoked: [], key: key)
        XCTAssertThrowsError(try state.applyRevocationList(older)) { XCTAssertEqual($0 as? RevocationError, .stale) }
    }

    // MARK: - Acceptance receipt

    func testReceiptRecordsTheLicenseIDAndLicensee() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("LicReceipt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        LegalReceipt.append(
            version: "v1", at: Date(timeIntervalSince1970: 0), root: root, appVersion: "1.0",
            licenseID: "lid-9", licensee: "a@example.com")
        LegalReceipt.append(version: "v1", at: Date(timeIntervalSince1970: 0), root: root, appVersion: "1.0")
        let lines = try String(contentsOf: root.appendingPathComponent(LegalReceipt.fileName), encoding: .utf8)
            .split(separator: "\n")
        let with = try JSONDecoder().decode(LegalReceipt.Entry.self, from: Data(lines[0].utf8))
        XCTAssertEqual(with.licenseID, "lid-9")
        XCTAssertEqual(with.licensee, "a@example.com")
        let without = try JSONDecoder().decode(LegalReceipt.Entry.self, from: Data(lines[1].utf8))
        XCTAssertNil(without.licenseID)
    }
}
