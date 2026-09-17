import Foundation

/// Decides whether a newer version exists and should be surfaced, throttling
/// checks and honoring a "skip this version" choice. UI observes `available`;
/// polling is driven from the app on launch and on resume.
@MainActor
final class UpdateService: ObservableObject {
    /// Non-nil when a newer, non-skipped release is available to offer.
    @Published private(set) var available: ReleaseInfo?
    @Published private(set) var isChecking = false

    private let checker: UpdateChecking
    private let installer: UpdateInstalling
    private let currentVersion: SemanticVersion
    private let defaults: UserDefaults
    private let minimumInterval: TimeInterval
    private var lastCheck: Date?

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
    /// failures are swallowed on purpose — a missing feed or offline machine
    /// simply means "no update to offer", never an error in the user's face.
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
                return
            }
            if defaults.string(forKey: Self.skipKey) == release.version {
                available = nil
                return
            }
            available = release
        } catch {
            // Offline or no published release yet — nothing to offer.
        }
    }

    func installAvailableUpdate() {
        guard let release = available else { return }
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
