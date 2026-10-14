import Foundation
import os
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
/// The C API, its pointers and callbacks stay inside this framework.
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

    /// Silero VAD v6.2.0 (MIT), bundled in this framework. From
    /// huggingface.co/ggml-org/whisper-vad at 9ffd54a1, SHA-256
    /// 2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987.
    static let vadModelPath = Bundle(for: WhisperEngine.self)
        .path(forResource: "ggml-silero-v6.2.0", ofType: "bin")!

    private let context: OpaquePointer

    /// Loads the ggml model at `modelPath`. `useGPU` runs the encoder on Metal;
    /// whisper.cpp falls back to the CPU by itself where Metal isn't available.
    public init(modelPath: URL, useGPU: Bool = true) throws {
        _ = Self.routeLogs
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
        // Silero VAD hands whisper only the stretches with speech. Long
        // silences otherwise make larger models loop on a phrase ("Okay." for
        // minutes); segment times still come back on the original timeline.
        params.vad = true

        let status: Int32 = withExtendedLifetime(callbacks) {
            language.withCString { languagePointer in
                Self.vadModelPath.withCString { vadPointer in
                    params.language = languagePointer
                    params.vad_model_path = vadPointer
                    return samples.withUnsafeBufferPointer { buffer in
                        whisper_full(context, params, buffer.baseAddress, Int32(buffer.count))
                    }
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

private let log = Logger(subsystem: "com.aletheia.WhisperEngine", category: "whisper.cpp")

extension WhisperEngine {
    /// whisper.cpp and ggml print every load step to stderr, including the
    /// optional Core ML encoder they probe for and we don't ship ("failed to
    /// load Core ML model", then Metal runs the whole model). Send it to the
    /// unified log instead, where Console still has it. Once per process.
    fileprivate static let routeLogs: Void = whisper_log_set({ level, text, _ in
        guard let text else { return }
        let line = String(cString: text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !line.isEmpty else { return }
        switch level {
        case GGML_LOG_LEVEL_ERROR: log.error("\(line, privacy: .public)")
        case GGML_LOG_LEVEL_WARN: log.notice("\(line, privacy: .public)")
        default: log.debug("\(line, privacy: .public)")
        }
    }, nil)
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
