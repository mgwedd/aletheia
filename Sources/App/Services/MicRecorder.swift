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
    /// When true, the input tap keeps running but its buffers are dropped, so
    /// the file skips the paused span instead of stopping the engine (restarting
    /// AVAudioEngine mid-session risks glitches). Written on the main actor,
    /// read on the audio thread; a single Bool tolerates that racey read.
    var isPaused = false

    /// Write-health of the current recording: failed buffer writes and
    /// input-configuration changes. Populated from the audio thread, readable
    /// anywhere (lock-guarded).
    let health = RecordingHealth()

    /// Latest input level (0...1), published from the tap for the live meter.
    /// Read-only metering of the buffer the tap already receives; it does not
    /// affect what is written.
    let levelSource = LevelMeterSource()

    /// Called once, on the main actor, the first time a buffer write fails — so a
    /// silent audio-write failure (full disk, I/O error) becomes a visible error
    /// instead of a truncated file discovered after the session. Mirrors
    /// `SystemAudioCapture.onError`.
    var onDisruption: ((String) -> Void)?

    /// Observer for `AVAudioEngineConfigurationChange`, so an input-device swap or
    /// unplug mid-session is detected rather than silently ending capture.
    private var configObserver: NSObjectProtocol?

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

    private var fileURL: URL?

    func start(to url: URL) throws {
        guard !isRunning else { throw MicRecorderError.alreadyRunning }
        guard Self.permissionStatus == .authorized else { throw MicRecorderError.permissionDenied }

        health.reset()
        levelSource.reset()

        let inputNode = engine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        self.file = file
        self.fileURL = url

        // Plain tap, deliberately without Apple voice processing (echo
        // cancellation): it suppresses the near-end speaker during double-talk,
        // which is exactly an interruption, and it changes the input format this
        // file was opened with. Speaker bleed is handled at the text level
        // instead (see SpeakerLeakageFilter); headphones avoid it entirely.
        inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            if let level = AudioLevel.level(of: buffer) { self.levelSource.publish(level) }
            guard !self.isPaused else { return }
            do {
                try self.file?.write(from: buffer)
                if let fileURL = self.fileURL {
                    AudioCrashSafety.flushHeader(at: fileURL)
                }
            } catch {
                // Surface a silent write failure once, on the main actor, so the
                // therapist learns the recording stopped saving *during* the
                // session — not from a truncated file afterwards.
                if self.health.recordWriteFailure(error.localizedDescription) {
                    let message = "The microphone recording may have stopped saving to disk: \(error.localizedDescription)"
                    Task { @MainActor [weak self] in self?.onDisruption?(message) }
                }
            }
        }

        // An input-device swap or unplug mid-session posts this; capture can
        // silently stop when it does, so record it and attempt engine recovery.
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.health.recordConfigurationChange()
            if self.isRunning && !self.engine.isRunning {
                do {
                    self.engine.prepare()
                    try self.engine.start()
                } catch {
                    if self.health.recordWriteFailure(error.localizedDescription) {
                        let msg = "Microphone input changed and couldn't restart: \(error.localizedDescription)"
                        Task { @MainActor [weak self] in self?.onDisruption?(msg) }
                    }
                }
            }
        }

        engine.prepare()
        try engine.start()
        isRunning = true
    }

    func stop() {
        guard isRunning else { return }
        removeConfigObserver()
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        if let fileURL {
            AudioCrashSafety.flushHeader(at: fileURL)
        }
        file = nil
        fileURL = nil
        isRunning = false
        isPaused = false
        levelSource.reset()
    }

    private func removeConfigObserver() {
        if let configObserver {
            NotificationCenter.default.removeObserver(configObserver)
            self.configObserver = nil
        }
    }

    deinit {
        removeConfigObserver()
    }
}
