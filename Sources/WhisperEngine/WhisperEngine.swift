import Foundation
import whisper

/// One line of speech as whisper.cpp reports it, in seconds from the start of
/// the audio.
public struct WhisperSegment: Equatable {
    public let start: TimeInterval
    public let end: TimeInterval
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

public enum WhisperEngineError: LocalizedError, Equatable {
    case modelLoadFailed
    case inferenceFailed(code: Int32)
    case aborted

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed:
            "The speech-to-text model couldn't be loaded. Download it again in Settings."
        case .inferenceFailed(let code):
            "Transcription failed (whisper.cpp error \(code))."
        case .aborted:
            "Transcription was stopped."
        }
    }
}

/// The current official whisper.cpp (ggml-org), behind a small Swift surface.
///
/// A framework of its own, not a file in the app, on purpose: the app also
/// links SwiftWhisper, which compiles an old whisper.cpp into the app binary
/// under the same C symbol names (`whisper_full`, …). A symbol name resolves
/// once per binary, so code in the app calling `whisper_full` would bind to
/// that old copy while reading the new header's struct layouts. Inside this
/// framework the names bind to the new library only.
///
/// Everything here is synchronous and CPU/GPU-heavy; call it off the main
/// thread. One engine holds one loaded model.
public final class WhisperEngine {
    /// The linked whisper.cpp version, e.g. "1.9.5".
    public static var version: String { String(cString: whisper_version()) }

    /// Decoder threads. With Metal the encoder runs on the GPU, so this mostly
    /// matters for decoding and for the CPU fallback: use the cores, but leave
    /// two for the app and cap it where whisper.cpp stops scaling.
    public static func recommendedThreads(activeCores: Int = ProcessInfo.processInfo.activeProcessorCount) -> Int {
        max(1, min(8, activeCores - 2))
    }

    /// whisper.cpp reports segment times in hundredths of a second.
    public static func seconds(fromCentiseconds value: Int64) -> TimeInterval {
        TimeInterval(value) / 100
    }

    private let context: OpaquePointer

    /// Loads the ggml model at `modelPath`. `useGPU` runs the encoder on Metal;
    /// whisper.cpp falls back to the CPU by itself where Metal isn't available.
    public init(modelPath: URL, useGPU: Bool = true) throws {
        var params = whisper_context_default_params()
        params.use_gpu = useGPU
        guard FileManager.default.fileExists(atPath: modelPath.path),
              let context = whisper_init_from_file_with_params(modelPath.path, params)
        else { throw WhisperEngineError.modelLoadFailed }
        self.context = context
    }

    deinit {
        whisper_free(context)
    }

    /// Transcribes 16 kHz mono samples. `onProgress` gets 0...1 and
    /// `shouldAbort` is polled throughout; both may be called from any thread.
    /// Throws `.aborted` (and returns nothing) once `shouldAbort` says so.
    public func transcribe(
        samples: [Float],
        language: String = "en",
        threads: Int = WhisperEngine.recommendedThreads(),
        onProgress: @escaping (Double) -> Void = { _ in },
        shouldAbort: @escaping () -> Bool = { false }
    ) throws -> [WhisperSegment] {
        let callbacks = Callbacks(onProgress: onProgress, shouldAbort: shouldAbort)
        let userData = Unmanaged.passUnretained(callbacks).toOpaque()

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.n_threads = Int32(threads)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.progress_callback = { _, _, percent, userData in
            guard let userData else { return }
            Unmanaged<Callbacks>.fromOpaque(userData).takeUnretainedValue().onProgress(Double(percent) / 100)
        }
        params.progress_callback_user_data = userData
        params.abort_callback = { userData in
            guard let userData else { return false }
            return Unmanaged<Callbacks>.fromOpaque(userData).takeUnretainedValue().shouldAbort()
        }
        params.abort_callback_user_data = userData

        let status: Int32 = withExtendedLifetime(callbacks) {
            language.withCString { languagePointer in
                params.language = languagePointer
                return samples.withUnsafeBufferPointer { buffer in
                    whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                }
            }
        }
        // An abort surfaces as a failed run; report it as what it was.
        if shouldAbort() { throw WhisperEngineError.aborted }
        guard status == 0 else { throw WhisperEngineError.inferenceFailed(code: status) }

        return (0..<whisper_full_n_segments(context)).map { index in
            WhisperSegment(
                start: Self.seconds(fromCentiseconds: whisper_full_get_segment_t0(context, index)),
                end: Self.seconds(fromCentiseconds: whisper_full_get_segment_t1(context, index)),
                text: String(cString: whisper_full_get_segment_text(context, index))
            )
        }
    }
}

/// Carries the Swift closures through whisper.cpp's `void *` user data.
private final class Callbacks {
    let onProgress: (Double) -> Void
    let shouldAbort: () -> Bool

    init(onProgress: @escaping (Double) -> Void, shouldAbort: @escaping () -> Bool) {
        self.onProgress = onProgress
        self.shouldAbort = shouldAbort
    }
}
