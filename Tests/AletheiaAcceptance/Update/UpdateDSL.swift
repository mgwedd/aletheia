@testable import Aletheia
import CryptoKit
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

/// The conversation with the sandboxed helper: writes `payload` into the file
/// the app hands it, as the helper would. The app's own client, which checks
/// the digest and deletes a mismatch, runs for real on top of it.
private final class HelperConnectionFake: NetworkHelperConnection, @unchecked Sendable {
    var payload = Data()
    private(set) var assets: [AssetID] = []
    func checkForUpdates() async throws -> Data { Data() }
    func fetchRevocations() async throws -> Data { Data() }
    func download(
        asset: AssetID, into file: FileHandle,
        progress: @escaping @Sendable (Int64, Int64) -> Void
    ) async throws {
        assets.append(asset)
        try file.write(contentsOf: payload)
        progress(Int64(payload.count), Int64(payload.count))
    }
}

func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
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
    fileprivate let connection = HelperConnectionFake()
    fileprivate let log = OpenLog()
    let service: UpdateService
    private let suite = "aletheia-acceptance-update-\(UUID().uuidString)"
    private let defaults: UserDefaults
    let downloads: URL

    fileprivate init(feed: Result<ReleaseInfo, Error>, interval: TimeInterval?) {
        let fake = FeedFake(feed)
        self.feed = fake
        let helper = NetworkHelperClient(connection: connection)
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
    var downloadedAssets: [AssetID] { connection.assets }
    fileprivate func helperSends(_ bytes: Data) { connection.payload = bytes }
    var archive: URL { downloads.appendingPathComponent("Aletheia-update.dmg") }
    /// Every file left in the downloads folder, including partials.
    var filesLeftBehind: [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: downloads.path)) ?? []).sorted()
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: downloads)
    }
}

/// What the update banner and the prompt it opens offer.
struct UpdatePrompt {
    let release: ReleaseInfo?
    let buttons: [String]
}

struct UpdateDownload {
    let rig: UpdateRig
}

/// What Settings says after a manual check. No alert is shown for it.
struct UpdateCheckOutcome {
    let result: UpdateService.ManualCheckResult?
    let offered: ReleaseInfo?
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

    func checkManually(_ rig: UpdateRig) async -> UpdateCheckOutcome {
        await rig.service.checkForUpdates(force: true)
        return UpdateCheckOutcome(result: rig.service.manualCheckResult, offered: rig.service.available)
    }

    func checkAutomatically(_ rig: UpdateRig) async { await rig.service.checkForUpdates() }

    func lookAtPrompt(_ rig: UpdateRig) -> UpdatePrompt {
        UpdatePrompt(release: rig.service.available, buttons: UpdatePromptLayout.rows.flatMap { $0 })
    }

    /// The banner's text and buttons, when a version is offered.
    func lookAtBanner(_ rig: UpdateRig) -> UpdatePrompt {
        UpdatePrompt(
            release: rig.service.available,
            buttons: [UpdateBanner.details, UpdatePromptLayout.later, UpdatePromptLayout.download])
    }

    func remindLater(_ rig: UpdateRig) { rig.service.dismiss() }
    func skipVersion(_ rig: UpdateRig) { rig.service.skipAvailableVersion() }

    /// Clicks Download update with a network helper and browser that are fakes.
    func downloadUpdate(checksumListed: Bool, checksumMatches: Bool = true) async throws -> UpdateDownload {
        let rig = UpdateRig(
            feed: .success(Self.release("1.1.0", sha256: checksumListed ? sha256Hex(Self.diskImage) : nil)),
            interval: 0)
        rig.helperSends(checksumMatches ? Self.diskImage : Data("not the release".utf8))
        await rig.service.checkForUpdates(force: true)
        rig.service.installAvailableUpdate()
        // The download runs in the background; wait for it to open something.
        try await eventually("the update to open something") { !rig.opened.isEmpty }
        return UpdateDownload(rig: rig)
    }

    static let diskImage = Data("pretend disk image bytes".utf8)


    /// The Software update card's rows, top to bottom.
    var softwareUpdateRows: [String] { SoftwareUpdateRow.allCases.map(\.title) }

    var automaticChecksDefault: Bool { app.settings.autoCheckForUpdates }
}

// MARK: - Then

extension Then where Subject == UpdateCheckOutcome {
    func saysUpToDate() {
        if case .upToDate = subject.result {} else { fail("Settings should say you are up to date, found \(String(describing: subject.result))") }
        expect(subject.offered == nil, "no banner should appear when up to date")
    }

    func saysCouldNotCheck() {
        if case .couldNotCheck = subject.result {} else { fail("Settings should say the check failed, found \(String(describing: subject.result))") }
        expect(subject.offered == nil, "no banner should appear when the check failed")
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

    func reads(_ text: String) {
        expectEqual(subject.release.map(UpdateBanner.text(for:)), text, "the banner text")
    }
}

@MainActor extension Then where Subject == UpdateDownload {
    func downloadedAndOpenedDiskImage() {
        expectEqual(subject.rig.downloadedAssets, [AssetID.updateArchive], "the downloaded asset")
        expectEqual(subject.rig.opened.map(\.pathExtension), ["dmg"], "the opened file")
        expectEqual(try? Data(contentsOf: subject.rig.archive), When.diskImage, "the verified disk image on disk")
        expect(subject.rig.service.available == nil, "the prompt should close")
    }

    func openedReleasePage() {
        expectEqual(subject.rig.opened, [ReleaseLink.downloadsPage], "what opened after a failed verification")
    }

    func deletedTheFile() {
        expectEqual(subject.rig.filesLeftBehind, [], "files left in the downloads folder after a mismatch")
    }
}

@MainActor extension Then where Subject == UpdateDownload {
    func downloadedNothingAndOpenedReleasePage() {
        expect(subject.rig.downloadedAssets.isEmpty, "nothing should be downloaded without a checksum")
        expectEqual(subject.rig.opened, [ReleaseLink.downloadsPage], "the page opened")
    }
}

@MainActor extension Then where Subject == UpdateRig {
    func checkedTheFeed(_ times: Int) { expectEqual(subject.fetchCount, times, "feed checks") }
}

extension Then where Subject == [String] {
    func showVersionAndAutomaticSwitch() {
        expectEqual(
            subject,
            [Copy.versionRow, Copy.automaticChecksRow, Copy.checkNowRow],
            "the Software update rows")
    }
}

extension Then where Subject == Bool {
    func isOn(_ what: String) { expect(subject, "\(what) should be on") }
}
