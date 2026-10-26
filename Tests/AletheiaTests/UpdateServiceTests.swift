import XCTest
import AppKit
@testable import Aletheia

private final class FakeChecker: UpdateChecking, @unchecked Sendable {
    var result: Result<ReleaseInfo, Error>
    private(set) var fetchCount = 0

    init(_ result: Result<ReleaseInfo, Error>) { self.result = result }

    func fetchLatest() async throws -> ReleaseInfo {
        fetchCount += 1
        return try result.get()
    }
}

private final class RecordingInstaller: UpdateInstalling {
    private(set) var installed: [String] = []
    @MainActor func install(_ release: ReleaseInfo) { installed.append(release.version) }
}

private func makeRelease(_ version: String) -> ReleaseInfo {
    ReleaseInfo(
        version: version,
        downloadURL: URL(string: "https://example.com/Aletheia-\(version).dmg")!,
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

    private func makeService(checker: UpdateChecking, installer: UpdateInstalling = RecordingInstaller()) -> UpdateService {
        UpdateService(
            checker: checker,
            installer: installer,
            currentVersion: SemanticVersion(major: 1, minor: 0, patch: 0),
            defaults: defaults,
            minimumInterval: 1800
        )
    }

    func testOffersNewerVersion() async {
        let service = makeService(checker: FakeChecker(.success(makeRelease("1.1.0"))))
        await service.checkForUpdates(force: true)
        XCTAssertEqual(service.available?.version, "1.1.0")
    }

    func testDoesNotOfferSameOrOlderVersion() async {
        let same = makeService(checker: FakeChecker(.success(makeRelease("1.0.0"))))
        await same.checkForUpdates(force: true)
        XCTAssertNil(same.available)

        let older = makeService(checker: FakeChecker(.success(makeRelease("0.9.0"))))
        await older.checkForUpdates(force: true)
        XCTAssertNil(older.available)
    }

    func testSkippedVersionIsNotOfferedAgain() async {
        let service = makeService(checker: FakeChecker(.success(makeRelease("1.2.0"))))
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
        let checker = FakeChecker(.success(makeRelease("1.1.0")))
        let service = makeService(checker: checker)

        await service.checkForUpdates(force: true)   // counts
        await service.checkForUpdates(force: false)  // throttled, should not refetch
        XCTAssertEqual(checker.fetchCount, 1)

        await service.checkForUpdates(force: true)   // forced, refetches
        XCTAssertEqual(checker.fetchCount, 2)
    }

    func testInstallStartsTheDownloadAndClosesThePrompt() async {
        let installer = RecordingInstaller()
        let service = makeService(checker: FakeChecker(.success(makeRelease("1.1.0"))), installer: installer)
        await service.checkForUpdates(force: true)
        XCTAssertNotNil(service.available)

        service.installAvailableUpdate()

        XCTAssertEqual(installer.installed, ["1.1.0"])
        XCTAssertNil(service.available, "the prompt closes so the app can be quit")
    }

    func testDownloadedVersionIsNotOfferedAgainThisRun() async {
        let service = makeService(checker: FakeChecker(.success(makeRelease("1.1.0"))))
        await service.checkForUpdates(force: true)
        service.installAvailableUpdate()

        await service.checkForUpdates(force: true)
        XCTAssertNil(service.available)
    }

    func testNewerVersionAfterADownloadIsStillOffered() async {
        let checker = FakeChecker(.success(makeRelease("1.1.0")))
        let service = makeService(checker: checker)
        await service.checkForUpdates(force: true)
        service.installAvailableUpdate()

        checker.result = .success(makeRelease("1.2.0"))
        await service.checkForUpdates(force: true)
        XCTAssertEqual(service.available?.version, "1.2.0")
    }

    func testInstallWithNothingAvailableDoesNothing() {
        let installer = RecordingInstaller()
        let service = makeService(checker: FakeChecker(.success(makeRelease("1.1.0"))), installer: installer)
        service.installAvailableUpdate()
        XCTAssertTrue(installer.installed.isEmpty)
    }

    func testManualCheckWhenUpToDateRecordsResult() async {
        let service = makeService(checker: FakeChecker(.success(makeRelease("1.0.0"))))
        await service.checkForUpdates(force: true)
        if case .upToDate(let checkedAt) = service.manualCheckResult {
            XCTAssertLessThanOrEqual(checkedAt.timeIntervalSinceNow, 1.0)
        } else {
            XCTFail("Expected .upToDate manualCheckResult, got \(String(describing: service.manualCheckResult))")
        }
        XCTAssertNil(service.available, "nothing is offered")
    }

    func testAutomaticCheckDoesNotRecordAResult() async {
        let service = makeService(checker: FakeChecker(.success(makeRelease("1.0.0"))))
        await service.checkForUpdates(force: false)
        XCTAssertNil(service.manualCheckResult)
    }

    func testManualCheckWhenUpdateAvailableRecordsResult() async {
        let service = makeService(checker: FakeChecker(.success(makeRelease("1.1.0"))))
        await service.checkForUpdates(force: true)
        XCTAssertEqual(service.manualCheckResult, .updateAvailable(version: "1.1.0"))
        XCTAssertEqual(service.available?.version, "1.1.0")
    }

    func testManualCheckFailureRecordsCouldNotCheck() async {
        let service = makeService(checker: FakeChecker(.failure(URLError(.notConnectedToInternet))))
        await service.checkForUpdates(force: true)
        if case .couldNotCheck(let reason) = service.manualCheckResult {
            XCTAssertFalse(reason.isEmpty)
        } else {
            XCTFail("Expected .couldNotCheck, got \(String(describing: service.manualCheckResult))")
        }
        XCTAssertNil(service.available)
    }

    private let goodDownload = URL(string: "https://github.com/mgwedd/aletheia/releases/download/v1.2.0/Aletheia.dmg")!

    func testReleasesOpenAletheiasDownloadPageOnAstreaLabs() {
        let page = ReleaseLink.downloadsPage
        XCTAssertEqual(page.scheme, "https")
        XCTAssertEqual(page.host, "astrealabs.com")
        XCTAssertEqual(page.path, "/aletheia/download")
        XCTAssertNil(page.query)
        XCTAssertNil(page.fragment)
    }

    /// Links in the feed are ignored: a page URL in it is not even decoded.
    @MainActor
    func testFeedLinksAreNeverOpened() throws {
        let json = #"{"version":"1.2.0","downloadURL":"https://evil.example/x.dmg","releaseNotes":"n","releasePageURL":"file:///etc/passwd"}"#
        let release = try JSONDecoder().decode(ReleaseInfo.self, from: Data(json.utf8))
        var opened: [URL] = []
        GuidedDownloadInstaller(open: { opened.append($0) }).install(release)
        XCTAssertEqual(opened, [ReleaseLink.downloadsPage])
    }

    @MainActor
    func testInstallerFallsBackToTheDownloadsPage() async {
        var opened: [URL] = []
        let done = expectation(description: "fallback opened")
        let installer = GuidedDownloadInstaller(helper: FailingHelper(), open: { opened.append($0); done.fulfill() })
        installer.install(ReleaseInfo(
            version: "1.2.0", downloadURL: goodDownload, releaseNotes: "Notes", sha256: String(repeating: "a", count: 64)
        ))
        await fulfillment(of: [done], timeout: 10)
        XCTAssertEqual(opened, [ReleaseLink.downloadsPage])
    }

    /// Nothing in the app links to GitHub releases any more.
    /// No alert or sheet opens by itself: a newer version shows as a banner, and
    /// the full prompt opens only from it.
    func testUpdatesNeverInterruptTheMainWindow() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/App/Views/RootView.swift"), encoding: .utf8)
        XCTAssertFalse(text.contains("You're Up to Date"))
        XCTAssertTrue(text.contains("UpdateBanner("))
        XCTAssertTrue(text.contains("showUpdateDetails && updateService.available != nil"))
        XCTAssertEqual(UpdateBanner.text(for: ReleaseInfo(
            version: "1.2.0", downloadURL: goodDownload, releaseNotes: "")), "Aletheia 1.2.0 is available.")
    }

    func testNoScreenLinksToGitHubReleases() throws {
        let repo = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for file in ["Views/UpdatePromptView.swift", "Views/SettingsView.swift", "Services/Updates/UpdateInstalling.swift", "Services/Updates/UpdateChecking.swift"] {
            let text = try String(contentsOf: repo.appendingPathComponent("Sources/App/\(file)"), encoding: .utf8)
            XCTAssertFalse(text.contains("github.com"), file)
        }
    }

    func testAppSettingsAutoCheckForUpdatesDefaultAndPersistence() {
        let original = AppSettings.shared.autoCheckForUpdates
        defer { AppSettings.shared.autoCheckForUpdates = original }

        AppSettings.shared.autoCheckForUpdates = false
        XCTAssertFalse(AppSettings.shared.autoCheckForUpdates)

        AppSettings.shared.autoCheckForUpdates = true
        XCTAssertTrue(AppSettings.shared.autoCheckForUpdates)
    }
}

