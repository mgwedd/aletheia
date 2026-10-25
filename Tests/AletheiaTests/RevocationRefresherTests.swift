import CryptoKit
import XCTest
@testable import Aletheia

@MainActor
final class RevocationRefresherTests: XCTestCase {
    private let now = LicenseTestMint.now
    private let day = LicenseTestMint.day
    private var key: Curve25519.Signing.PrivateKey!
    private var ring: LicenseKeyring!
    private var suite: String!
    private var defaults: UserDefaults!
    private var settings: AppSettings!
    private var clock: Date!

    /// Counts fetches and serves `body` (or throws `failure`).
    private final class FakeFetch: @unchecked Sendable {
        var body = Data()
        var failure: Error?
        private(set) var calls = 0
        func callAsFunction() throws -> Data {
            calls += 1
            if let failure { throw failure }
            return body
        }
    }

    override func setUp() {
        (key, ring) = LicenseTestMint.freshKeyring()
        suite = "RevocationRefresherTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        settings = AppSettings(defaults: defaults)
        settings.autoCheckForUpdates = true
        clock = now
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    private func make(_ fake: FakeFetch) -> (RevocationRefresher, LicenseState) {
        let state = LicenseState(settings: settings, keyring: ring, now: { [unowned self] in self.clock })
        let refresher = RevocationRefresher(
            settings: settings, license: state, fetch: { try fake() }, now: { [unowned self] in self.clock })
        return (refresher, state)
    }

    private func installToken(_ state: LicenseState, lid: String) throws {
        let text = try LicenseTestMint.token(
            LicenseTestMint.payload(lid: lid, exp: now.addingTimeInterval(80 * day)), key: key)
        guard case .success = state.install(text) else { return XCTFail("token refused") }
    }

    private func listData(iat: Date, revoked: [String]) throws -> Data {
        Data(try LicenseTestMint.revocationList(iat: iat, revoked: revoked, key: key).utf8)
    }

    func testAFetchedListRevokesTheInstalledLicense() async throws {
        let fake = FakeFetch()
        let (refresher, state) = make(fake)
        try installToken(state, lid: LicenseTestMint.sampleLID)
        fake.body = try listData(iat: now, revoked: [LicenseTestMint.sampleLID])

        let accepted = await refresher.refreshIfDue()
        XCTAssertTrue(accepted)
        guard case .revoked = state.status else { return XCTFail("status is \(state.status)") }
        XCTAssertEqual(settings.lastRevocationCheck, now)
    }

    func testNothingIsFetchedWhileUpdateChecksAreOff() async throws {
        settings.autoCheckForUpdates = false
        let fake = FakeFetch()
        let (refresher, _) = make(fake)
        let accepted = await refresher.refreshIfDue()
        XCTAssertFalse(accepted)
        XCTAssertEqual(fake.calls, 0)
        XCTAssertNil(settings.lastRevocationCheck)
    }

    func testAtMostOneFetchPerDayAcrossLaunches() async throws {
        let fake = FakeFetch()
        fake.body = try listData(iat: now, revoked: [])
        await make(fake).0.refreshIfDue()
        XCTAssertEqual(fake.calls, 1)

        // A new launch (a new refresher on the same settings) inside the day.
        clock = now.addingTimeInterval(day - 1)
        await make(fake).0.refreshIfDue()
        XCTAssertEqual(fake.calls, 1)

        clock = now.addingTimeInterval(day)
        await make(fake).0.refreshIfDue()
        XCTAssertEqual(fake.calls, 2)
    }

    func testAFailedFetchStillCountsAsTodaysCheckAndChangesNothing() async throws {
        let fake = FakeFetch()
        fake.failure = URLError(.badServerResponse)
        let (refresher, state) = make(fake)
        try installToken(state, lid: LicenseTestMint.sampleLID)

        let accepted = await refresher.refreshIfDue()
        XCTAssertFalse(accepted)
        XCTAssertEqual(fake.calls, 1)
        XCTAssertEqual(settings.lastRevocationCheck, now)
        guard case .valid = state.status else { return XCTFail("status is \(state.status)") }
        XCTAssertFalse(refresher.isDue)
    }

    func testAListSignedByAnUnknownKeyIsIgnored() async throws {
        let fake = FakeFetch()
        let (refresher, state) = make(fake)
        try installToken(state, lid: LicenseTestMint.sampleLID)
        let stranger = Curve25519.Signing.PrivateKey()
        fake.body = Data(try LicenseTestMint.revocationList(iat: now, revoked: [LicenseTestMint.sampleLID], key: stranger).utf8)

        let accepted = await refresher.refreshIfDue()
        XCTAssertFalse(accepted)
        guard case .valid = state.status else { return XCTFail("status is \(state.status)") }
        XCTAssertEqual(settings.revokedLicenseIDs, [])
    }

    /// A license revoked in error is restored by the next list that leaves it out.
    func testALaterListWithoutTheLicenseRestoresIt() async throws {
        let fake = FakeFetch()
        let (refresher, state) = make(fake)
        try installToken(state, lid: LicenseTestMint.sampleLID)
        fake.body = try listData(iat: now, revoked: [LicenseTestMint.sampleLID])
        await refresher.refreshIfDue()
        guard case .revoked = state.status else { return XCTFail("status is \(state.status)") }
        XCTAssertNotNil(state.newWorkRefusal)

        clock = now.addingTimeInterval(day)
        fake.body = try listData(iat: now.addingTimeInterval(day), revoked: [])
        let accepted = await refresher.refreshIfDue()
        XCTAssertTrue(accepted)
        guard case .valid = state.status else { return XCTFail("status is \(state.status)") }
        XCTAssertNil(state.newWorkRefusal)
        XCTAssertEqual(settings.revokedLicenseIDs, [])
    }

    func testAnOlderListIsIgnored() async throws {
        let fake = FakeFetch()
        let (refresher, state) = make(fake)
        XCTAssertTrue(try state.applyRevocationList(LicenseTestMint.revocationList(iat: now, revoked: [], key: key)))
        fake.body = try listData(iat: now.addingTimeInterval(-day), revoked: [LicenseTestMint.sampleLID])

        let accepted = await refresher.refreshIfDue()
        XCTAssertFalse(accepted)
        XCTAssertEqual(settings.revokedLicenseIDs, [])
    }

    func testAClockSetBackBeforeTheLastCheckMakesACheckDue() async throws {
        let fake = FakeFetch()
        fake.body = try listData(iat: now, revoked: [])
        let (refresher, _) = make(fake)
        await refresher.refreshIfDue()
        clock = now.addingTimeInterval(-60)
        XCTAssertTrue(refresher.isDue)
        await refresher.refreshIfDue()
        XCTAssertEqual(fake.calls, 2)
    }
}
