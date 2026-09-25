import AVFoundation
import CoreGraphics
import ScreenCaptureKit

enum SystemAudioCaptureError: LocalizedError, Equatable {
    case permissionDenied
    case noDisplayAvailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "Aletheia doesn't have permission to capture the call audio. Open System Settings > Privacy & Security > Screen & System Audio Recording and turn it on for Aletheia."
        case .noDisplayAvailable:
            return "Couldn't find a display to capture system audio from."
        }
    }
}

/// Captures the *other side* of the video call — whatever is coming out of
/// the Mac's speakers/headphones during the session — using ScreenCaptureKit
/// in audio-only mode. It captures system audio, so it's app-agnostic: Zoom, a
/// browser (Tebra), FaceTime, or any other call all work the same way with no
/// per-app setup. This replaces the BlackHole virtual-audio-device
/// approach: no third-party kernel extension or Audio MIDI Setup routing is
/// needed, only a one-time system permission grant (the same "Screen &
/// System Audio Recording" permission macOS uses for screen recorders).
///
/// No video frames are captured or stored; the capture width/height is
/// clamped to the minimum ScreenCaptureKit allows, purely so the audio
/// stream can be opened.
@MainActor
final class SystemAudioCapture: NSObject {
    private var stream: SCStream?
    private var file: AVAudioFile?
    private var fileURL: URL?
    var onError: ((Error) -> Void)?
    private(set) var isRunning = false
    /// When true, the SCStream keeps running but incoming buffers are dropped,
    /// so the call track skips the paused span in step with the mic track.
    var isPaused = false

    /// Whether Screen Recording (which gates ScreenCaptureKit audio) is granted —
    /// checked *without* prompting. Using the CoreGraphics preflight instead of
    /// probing `SCShareableContent` is what stops the setup flow from re-showing
    /// the system permission dialog every time it re-runs its health checks. Safe
    /// to poll as often as we like.
    static func checkPermission() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    /// The authoritative, live answer to "is Screen & System Audio Recording
    /// granted right now?" — used at the moments the user has just changed it
    /// (returning from System Settings, or right after the grant prompt).
    ///
    /// `CGPreflightScreenCaptureAccess()` is decided once per process launch and
    /// then cached, so on macOS 14/15 a grant made while the app is running keeps
    /// reading back as *denied* until relaunch — exactly the false negative that
    /// makes the setup row stay red after the toggle is on. Actually trying to
    /// read `SCShareableContent` reflects the current TCC state without a
    /// relaunch: it succeeds when access is granted and throws when it isn't.
    ///
    /// This can surface the one-time system prompt when the state is still
    /// undetermined, so it's called only on explicit/among-activation refreshes,
    /// never on the fast background poll (which stays on the non-prompting
    /// `checkPermission()`).
    static func verifyAccessGranted() async -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    /// Ask for Screen Recording access with a single, explicit system prompt.
    /// Only triggers the dialog when the state is undetermined; once the user has
    /// denied it, macOS won't re-prompt (this returns false and the UI sends them
    /// to System Settings instead). Because the app never poisons its own TCC
    /// state with a premature capture attempt, a grant takes effect for the
    /// running process — no relaunch required.
    ///
    /// `CGRequestScreenCaptureAccess()` is synchronous and blocks its calling
    /// thread until the user responds to the system dialog, which can take
    /// several seconds. Calling it on the main actor — as this used to —
    /// freezes the whole app for as long as the dialog is up (issue #110:
    /// "Grant appears to hang the wizard step"). `nonisolated` plus
    /// `Task.detached` moves the actual blocking call off the main thread;
    /// only the `Bool` result crosses back to the caller.
    /// - Returns: whether access is granted right after the request.
    @discardableResult
    nonisolated static func requestPermission() async -> Bool {
        await Task.detached(priority: .userInitiated) {
            CGRequestScreenCaptureAccess()
        }.value
    }

    /// Pure mapping from "is access granted?" to the error `start()` should
    /// surface before ever touching ScreenCaptureKit — split out so the
    /// fail-fast branch is unit-tested without a live capture attempt.
    static func permissionError(granted: Bool) -> SystemAudioCaptureError? {
        granted ? nil : .permissionDenied
    }

    func start(to url: URL) async throws {
        // Fail fast with the friendly message when access isn't granted,
        // mirroring `MicRecorder.start`'s guard, instead of letting an
        // unauthorized `SCShareableContent` call surface a raw ScreenCaptureKit
        // error. Uses the live check (not the cached preflight) so a grant made
        // moments ago in the setup wizard is recognized immediately.
        if let permissionError = Self.permissionError(granted: await Self.verifyAccessGranted()) {
            throw permissionError
        }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplayAvailable
        }

        // `init(display:excludingWindows:)` with an empty window list is a
        // known ScreenCaptureKit gotcha that can make the stream silently
        // never start; excludingApplications with an empty list is the
        // documented-safe way to say "capture everything on this display".
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.sampleRate = 48000
        config.channelCount = 2
        config.excludesCurrentProcessAudio = true
        // We only want audio; keep the video side of the stream as cheap as possible.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        self.fileURL = url
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "com.aletheia.systemaudio"))
        try await stream.startCapture()
        self.stream = stream
        isRunning = true
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
        self.file = nil
        isRunning = false
        isPaused = false
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard !isPaused, let fileURL else { return }
        do {
            if file == nil {
                file = try AVAudioFile(forWriting: fileURL, settings: buffer.format.settings)
            }
            try file?.write(from: buffer)
        } catch {
            onError?(error)
        }
    }
}

extension SystemAudioCapture: SCStreamOutput {
    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of outputType: SCStreamOutputType) {
        guard outputType == .audio, sampleBuffer.isValid else { return }
        guard let pcmBuffer = sampleBuffer.asPCMBuffer else { return }
        Task { @MainActor [weak self] in
            self?.write(pcmBuffer)
        }
    }
}

extension SystemAudioCapture: SCStreamDelegate {
    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        Task { @MainActor [weak self] in
            self?.onError?(error)
            self?.isRunning = false
        }
    }
}
