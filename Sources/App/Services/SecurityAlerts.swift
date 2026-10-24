import Foundation

/// Counts failed unlock attempts and says when there have been too many in a
/// short time. Pure value type: the caller passes the clock.
struct FailedUnlockMonitor: Equatable {
    static let defaultThreshold = 3
    static let defaultWindow: TimeInterval = 5 * 60

    let threshold: Int
    let window: TimeInterval
    private var failures: [Date] = []

    init(threshold: Int = defaultThreshold, window: TimeInterval = defaultWindow) {
        self.threshold = threshold
        self.window = window
    }

    /// Notes one failed attempt. Returns true when it is the `threshold`-th
    /// within `window`; the count then starts over, so a long run of failures
    /// raises one alert per `threshold` attempts, not one per attempt.
    mutating func recordFailure(at date: Date) -> Bool {
        failures.removeAll { date.timeIntervalSince($0) > window }
        failures.append(date)
        guard failures.count >= threshold else { return false }
        failures.removeAll()
        return true
    }

    /// A good unlock ends the run.
    mutating func recordSuccess() { failures.removeAll() }
}

/// A condition the user should hear about, shown as a banner in the main window.
enum SecurityAlert: Equatable, Identifiable {
    case repeatedUnlockFailures(attempts: Int, minutes: Int)
    case auditLogBroken(entry: Int64)
    case recordingEncryptionDeferred

    var id: String {
        switch self {
        case .repeatedUnlockFailures: return "repeatedUnlockFailures"
        case .auditLogBroken: return "auditLogBroken"
        case .recordingEncryptionDeferred: return "recordingEncryptionDeferred"
        }
    }

    var message: String {
        switch self {
        case let .repeatedUnlockFailures(attempts, minutes):
            return "There were \(attempts) failed unlock attempts within \(minutes) minutes. If that wasn't you, change your Mac's login password."
        case let .auditLogBroken(entry):
            return "The activity log doesn't pass its integrity check (it first breaks at entry #\(entry)). It may have been edited or damaged. Open Settings > Security to review it."
        case .recordingEncryptionDeferred:
            return "Your recording was saved, but it couldn't be encrypted yet. Aletheia will encrypt it and add it to the session the next time it opens."
        }
    }
}
