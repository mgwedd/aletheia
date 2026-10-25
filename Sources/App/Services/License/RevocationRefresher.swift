import Foundation

/// Fetches the signed revocation list through the network helper and hands it to
/// `LicenseState`, which verifies it before anything changes. Runs only while
/// update checks are on, and at most once a day (counted across launches,
/// whatever the outcome). A failed fetch or a list that does not verify changes
/// nothing; the last accepted list keeps applying.
@MainActor
final class RevocationRefresher {
    static let interval: TimeInterval = 24 * 60 * 60

    private let settings: AppSettings
    private let license: LicenseState
    private let fetch: @Sendable () async throws -> Data
    private let now: () -> Date
    private var running = false

    init(
        settings: AppSettings,
        license: LicenseState,
        fetch: @escaping @Sendable () async throws -> Data = { try await NetworkHelperClient.shared.fetchRevocations() },
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.license = license
        self.fetch = fetch
        self.now = now
    }

    /// Whether a check is due now.
    var isDue: Bool {
        guard settings.autoCheckForUpdates else { return false }
        guard let last = settings.lastRevocationCheck else { return true }
        // A clock set back past the last check counts as due, so a wrong date
        // cannot stop checks for good.
        let elapsed = now().timeIntervalSince(last)
        return elapsed >= Self.interval || elapsed < 0
    }

    /// Fetches and applies the list when a check is due. Returns whether a new
    /// list was accepted.
    @discardableResult
    func refreshIfDue() async -> Bool {
        guard isDue, !running else { return false }
        running = true
        defer { running = false }
        settings.lastRevocationCheck = now()
        guard let data = try? await fetch(), let text = String(data: data, encoding: .utf8) else { return false }
        return (try? license.applyRevocationList(text)) ?? false
    }
}
