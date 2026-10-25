import Foundation

/// Fails the test when a condition does not come true in time.
struct EventuallyTimeout: Error, CustomStringConvertible {
    let what: String
    let seconds: TimeInterval
    var description: String { "timed out after \(seconds)s waiting for \(what)" }
}

/// Waits for `condition` to become true: polls about every 10 ms and throws
/// `EventuallyTimeout` naming `what` once `within` seconds have passed.
///
/// This is the only way a spec, DSL verb or driver waits. A fixed delay is never
/// a wait, because it is either too short (flaky) or too long (slow); the
/// coverage test rejects `Task.sleep` and `Thread.sleep` anywhere else in DSL/
/// and Drivers/. The pause between polls below is the one allowed use.
///
/// The condition is checked once more at the deadline, so a slow machine gets
/// the full `within` window rather than losing the last interval.
func eventually(
    within timeout: TimeInterval = 5,
    _ what: String,
    _ condition: @MainActor () async throws -> Bool
) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        if try await condition() { return }
        if Date() >= deadline { throw EventuallyTimeout(what: what, seconds: timeout) }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
}
