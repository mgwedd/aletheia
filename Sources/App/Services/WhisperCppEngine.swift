#if ALETHEIA_PREVIEW && canImport(WhisperEngine)
import Foundation
import os
import WhisperEngine

/// The current official whisper.cpp with Metal (see the `WhisperEngine`
/// framework). Preview and dev builds only, until it has proven itself;
/// production stays on `SwiftWhisperEngine`.
struct WhisperCppEngine: SpeechEngine {
    func segments(
        for samples: [Float],
        modelPath: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [SpeechSegment] {
        // whisper.cpp polls this flag from its own threads, where
        // `Task.isCancelled` can't be read.
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            // Blocking for minutes: keep it off the cooperative pool.
            try await Task.detached(priority: .userInitiated) {
                do {
                    return try WhisperEngine(modelPath: modelPath)
                        .transcribe(
                            samples: samples,
                            onProgress: onProgress,
                            shouldAbort: { cancelled.withLock { $0 } }
                        )
                        .map { SpeechSegment(start: $0.start, end: $0.end, text: $0.text) }
                } catch WhisperEngineError.aborted {
                    throw CancellationError()
                }
            }.value
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }
}
#endif