final class UpdatePromptLayoutTests: XCTestCase {
    /// Mirrors `Theme.Typography.control` (system 13, medium).
    private let controlFont = NSFont.systemFont(ofSize: 13, weight: .medium)
    /// Horizontal padding of a themed button (12 each side).
    private let chrome: CGFloat = 24

    private func width(of label: String) -> CGFloat {
        ceil((label as NSString).size(withAttributes: [.font: controlFont]).width) + chrome
    }

    private func rowWidth(_ labels: [String], spacing: CGFloat) -> CGFloat {
        labels.map(width(of:)).reduce(0, +) + spacing * CGFloat(max(labels.count - 1, 0))
    }

    func testEveryActionRowFitsWithRoomToSpare() {
        // 15% slack for fonts and text sizes that run wider than measured here.
        let available = UpdatePromptLayout.contentWidth * 0.85
        for row in UpdatePromptLayout.rows {
            XCTAssertLessThanOrEqual(
                rowWidth(row, spacing: 16), available,
                "\(row) needs more than the prompt offers; its labels would truncate"
            )
        }
    }

    func testAllFourActionsAreOnOfferedRows() {
        XCTAssertEqual(
            Set(UpdatePromptLayout.rows.flatMap { $0 }),
            [UpdatePromptLayout.viewDownloads, UpdatePromptLayout.skip, UpdatePromptLayout.later, UpdatePromptLayout.download]
        )
    }

    /// The reported bug: all four controls in one row do not fit, which is why
    /// they are split across two.
    func testAllFourInOneRowWouldNotFit() {
        let single = UpdatePromptLayout.rows.flatMap { $0 }
        XCTAssertGreaterThan(rowWidth(single, spacing: UpdatePromptLayout.rowSpacing), UpdatePromptLayout.contentWidth)
    }
}

/// A helper whose every call fails, so the installer takes its fallback.
private struct FailingHelper: NetworkHelping {
    struct Failure: Error {}
    func fetchAppcast() async throws -> Data { throw Failure() }
    func fetchRevocations() async throws -> Data { throw Failure() }
    func download(
        _ asset: AssetID, expectedSHA256: String, to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws { throw Failure() }
}
