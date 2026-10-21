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

    func testManualCheckWhenUpToDateRecordsResultAndNotice() async {
        let service = makeService(checker: FakeChecker(.success(makeRelease("1.0.0"))))
        await service.checkForUpdates(force: true)
        if case .upToDate(let checkedAt) = service.manualCheckResult {
            XCTAssertLessThanOrEqual(checkedAt.timeIntervalSinceNow, 1.0)
        } else {
            XCTFail("Expected .upToDate manualCheckResult, got \(String(describing: service.manualCheckResult))")
        }
        XCTAssertEqual(service.manualNotice, .upToDate(currentVersion: "1.0.0"))
    }

    func testAutomaticCheckDoesNotRecordManualNoticeOrResult() async {
        let service = makeService(checker: FakeChecker(.success(makeRelease("1.0.0"))))
        await service.checkForUpdates(force: false)
        XCTAssertNil(service.manualCheckResult)
        XCTAssertNil(service.manualNotice)
    }

    func testManualCheckWhenUpdateAvailableRecordsResultAndClearsNotice() async {
        let service = makeService(checker: FakeChecker(.success(makeRelease("1.1.0"))))
        await service.checkForUpdates(force: true)
        XCTAssertEqual(service.manualCheckResult, .updateAvailable(version: "1.1.0"))
        XCTAssertNil(service.manualNotice)
    }

    func testManualCheckFailureRecordsCouldNotCheck() async {
        let service = makeService(checker: FakeChecker(.failure(URLError(.notConnectedToInternet))))
        await service.checkForUpdates(force: true)
        if case .couldNotCheck(let reason) = service.manualCheckResult {
            XCTAssertFalse(reason.isEmpty)
        } else {
            XCTFail("Expected .couldNotCheck, got \(String(describing: service.manualCheckResult))")
        }
        if case .couldNotCheck(let reason) = service.manualNotice {
            XCTAssertFalse(reason.isEmpty)
        } else {
            XCTFail("Expected .couldNotCheck notice, got \(String(describing: service.manualNotice))")
        }

        service.clearManualNotice()
        XCTAssertNil(service.manualNotice)
    }

    func testReleasePageOrWebURLFallback() {
        let customURL = URL(string: "https://example.com/custom-release")!
        let withPage = ReleaseInfo(
            version: "1.2.0",
            downloadURL: URL(string: "https://github.com/mgwedd/aletheia/releases/download/v1.2.0/Aletheia.dmg")!,
            releaseNotes: "Notes",
            releasePageURL: customURL
        )
        XCTAssertEqual(withPage.releasePageOrWebURL, customURL)

        let gitHubWithoutPage = ReleaseInfo(
            version: "1.2.0",
            downloadURL: URL(string: "https://github.com/mgwedd/aletheia/releases/download/v1.2.0/Aletheia.dmg")!,
            releaseNotes: "Notes"
        )
        XCTAssertEqual(
            gitHubWithoutPage.releasePageOrWebURL,
            URL(string: "https://github.com/mgwedd/aletheia/releases/tag/v1.2.0")!
        )

        let thirdParty = ReleaseInfo(
            version: "1.2.0",
            downloadURL: URL(string: "https://mycdn.example.org/downloads/Aletheia.dmg")!,
            releaseNotes: "Notes"
        )
        XCTAssertEqual(
            thirdParty.releasePageOrWebURL,
            URL(string: "https://mycdn.example.org/downloads/Aletheia.dmg")!
        )
    }

    func testCodeSigningStatusInspectorAndDescriptions() {
        let notarized = CodeSigningStatus.current(inspector: { .developerIDNotarized(teamID: "ABCDE12345") })
        XCTAssertEqual(notarized, .developerIDNotarized(teamID: "ABCDE12345"))
        XCTAssertTrue(notarized.description.contains("Developer ID signed and notarized"))

        let adHoc = CodeSigningStatus.current(inspector: { .adHoc })
        XCTAssertEqual(adHoc, .adHoc)
        XCTAssertTrue(adHoc.description.contains("Ad-hoc"))

        let dev = CodeSigningStatus.current(inspector: { .devBuild })
        XCTAssertEqual(dev, .devBuild)
        XCTAssertTrue(dev.description.contains("Development build"))

        let unsigned = CodeSigningStatus.current(inspector: { .unsigned })
        XCTAssertEqual(unsigned, .unsigned)
        XCTAssertTrue(unsigned.description.contains("Unsigned build"))

        let other = CodeSigningStatus.current(inspector: { .other("Apple Development") })
        XCTAssertEqual(other, .other("Apple Development"))
        XCTAssertTrue(other.description.contains("Apple Development"))
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
            [UpdatePromptLayout.viewOnGitHub, UpdatePromptLayout.skip, UpdatePromptLayout.later, UpdatePromptLayout.download]
        )
    }

    /// The reported bug: all four controls in one row do not fit, which is why
    /// they are split across two.
    func testAllFourInOneRowWouldNotFit() {
        let single = UpdatePromptLayout.rows.flatMap { $0 }
        XCTAssertGreaterThan(rowWidth(single, spacing: UpdatePromptLayout.rowSpacing), UpdatePromptLayout.contentWidth)
    }
}
