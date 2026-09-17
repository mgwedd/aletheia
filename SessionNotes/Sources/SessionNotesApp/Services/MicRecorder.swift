import AVFoundation

enum MicRecorderError: LocalizedError {
    case permissionDenied
    case alreadyRunning

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Aletheia doesn't have permission to use the microphone. Open System Settings > Privacy & Security > Microphone and turn it on for Aletheia."
        case .alreadyRunning:
            return "A recording is already in progress."
        }
    }
}

/// Captures the therapist's own microphone via an AVAudioEngine tap on the
/// input node and writes it straight to disk as linear PCM.
///
/// Deliberately not actor-isolated: the tap closure below runs on a
/// dedicated real-time audio thread, and hopping to another actor on every
/// buffer would risk dropped audio if that actor is busy. `file` is only
/// ever touched from that one audio thread between `start()` and `stop()`.
final class MicRecorder {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private(set) var isRunning = false

    static func requestPermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    static var permissionStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .audio)
    }

    func start(to url: URL) throws {
        guard !isRunning else { throw MicRecorderError.alreadyRunning }
        guard Self.permissionStatus == .authorized else { throw MicRecorderError.permissionDenied }

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        self.file = file

        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            try? self.file?.write(from: buffer)
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        file = nil
        isRunning = false
    }
}
