@testable import Aletheia
import Foundation
import XCTest

// MARK: - Fakes

private final class FeedFake: UpdateChecking, @unchecked Sendable {
    var result: Result<ReleaseInfo, Error>
    private(set) var fetchCount = 0
    init(_ result: Result<ReleaseInfo, Error>) { self.result = result }
    func fetchLatest() async throws -> ReleaseInfo {
        fetchCount += 1
        return try result.get()
    }
}

private final class HelperFake: NetworkHelping, @unchecked Sendable {
    struct Download: Equatable { let asset: AssetID; let sha256: String }
    var failure: Error?
    private(set) var downloads: [Download] = []
    func fetchAppcast() async throws -> Data { Data() }
    func fetchRevocations() async throws -> Data { Data() }
    func download(
        _ asset: AssetID, expectedSHA256: String, to destination: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws {
        downloads.append(Download(asset: asset, sha256: expectedSHA256))
        if let failure { throw failure }
    }
}

// MARK: - Subjects

/// Records what the installer would open, instead of opening it.
private final class OpenLog: @unchecked Sendable {
    var urls: [URL] = []
}

/// An update service wired to a fake feed and fake network helper, with its own
/// defaults. Nothing is opened for real.
@MainActor
final class UpdateRig {
    fileprivate let feed: FeedFake
    fileprivate let helper = HelperFake()
    fileprivate let log = OpenLog()
    let service: UpdateService
    private let suite = "aletheia-acceptance-update-\(UUID().uuidString)"
    private let defaults: UserDefaults
    let downloads: URL

    fileprivate init(feed: Result<ReleaseInfo, Error>, interval: TimeInterval?) {
        let fake = FeedFake(feed)
        self.feed = fake
        let helper = self.helper
        let defaults = UserDefaults(suiteName: suite)!
        self.defaults = defaults
        downloads = FileManager.default.temporaryDirectory
            .appendingPathComponent("aletheia-acceptance-updates-\(UUID().uuidString)", isDirectory: true)
        let log = self.log
        var installer = GuidedDownloadInstaller(helper: helper)
        installer.downloadsDirectory = downloads
        installer.open = { log.urls.append($0) }
        let current = SemanticVersion(major: 1, minor: 0, patch: 0)
        service = interval.map {
            UpdateService(checker: fake, installer: installer, currentVersion: current, defaults: defaults, minimumInterval: $0)
        } ?? UpdateService(checker: fake, installer: installer, currentVersion: current, defaults: defaults)
    }

    var fetchCount: Int { feed.fetchCount }
    var opened: [URL] { log.urls }
    var downloadRequests: [(asset: AssetID, sha256: String)] { helper.downloads.map { ($0.asset, $0.sha256) } }
    fileprivate func helperFails(_ error: Error) { helper.failure = error }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: downloads)
    }
}

/// What the update prompt offers.
struct UpdatePrompt {
    let release: ReleaseInfo?
    let buttons: [String]
}

/// What the manual-check alert says.
struct UpdateDownload {
    let rig: UpdateRig
}

struct UpdateAlert {
    let notice: UpdateService.ManualNotice?
    let result: UpdateService.ManualCheckResult?
}

// MARK: - Given

/// What the update feed says.
enum UpdateFeedState {
    case sameVersion
    case newerRelease
    case unreachable
}

// MARK: - When

extension When {
    /// The running version is 1.0.0. `interval` of nil keeps the app's own throttle.
    func updateRig(feed: UpdateFeedState, interval: TimeInterval? = 0) -> UpdateRig {
        UpdateRig(feed: Self.result(of: feed), interval: interval)
    }

    private static func result(of feed: UpdateFeedState) -> Result<ReleaseInfo, Error> {
        switch feed {
        case .sameVersion: return .success(release("1.0.0"))
        case .newerRelease: return .success(release("1.1.0"))
        case .unreachable: return .failure(URLError(.notConnectedToInternet))
        }
    }

    private static func release(_ version: String, sha256: String? = nil) -> ReleaseInfo {
        ReleaseInfo(
            version: version,
            downloadURL: URL(string: "https://example.com/Aletheia-\(version).dmg")!,
            releaseNotes: "Notes for \(version)",
            minimumSystemVersion: "14.0",
            publishedAt: nil,
            sha256: sha256)
    }

