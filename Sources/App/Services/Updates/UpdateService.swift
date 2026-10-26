import Foundation

/// Decides whether a newer version exists and should be surfaced, throttling
/// checks and honoring a "skip this version" choice. UI observes `available`;
/// polling is driven from the app on launch and on resume.
@MainActor
final class UpdateService: ObservableObject {
    /// Result of an explicit, user-initiated update check (Settings or Menu bar).
    enum ManualCheckResult: Equatable {
        case upToDate(checkedAt: Date)
        case updateAvailable(version: String)
        case couldNotCheck(reason: String)
    }

    /// Non-nil when a newer, non-skipped release is available to offer.
    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var isChecking = false
    /// Outcome of the last manual check, shown in Settings. Only a newer
    /// version is surfaced elsewhere, as a banner that doesn't block the app.
    @Published private(set) var manualCheckResult: ManualCheckResult?

    private let checker: UpdateChecking
    private let installer: UpdateInstalling
    private let currentVersion: SemanticVersion
    private let defaults: UserDefaults
    private let minimumInterval: TimeInterval
    private var lastCheck: Date?
    /// The version whose download the user already started in this run. It isn't
    /// offered again until the app relaunches (by then it's installed, or the
    /// user chose to keep working), so the prompt doesn't come back mid-session.
    private var downloadStartedVersion: String?

    private static let skipKey = "skippedUpdateVersion"

    init(
        checker: UpdateChecking,
        installer: UpdateInstalling = GuidedDownloadInstaller(),
        currentVersion: SemanticVersion,
        defaults: UserDefaults = .standard,
        minimumInterval: TimeInterval = 1800
    ) {
        self.checker = checker
        self.installer = installer
        self.currentVersion = currentVersion
        self.defaults = defaults
        self.minimumInterval = minimumInterval
    }

    /// The current app version, read from the bundle (falls back to 0.0.0).
    static func bundleVersion() -> SemanticVersion {
        let raw = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
        return raw.flatMap(SemanticVersion.init) ?? SemanticVersion(major: 0, minor: 0, patch: 0)
    }

    /// Checks the feed if enough time has passed (or `force`). Network/decoding
    /// failures are swallowed on automatic runs, but recorded into `manualCheckResult`
    /// when initiated manually (`force == true`).
    func checkForUpdates(force: Bool = false) async {
        guard !isChecking else { return }
        if !force, let last = lastCheck, Date().timeIntervalSince(last) < minimumInterval { return }

        isChecking = true
        lastCheck = Date()
        defer { isChecking = false }

        do {
            let release = try await checker.fetchLatest()
            guard let releaseVersion = SemanticVersion(release.version), releaseVersion > currentVersion else {
                available = nil
                if force {
                    let now = Date()
                    manualCheckResult = .upToDate(checkedAt: now)
                }
                return
            }
            if defaults.string(forKey: Self.skipKey) == release.version
                || downloadStartedVersion == release.version {
                available = nil
                if force {
                    let now = Date()
                    manualCheckResult = .upToDate(checkedAt: now)
                }
                return
            }
            available = release
            if force {
                manualCheckResult = .updateAvailable(version: release.version)
            }
        } catch {
            available = nil
            if force {
                let detail = (error as? URLError)?.localizedDescription ?? error.localizedDescription
                manualCheckResult = .couldNotCheck(reason: detail)
            }
        }
    }

    /// Starts the download and closes the prompt. The app is deliberately not
    /// quit: the therapist may have unsaved work, and a still-open prompt would
    /// block quitting (and so replacing the app from the downloaded disk image).
    func installAvailableUpdate() {
        guard let release = available else { return }
        downloadStartedVersion = release.version
        available = nil
        installer.install(release)
    }

    func skipAvailableVersion() {
        guard let release = available else { return }
        defaults.set(release.version, forKey: Self.skipKey)
        available = nil
    }

    func dismiss() {
        available = nil
    }
}
