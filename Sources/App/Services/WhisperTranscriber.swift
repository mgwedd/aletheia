import Foundation
import os
import WhisperEngine

enum WhisperTranscriberError: LocalizedError {
    case modelNotDownloaded
    case modelSizeMismatch

    var errorDescription: String? {
        switch self {
        case .modelNotDownloaded:
            return "The speech-to-text model hasn't been downloaded yet. Open Settings and download it first."
        case .modelSizeMismatch:
            return "The speech-to-text model file is damaged or incomplete. Open Settings and download it again."
        }
    }
}

/// Transcribes a session with whisper.cpp (the official release, on the GPU via
/// Metal; see the `WhisperEngine` framework), in-process — no Homebrew install
/// or shelled-out CLI tool; it runs inside the sandboxed app itself, entirely
/// offline.
///
/// Deliberately not MainActor-isolated: resampling and whisper.cpp
/// inference are both CPU-heavy and can take minutes for a long session,
/// so this runs on a background executor. `onProgress` may be called from
/// any thread — callers hop back to the main actor themselves before
/// touching UI state.
final class WhisperTranscriber: Transcribing {
    private let modelPath: URL
    private let expectedBytes: Int64?

    init(modelPath: URL, expectedBytes: Int64? = nil) {
        self.modelPath = modelPath
        self.expectedBytes = expectedBytes
    }

    var isReady: Bool {
        FileManager.default.fileExists(atPath: modelPath.path)
    }

    /// Transcribes the mic and call recordings separately, then merges the
    /// lines by timestamp so the transcript reads like a two-person
    /// conversation ("You" / "Call audio") instead of one blended track.
    func transcribeSession(
        micURL: URL?,
        callURL: URL?,
        onProgress: @escaping (TranscriptionProgress) -> Void
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw WhisperTranscriberError.modelNotDownloaded
        }
        if let expectedBytes {
            try WhisperModelFile.verifySize(at: modelPath, expectedBytes: expectedBytes)
        }

        var tracks: [(url: URL, source: String, stage: TranscriptionStage)] = []
        if let micURL, FileManager.default.fileExists(atPath: micURL.path) {
            tracks.append((url: micURL, source: "You", stage: .transcribingMic))
        }
        if let callURL, FileManager.default.fileExists(atPath: callURL.path) {
            tracks.append((url: callURL, source: "Call audio", stage: .transcribingCall))
        }

        // Progress spans only the tracks that exist, so a single-track
        // session still runs 0-100%.
        var lines: [TranscribedLine] = []
        let trackCount = tracks.count
        for (index, track) in tracks.enumerated() {
            // Cancelling between tracks must not start the next one.
            try Task.checkCancellation()
            let report: (TranscriptionStage, Double) -> Void = { stage, trackFraction in
                onProgress(TranscriptionProgress(
                    stage: stage,
                    fraction: TranscriptionProgressMath.overall(trackIndex: index, trackCount: trackCount, trackFraction: trackFraction)
                ))
            }
            let found = try await transcribe(url: track.url, source: track.source, stage: track.stage, report: report)
            report(track.stage, 1)
            lines += found
        }

        // On speakers the call re-enters the mic and is transcribed twice, so
        // drop mic lines that repeat the call track's words. Before cleaning:
        // the raw segments are shorter, which keeps the filter's time window
        // tight, and coalescing then sees the timeline without the echoes.
        let callLines = lines.filter { $0.source != "You" }
        lines = SpeakerLeakageFilter.dropLeakedLines(
            mic: lines.filter { $0.source == "You" },
            call: callLines
        ) + callLines

        // Clean across both tracks at once (coalescing needs the merged
        // timeline), then print. Dropping non-speech tags and silence
        // artifacts means a recording where nothing was said yields "" (which
        // the caller treats as "no speech") instead of a transcript of bare
        // "[00:00] You:" labels.
        return TranscriptFormatter.format(TranscriptCleaner.clean(lines))
    }

    private func transcribe(
        url: URL,
        source: String,
        stage: TranscriptionStage,
        report: @escaping (TranscriptionStage, Double) -> Void
    ) async throws -> [TranscribedLine] {
        report(.preparing, 0)
        let samples = try AudioResampler.loadWhisperSamples(from: url)
        try Task.checkCancellation()
        // Whisper hallucinates tags and filler on silence, so skip it.
        guard !AudioResampler.isEssentiallySilent(samples) else { return [] }

        report(stage, 0)
        let segments = try await Self.segments(for: samples, modelPath: modelPath) { report(stage, $0) }
        // Cancel can land before the engine has started; never hand back text
        // for a cancelled run.
        try Task.checkCancellation()
        return segments.map { segment in
            TranscribedLine(
                source: source,
                startTime: segment.start,
                endTime: segment.end,
                text: segment.text
            )
        }
    }

    /// One track's 16 kHz mono samples through whisper.cpp. `onProgress` gets
    /// 0...1 from any thread; cancelling the task stops the run and throws
    /// `CancellationError`.
    static func segments(
        for samples: [Float],
        modelPath: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [WhisperSegment] {
        // whisper.cpp polls this flag from its own threads, where
        // `Task.isCancelled` can't be read.
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        return try await withTaskCancellationHandler {
            // Blocking for minutes: keep it off the cooperative pool.
            try await Task.detached(priority: .userInitiated) {
                do {
                    return try WhisperEngine(modelPath: modelPath).transcribe(
                        samples: samples,
                        onProgress: onProgress,
                        shouldAbort: { cancelled.withLock { $0 } }
                    )
                } catch WhisperEngineError.aborted {
                    throw CancellationError()
                }
            }.value
        } onCancel: {
            cancelled.withLock { $0 = true }
        }
    }
}
