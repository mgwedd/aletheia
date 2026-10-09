import Foundation
import SwiftWhisper

enum WhisperTranscriberError: LocalizedError {
    case modelNotDownloaded

    var errorDescription: String? {
        "The speech-to-text model hasn't been downloaded yet. Open Settings and download it first."
    }
}

/// Wraps SwiftWhisper — an in-process Swift binding for whisper.cpp — so
/// transcription never needs a Homebrew install or a shelled-out CLI tool;
/// it runs inside the sandboxed app itself, entirely offline.
///
/// Deliberately not MainActor-isolated: resampling and whisper.cpp
/// inference are both CPU-heavy and can take minutes for a long session,
/// so this runs on a background executor. `onProgress` may be called from
/// any thread — callers hop back to the main actor themselves before
/// touching UI state.
final class WhisperTranscriber: Transcribing {
    private let modelPath: URL

    init(modelPath: URL) {
        self.modelPath = modelPath
    }

    var isReady: Bool {
        FileManager.default.fileExists(atPath: modelPath.path)
    }

    /// Transcribes the mic and call recordings separately, then merges the
    /// lines by timestamp so the transcript reads like a two-person
    /// conversation ("Therapist" / "Call audio") instead of one blended track.
    func transcribeSession(
        micURL: URL?,
        callURL: URL?,
        onProgress: @escaping (Double) -> Void
    ) async throws -> String {
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw WhisperTranscriberError.modelNotDownloaded
        }

        var tracks: [(url: URL, source: String)] = []
        if let micURL, FileManager.default.fileExists(atPath: micURL.path) {
            tracks.append((url: micURL, source: "Therapist"))
        }
        if let callURL, FileManager.default.fileExists(atPath: callURL.path) {
            tracks.append((url: callURL, source: "Call audio"))
        }

        // Progress spans only the tracks that exist, so a single-track
        // session still runs 0-100%.
        var lines: [TranscribedLine] = []
        let span = 1.0 / Double(tracks.count)
        for (index, track) in tracks.enumerated() {
            let base = Double(index) * span
            let found = try await transcribe(url: track.url, source: track.source) { onProgress(base + $0 * span) }
            onProgress(base + span)
            lines += found
        }

        // Clean across both tracks at once (coalescing needs the merged
        // timeline), then print. Dropping non-speech tags and silence
        // artifacts means a recording where nothing was said yields "" (which
        // the caller treats as "no speech") instead of a transcript of bare
        // "[00:00] Therapist:" labels.
        return TranscriptFormatter.format(TranscriptCleaner.clean(lines))
    }

    private func transcribe(url: URL, source: String, onProgress: @escaping (Double) -> Void) async throws -> [TranscribedLine] {
        let samples = try AudioResampler.loadWhisperSamples(from: url)
        // Whisper hallucinates tags and filler on silence, so skip it.
        guard !AudioResampler.isEssentiallySilent(samples) else { return [] }

        let whisper = Whisper(fromFileURL: modelPath)
        let forwarder = ProgressForwarder(onProgress: onProgress)
        whisper.delegate = forwarder

        let segments = try await whisper.transcribe(audioFrames: samples)
        // SwiftWhisper holds `delegate` weakly; nothing else retains
        // `forwarder`, so without this the optimizer could release it right
        // after the assignment above and silently drop every progress
        // callback. Referencing it after the await pins its lifetime across
        // the whole transcription.
        withExtendedLifetime(forwarder) {}
        return segments.map { segment in
            TranscribedLine(
                source: source,
                startTime: TimeInterval(segment.startTime) / 1000.0,
                endTime: TimeInterval(segment.endTime) / 1000.0,
                text: segment.text
            )
        }
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
