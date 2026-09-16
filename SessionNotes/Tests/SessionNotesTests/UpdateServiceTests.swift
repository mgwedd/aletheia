import XCTest
@testable import SessionNotes

private final class FakeChecker: UpdateChecking, @unchecked Sendable {
    var result: Result<ReleaseInfo, Error>
    private(set) var fetchCount = 0

    init(_ result: Result<ReleaseInfo, Error>) { self.result = result }

    func fetchLatest() async throws -> ReleaseInfo {
        fetchCount += 1
        return try result.get()
    }
}

private struct NoopInstaller: UpdateInstalling {
    @MainActor func install(_ release: ReleaseInfo) {}
}

private func release(_ version: String) -> ReleaseInfo {
    ReleaseInfo(
        version: version,
        downloadURL: URL(string: "https://example.com/SessionNotes-\(version).dmg")!,
        releaseNotes: "Notes for \(version)",
        minimumSystemVersion: "14.0",
        publishedAt: nil
    )
}

@MainActor
final class UpdateServiceTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "UpdateServiceTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func makeService(checker: UpdateChecking) -> UpdateService {
        UpdateService(
            checker: checker,
            installer: NoopInstaller(),
            currentVersion: SemanticVersion(major: 1, minor: 0, patch: 0),
            defaults: defaults,
            minimumInterval: 1800
        )
    }

    func testOffersNewerVersion() async {
        let service = makeService(checker: FakeChecker(.success(release("1.1.0"))))
        await service.checkForUpdates(force: true)
        XCTAssertEqual(service.available?.version, "1.1.0")
    }

    func testDoesNotOfferSameOrOlderVersion() async {
        let same = makeService(checker: FakeChecker(.success(release("1.0.0"))))
        await same.checkForUpdates(force: true)
        XCTAssertNil(same.available)

        let older = makeService(checker: FakeChecker(.success(release("0.9.0"))))
        await older.checkForUpdates(force: true)
        XCTAssertNil(older.available)
    }

    func testSkippedVersionIsNotOfferedAgain() async {
        let service = makeService(checker: FakeChecker(.success(release("1.2.0"))))
        await service.checkForUpdates(force: true)
        XCTAssertNotNil(service.available)

        service.skipAvailableVersion()
        XCTAssertNil(service.available)

        await service.checkForUpdates(force: true)
        XCTAssertNil(service.available, "a skipped version should stay suppressed")
    }

    func testErrorsAreSwallowed() async {
        let service = makeService(checker: FakeChecker(.failure(URLError(.notConnectedToInternet))))
        await service.checkForUpdates(force: true)
        XCTAssertNil(service.available)
    }

    func testThrottleSkipsRepeatCheckWithinInterval() async {
        let checker = FakeChecker(.success(release("1.1.0")))
        let service = makeService(checker: checker)

        await service.checkForUpdates(force: true)   // counts
        await service.checkForUpdates(force: false)  // throttled, should not refetch
        XCTAssertEqual(checker.fetchCount, 1)

        await service.checkForUpdates(force: true)   // forced, refetches
        XCTAssertEqual(checker.fetchCount, 2)
    }
}
