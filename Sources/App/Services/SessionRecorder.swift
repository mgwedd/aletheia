import Foundation

enum RecordingState: Equatable {
    case idle
    case recording(startedAt: Date)
    case error(String)
}

/// Pure duration logic, so the "did you forget to stop?" threshold is testable
/// without a running recorder.
enum RecordingLimit {
    /// A therapy hour runs ~50 min; past 90 the session was almost certainly
    /// meant to end and the mic is still open.
    static let reminderThreshold: TimeInterval = 90 * 60

    static func shouldRemind(elapsed: TimeInterval, threshold: TimeInterval = reminderThreshold) -> Bool {
        elapsed >= threshold
    }
}

/// Elapsed recording time that stops while paused: the time since start,
/// minus every paused span (including one still open).
struct RecordingClock: Equatable {
    private(set) var startedAt: Date
    private var pausedTotal: TimeInterval = 0
    private var pausedAt: Date?

    init(startedAt: Date) { self.startedAt = startedAt }

    mutating func pause(at now: Date) {
        if pausedAt == nil { pausedAt = now }
    }

    mutating func resume(at now: Date) {
        guard let pausedAt else { return }
        pausedTotal += max(0, now.timeIntervalSince(pausedAt))
        self.pausedAt = nil
    }

    func elapsed(at now: Date) -> TimeInterval {
        let end = pausedAt ?? now
        return max(0, end.timeIntervalSince(startedAt) - pausedTotal)
    }
}

/// The smoothed live input levels (0...1) shown on the recording panel. A
/// separate observable object, so the ~15 Hz updates redraw only the meters
/// rather than every view that observes the recorder.
@MainActor
final class RecordingLevels: ObservableObject {
    @Published fileprivate(set) var mic: Float = 0
    @Published fileprivate(set) var call: Float = 0
}

/// Coordinates the two audio captures (mic + call) that make up a session
/// recording. They're kept as two separate files rather than mixed down to
/// one, which has a nice side effect: the transcript can label lines by
/// source ("Therapist" vs "Call audio") instead of a single blended track.
@MainActor
final class SessionRecorder: ObservableObject {
    /// Which session a recording is writing into. Held so a global control (the
    /// menu-bar item) can name what's recording and route back to it, and so a
    /// session view knows whether *it* is the one recording.
    struct ActiveRecording: Equatable {
        let patientID: UUID
        let patientName: String
        let patientSlug: String
        let sessionFolder: String
    }

    @Published private(set) var state: RecordingState = .idle
    /// True while recording is paused (captures still running, buffers dropped).
    @Published private(set) var isPaused = false
    /// Drives the elapsed-time display; frozen while paused.
    private var clock: RecordingClock?
    /// The session currently being recorded, or nil when idle.
    @Published private(set) var active: ActiveRecording?
    /// Set once when a recording has run past `RecordingLimit.reminderThreshold`,
    /// so the UI can ask whether the therapist forgot to end the session. The
    /// view clears it when the user answers.
    @Published var longRunningReminder = false

    let recordingHealth = RecordingHealth()
    /// Live mic / call-audio levels for the meters; zero unless actively recording.
    let levels = RecordingLevels()
    private let mic = MicRecorder()
    private let systemAudio = SystemAudioCapture()
    private var reminderTask: Task<Void, Never>?
    private var levelTask: Task<Void, Never>?
    private var micSmoother = AudioLevelSmoother()
    private var callSmoother = AudioLevelSmoother()
    /// Meter refresh rate: polled on a timer, never per audio buffer.
    private static let levelPollInterval: TimeInterval = 1.0 / 15.0

    /// Seals the finished recordings when encryption is on. Captured at
    /// `start()` and applied in `stop()` so the audio never lands as plaintext
    /// on an encrypted folder (beyond the live-recording window, by design).
    private var protector: FileProtector = .passthrough
    private var micURL: URL?
    private var callURL: URL?

