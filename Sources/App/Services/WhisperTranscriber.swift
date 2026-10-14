import Foundation
import SwiftWhisper

enum WhisperTranscriberError: LocalizedError {
    case modelNotDownloaded

    var errorDescription: String? {
        "The speech-to-text model hasn't been downloaded yet. Open Settings and download it first."
    }
}

/// One line of speech from a single track, in seconds from its start.
struct SpeechSegment: Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var text: String
}

/// The whisper.cpp build that turns one track's samples into segments. The
/// seam between the session logic in `WhisperTranscriber` (tracks, merging,
/// cleaning) and the runtime doing the inference, so the runtime can change
/// without touching the rest. See `Integrations.makeTranscriber()`.
protocol SpeechEngine {
    /// Transcribes 16 kHz mono samples; `onProgress` gets 0...1 from any
    /// thread. Honors task cancellation by throwing `CancellationError`.
    func segments(
        for samples: [Float],
        modelPath: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [SpeechSegment]
}

/// Transcribes a session with whisper.cpp, in-process — no Homebrew install or
/// shelled-out CLI tool; it runs inside the sandboxed app itself, entirely
/// offline.
///
/// Deliberately not MainActor-isolated: resampling and whisper.cpp
/// inference are both CPU-heavy and can take minutes for a long session,
/// so this runs on a background executor. `onProgress` may be called from
/// any thread — callers hop back to the main actor themselves before
/// touching UI state.
final class WhisperTranscriber: Transcribing {
    private let modelPath: URL
    private let engine: SpeechEngine

    init(modelPath: URL, engine: SpeechEngine = SwiftWhisperEngine()) {
        self.modelPath = modelPath
        self.engine = engine
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
        let segments = try await engine.segments(for: samples, modelPath: modelPath) { report(stage, $0) }
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
}

/// whisper.cpp via SwiftWhisper: an early-2023 build, CPU only. What the
/// production build ships.
struct SwiftWhisperEngine: SpeechEngine {
    func segments(
        for samples: [Float],
        modelPath: URL,
        onProgress: @escaping (Double) -> Void
    ) async throws -> [SpeechSegment] {
        let whisper = Whisper(fromFileURL: modelPath)
        let forwarder = ProgressForwarder(onProgress: onProgress)
        whisper.delegate = forwarder

        // whisper.cpp can't be interrupted mid-window, but SwiftWhisper checks a
        // cancel flag before each ~30 s window and then throws `.cancelled`, so
        // cancelling the task stops the work within a few seconds.
        let canceller = WhisperCanceller(whisper)
        let segments: [Segment]
        do {
            segments = try await withTaskCancellationHandler {
                try await whisper.transcribe(audioFrames: samples)
            } onCancel: {
                canceller.cancel()
            }
        } catch WhisperError.cancelled {
            throw CancellationError()
        }
        // SwiftWhisper holds `delegate` weakly; nothing else retains
        // `forwarder`, so without this the optimizer could release it right
        // after the assignment above and silently drop every progress
        // callback. Referencing it after the await pins its lifetime across
        // the whole transcription.
        withExtendedLifetime(forwarder) {}
        return segments.map { segment in
            SpeechSegment(
                start: TimeInterval(segment.startTime) / 1000.0,
                end: TimeInterval(segment.endTime) / 1000.0,
                text: segment.text
            )
        }
    }
}

/// Lets the task-cancellation handler (a `@Sendable` closure on an arbitrary
/// thread) ask a `Whisper` instance to stop. `Whisper.cancel` only sets a flag
/// that its C callback polls, and throws when nothing is running; both are fine
/// to ignore here.
private final class WhisperCanceller: @unchecked Sendable {
    private let whisper: Whisper

    init(_ whisper: Whisper) {
        self.whisper = whisper
    }

    func cancel() {
        try? whisper.cancel(completionHandler: {})
    }
}

private final class ProgressForwarder: WhisperDelegate {
    private let onProgress: (Double) -> Void

    init(onProgress: @escaping (Double) -> Void) {
        self.onProgress = onProgress
    }

    func whisper(_ aWhisper: Whisper, didUpdateProgress progress: Double) {
        onProgress(progress)
    }

    func whisper(_ aWhisper: Whisper, didProcessNewSegments segments: [Segment], atIndex index: Int) {}
    func whisper(_ aWhisper: Whisper, didCompleteWithSegments segments: [Segment]) {}
    func whisper(_ aWhisper: Whisper, didErrorWith error: Error) {}
}
