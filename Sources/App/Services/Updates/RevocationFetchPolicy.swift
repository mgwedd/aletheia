import Foundation

/// When the app may ask the helper for the license revocation list: at most
/// once per `minimumInterval`, and only while the user's automatic
/// update-check setting is on. Pure, so it is tested without a clock or a network.
struct RevocationFetchPolicy: Equatable {
    static let minimumInterval: TimeInterval = 24 * 60 * 60

    /// Mirrors `AppSettings.autoCheckForUpdates`.
    var updateChecksEnabled: Bool
    /// When the last attempt was made, or nil if never.
    var lastAttempt: Date?

    func shouldFetch(now: Date) -> Bool {
        guard updateChecksEnabled else { return false }
        guard let lastAttempt else { return true }
        // A clock set back counts as due, so a bad clock can't block forever.
        let elapsed = now.timeIntervalSince(lastAttempt)
        return elapsed < 0 || elapsed >= Self.minimumInterval
    }
}
