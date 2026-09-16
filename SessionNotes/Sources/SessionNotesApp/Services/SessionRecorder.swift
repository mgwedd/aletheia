import Foundation

enum RecordingState: Equatable {
    case idle
    case recording(startedAt: Date)
    case error(String)
}

/// Coordinates the two audio captures (mic + call) that make up a session
/// recording. They're kept as two separate files rather than mixed down to
/// one, which has a nice side effect: the transcript can label lines by
/// source ("You" vs "Call audio") instead of a single blended track.
@MainActor
final class SessionRecorder: ObservableObject {
    @Published private(set) var state: RecordingState = .idle

    private let mic = MicRecorder()
    private let systemAudio = SystemAudioCapture()

    func start(micURL: URL, callURL: URL) async {
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
            state = .recording(startedAt: Date())
        } catch {
            mic.stop()
            await systemAudio.stop()
            state = .error(error.localizedDescription)
        }
    }

    func stop() async {
        mic.stop()
        await systemAudio.stop()
        state = .idle
    }

    var isRecording: Bool {
        if case .recording = state { return true }
        return false
    }
}
