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

/// Coordinates the two audio captures (mic + call) that make up a session
/// recording. They're kept as two separate files rather than mixed down to
/// one, which has a nice side effect: the transcript can label lines by
/// source ("You" vs "Call audio") instead of a single blended track.
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
    /// The session currently being recorded, or nil when idle.
    @Published private(set) var active: ActiveRecording?
    /// Set once when a recording has run past `RecordingLimit.reminderThreshold`,
    /// so the UI can ask whether the therapist forgot to end the session. The
    /// view clears it when the user answers.
    @Published var longRunningReminder = false

    private let mic = MicRecorder()
    private let systemAudio = SystemAudioCapture()
    private var reminderTask: Task<Void, Never>?

    func start(micURL: URL, callURL: URL, context: ActiveRecording) async {
        if case .recording = state { return }

        let micGranted = await MicRecorder.requestPermission()
        guard micGranted else {
            state = .error(MicRecorderError.permissionDenied.localizedDescription)
            return
        }

        systemAudio.onError = { [weak self] error in
            self?.state = .error(error.localizedDescription)
        }

        do {
            try mic.start(to: micURL)
            try await systemAudio.start(to: callURL)
            isPaused = false
            active = context
            state = .recording(startedAt: Date())
            startReminderTimer()
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
    }

    /// Resume writing after a `pause()`.
    func resume() {
        guard isRecording, isPaused else { return }
        mic.isPaused = false
        systemAudio.isPaused = false
        isPaused = false
    }

    func stop() async {
        reminderTask?.cancel()
        reminderTask = nil
        mic.stop()
        await systemAudio.stop()
        isPaused = false
        active = nil
        state = .idle
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

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }

    /// When the active recording began (for an elapsed-time display), or nil.
    var startedAt: Date? {
        if case .recording(let date) = state { return date }
        return nil
    }
}