    func start(micURL: URL, callURL: URL, context: ActiveRecording, protector: FileProtector = .passthrough) async {
        if case .recording = state { return }

        let micGranted = await MicRecorder.requestPermission()
        guard micGranted else {
            state = .error(MicRecorderError.permissionDenied.localizedDescription)
            return
        }

        systemAudio.onError = { [weak self] error in
            guard let self else { return }
            self.recordingHealth.recordSystemAudioDisruption(error.localizedDescription)
            // System audio stream disruption (DRM, permission yank, display disconnect)
            // is non-fatal to the session if the microphone track is still recording.
            if !self.mic.isRunning {
                self.state = .error("Recording interrupted: \(error.localizedDescription)")
            }
        }
        mic.onDisruption = { [weak self] message in
            guard let self else { return }
            if !self.mic.isRunning && !self.systemAudio.isRunning {
                self.state = .error(message)
            }
        }

        do {
            try mic.start(to: micURL)
            // System audio capture is best-effort — if system audio fails to start,
            // session recording still continues with the microphone track.
            do {
                try await systemAudio.start(to: callURL)
            } catch {
                recordingHealth.recordSystemAudioDisruption(error.localizedDescription)
            }
            self.protector = protector
            self.micURL = micURL
            self.callURL = callURL
            isPaused = false
            active = context
            let started = Date()
            clock = RecordingClock(startedAt: started)
            state = .recording(startedAt: started)
            startReminderTimer()
            startLevelPolling()
        } catch {
            mic.stop()
            await systemAudio.stop()
            active = nil
            state = .error(error.localizedDescription)
        }
    }

    /// Pause both captures without ending the session. The mic and call streams
    /// keep running but stop writing, so the recording resumes as one continuous
    /// file with the paused span omitted.
    func pause() {
        guard isRecording, !isPaused else { return }
        mic.isPaused = true
        systemAudio.isPaused = true
        isPaused = true
        clock?.pause(at: Date())
        resetLevels()
    }

    /// Resume writing after a `pause()`.
    func resume() {
        guard isRecording, isPaused else { return }
        mic.isPaused = false
        systemAudio.isPaused = false
        isPaused = false
        clock?.resume(at: Date())
    }

    func stop() async {
        reminderTask?.cancel()
        reminderTask = nil
        stopLevelPolling()
        mic.stop()
        await systemAudio.stop()
        isPaused = false
        clock = nil
        let sealError = await sealRecordingsIfNeeded()
        active = nil
        micURL = nil
        callURL = nil
        state = sealError.map { .error($0) } ?? .idle
    }

    /// Seals both recordings in place when encryption is on. Runs off the main
    /// actor (chunked streaming, so bounded memory over a long recording). On
    /// failure the plaintext recording is kept — losing the session would be
    /// worse — and the error is surfaced so the user knows it wasn't encrypted.
    private func sealRecordingsIfNeeded() async -> String? {
        guard protector.isEncrypting else { return nil }
        let protector = self.protector
        let urls = [micURL, callURL].compactMap { $0 }
        return await Task.detached(priority: .utility) { () -> String? in
            do {
                for url in urls { try protector.sealLargeFileInPlace(at: url) }
                return nil
            } catch {
                return "The recording was saved but couldn't be encrypted: \(error.localizedDescription)"
            }
        }.value
    }

    /// After the reminder threshold, flag that the session has likely been left
    /// recording. Fires once; `stop()` cancels it.
    private func startReminderTimer() {
        reminderTask?.cancel()
        longRunningReminder = false
        reminderTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(RecordingLimit.reminderThreshold * 1_000_000_000))
            guard let self, !Task.isCancelled else { return }
            if self.isRecording { self.longRunningReminder = true }
        }
    }

    /// Starts the ~15 Hz poll that turns the recorders' latest raw levels into
    /// the smoothed values the meters show. `stop()` cancels it.
    private func startLevelPolling() {
        levelTask?.cancel()
        resetLevels()
        let interval = Self.levelPollInterval
        levelTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                self.updateLevels(dt: Float(interval))
            }
        }
    }

    private func stopLevelPolling() {
        levelTask?.cancel()
        levelTask = nil
        resetLevels()
    }

    /// Paused shows the meters at zero; otherwise smooths the latest raw levels.
    private func updateLevels(dt: Float) {
        guard isRecording else {
            // Recording ended some other way (e.g. a capture error): stop polling.
            stopLevelPolling()
            return
        }
        guard !isPaused else {
            resetLevels()
            return
        }
        let micValue = micSmoother.update(target: mic.levelSource.latest(), dt: dt)
        let callValue = callSmoother.update(target: systemAudio.levelSource.latest(), dt: dt)
        // Skip identical values (e.g. steady silence) so idle meters don't republish.
        if levels.mic != micValue { levels.mic = micValue }
        if levels.call != callValue { levels.call = callValue }
    }

    private func resetLevels() {
        micSmoother.reset()
        callSmoother.reset()
        if levels.mic != 0 { levels.mic = 0 }
        if levels.call != 0 { levels.call = 0 }
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// Recorded time so far, not counting paused spans (0 when not recording).
    func elapsed(at now: Date = Date()) -> TimeInterval {
        clock?.elapsed(at: now) ?? 0
    }

    /// When the active recording began (for an elapsed-time display), or nil.
    var startedAt: Date? {
        if case .recording(let date) = state { return date }
        return nil
    }
}
