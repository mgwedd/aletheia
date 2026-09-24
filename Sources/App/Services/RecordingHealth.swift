import Foundation

/// A thread-safe tally of a recording's write health, so a *silent* audio-write
/// failure — a full disk, an I/O error, or an input-device change mid-session —
/// becomes something the app can see and surface, instead of the therapist
/// discovering a truncated recording only after the session has ended.
///
/// Written from the real-time audio thread (once per buffer) and read from the
/// main actor, so every access is lock-guarded. Contention is negligible:
/// buffers arrive only ~10–20×/second. Lock-guarded internally, hence
/// `@unchecked Sendable`.
final class RecordingHealth: @unchecked Sendable {
    private let lock = NSLock()
    private var _writeFailures = 0
    private var _configurationChanges = 0
    private var _firstFailure: String?

    /// An immutable point-in-time view, safe to hand to the UI.
    struct Snapshot: Equatable {
        var writeFailures: Int
        var configurationChanges: Int
        var firstFailure: String?

        /// No write has failed and the input configuration hasn't changed.
        var isHealthy: Bool { writeFailures == 0 && configurationChanges == 0 }
    }

    init() {}

    /// Records a failed buffer write. Returns `true` iff this was the *first*
    /// failure, so the caller can surface it once rather than on every buffer.
    @discardableResult
    func recordWriteFailure(_ message: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _writeFailures += 1
        if _firstFailure == nil {
            _firstFailure = message
            return true
        }
        return false
    }

    /// Records that the audio engine's configuration changed (e.g. the input
    /// device was swapped or unplugged) — a signal that capture may have been
    /// disrupted even if no write has thrown yet.
    func recordConfigurationChange() {
        lock.lock(); defer { lock.unlock() }
        _configurationChanges += 1
    }

    /// A consistent snapshot of all counters, safe to read from any thread.
    var snapshot: Snapshot {
        lock.lock(); defer { lock.unlock() }
        return Snapshot(
            writeFailures: _writeFailures,
            configurationChanges: _configurationChanges,
            firstFailure: _firstFailure
        )
    }

    /// Resets to a clean slate for a new recording.
    func reset() {
        lock.lock(); defer { lock.unlock() }
        _writeFailures = 0
        _configurationChanges = 0
        _firstFailure = nil
    }
}
