import Foundation

/// Slows down repeated wrong passphrases. The first few failures are free; after
/// that each one doubles the wait, up to a ceiling, and a success starts over.
/// In memory only, so it paces a person at the unlock screen, not an attacker
/// working on a copy of the keystore (the key derivation covers that).
struct UnlockThrottle {
    /// Failures allowed before any wait is imposed.
    var freeAttempts = 3
    /// Wait after the first failure past the free ones.
    var baseDelay: TimeInterval = 2
    var maxDelay: TimeInterval = 15 * 60
    var now: () -> Date = Date.init

    private(set) var failures = 0
    private var blockedUntil: Date?

    init(freeAttempts: Int = 3, baseDelay: TimeInterval = 2, maxDelay: TimeInterval = 15 * 60, now: @escaping () -> Date = Date.init) {
        self.freeAttempts = freeAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.now = now
    }

    /// Seconds left before another attempt is allowed; 0 when one is.
    var remainingDelay: TimeInterval {
        guard let blockedUntil else { return 0 }
        return max(0, blockedUntil.timeIntervalSince(now()))
    }

    mutating func recordFailure() {
        failures += 1
        let over = failures - freeAttempts
        guard over > 0 else { return }
        let delay = min(maxDelay, baseDelay * pow(2, Double(min(over - 1, 30))))
        blockedUntil = now().addingTimeInterval(delay)
    }

    mutating func recordSuccess() {
        failures = 0
        blockedUntil = nil
    }
}