    func checkManually(_ rig: UpdateRig) async -> UpdateAlert {
        await rig.service.checkForUpdates(force: true)
        return UpdateAlert(notice: rig.service.manualNotice, result: rig.service.manualCheckResult)
    }

    func checkAutomatically(_ rig: UpdateRig) async { await rig.service.checkForUpdates() }

    func lookAtPrompt(_ rig: UpdateRig) -> UpdatePrompt {
        UpdatePrompt(release: rig.service.available, buttons: UpdatePromptLayout.rows.flatMap { $0 })
    }

    func remindLater(_ rig: UpdateRig) { rig.service.dismiss() }
    func skipVersion(_ rig: UpdateRig) { rig.service.skipAvailableVersion() }

    /// Clicks Download update with a network helper and browser that are fakes.
    func downloadUpdate(checksumListed: Bool, checksumMatches: Bool = true) async -> UpdateDownload {
        let rig = UpdateRig(feed: .success(Self.release("1.1.0", sha256: checksumListed ? Self.digest : nil)), interval: 0)
        if !checksumMatches { rig.helperFails(URLError(.cannotParseResponse)) }
        await rig.service.checkForUpdates(force: true)
        rig.service.installAvailableUpdate()
        for _ in 0..<100 where rig.opened.isEmpty { try? await Task.sleep(nanoseconds: 20_000_000) }
        return UpdateDownload(rig: rig)
    }

    static let digest = String(repeating: "ab", count: 32)

    var currentSigningDescription: String { CodeSigningStatus.current().description }
    var automaticChecksDefault: Bool { app.settings.autoCheckForUpdates }
}

// MARK: - Then

extension Then where Subject == UpdateAlert {
    func saysUpToDate() {
        expectEqual(subject.notice?.title, Copy.upToDateTitle, "the alert title")
        if case .upToDate = subject.result {} else { fail("Settings should say you are up to date, found \(String(describing: subject.result))") }
    }

    func saysCouldNotCheck() {
        expectEqual(subject.notice?.title, Copy.couldNotCheckTitle, "the alert title")
        if case .couldNotCheck = subject.result {} else { fail("Settings should say the check failed, found \(String(describing: subject.result))") }
    }
}

extension Then where Subject == UpdatePrompt {
    func offers(version: String) {
        expectEqual(subject.release?.version, version, "the offered version")
    }

    func offersNothing() { expect(subject.release == nil, "no update should be offered, found \(subject.release?.version ?? "")") }

    func hasButtons(_ names: [String]) {
        expectEqual(Set(subject.buttons), Set(names), "the prompt's controls")
    }
}

@MainActor extension Then where Subject == UpdateDownload {
    func downloadedAndOpenedDiskImage() {
        expectEqual(subject.rig.downloadRequests.first?.asset, AssetID.updateArchive, "the downloaded asset")
        expectEqual(subject.rig.downloadRequests.first?.sha256, When.digest, "the digest the download is checked against")
        expectEqual(subject.rig.opened.map(\.pathExtension), ["dmg"], "the opened file")
        expect(subject.rig.service.available == nil, "the prompt should close")
    }

    func openedReleasePage() {
        expectEqual(subject.rig.opened, [ReleaseLink.downloadsPage], "the page opened after a failed verification")
    }
}

@MainActor extension Then where Subject == UpdateDownload {
    func downloadedNothingAndOpenedReleasePage() {
        expect(subject.rig.downloadRequests.isEmpty, "nothing should be downloaded without a checksum")
        expectEqual(subject.rig.opened, [ReleaseLink.downloadsPage], "the page opened")
    }
}

@MainActor extension Then where Subject == UpdateRig {
    func checkedTheFeed(_ times: Int) { expectEqual(subject.fetchCount, times, "feed checks") }
}

extension Then where Subject == String {
    func isNotarizationText() { expect(!subject.isEmpty, "the Notarization row should say something") }
}

extension Then where Subject == Bool {
    func isOn(_ what: String) { expect(subject, "\(what) should be on") }
}
