import Foundation
import SwiftWhisper

enum WhisperTranscriberError: LocalizedError {
    case modelNotDownloaded

    var errorDescription: String? {
        "The speech-to-text model hasn't been downloaded yet. Open Settings and download it first."
    }
}

private struct TranscribedLine {
    let source: String
    let startTime: TimeInterval
    let text: String
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
final class WhisperTranscriber {
    private let modelPath: URL

    init(modelPath: URL) {
        self.modelPath = modelPath
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

        var lines: [TranscribedLine] = []

        if let micURL, FileManager.default.fileExists(atPath: micURL.path) {
            lines += try await transcribe(url: micURL, source: "Therapist") { onProgress($0 * 0.5) }
        }
        if let callURL, FileManager.default.fileExists(atPath: callURL.path) {
            lines += try await transcribe(url: callURL, source: "Call audio") { onProgress(0.5 + $0 * 0.5) }
        }

        lines.sort { $0.startTime < $1.startTime }
        return lines.map { line in
            let minutes = Int(line.startTime) / 60
            let seconds = Int(line.startTime) % 60
            let timestamp = String(format: "%02d:%02d", minutes, seconds)
            return "[\(timestamp)] \(line.source): \(line.text.trimmingCharacters(in: .whitespaces))"
        }.joined(separator: "\n")
    }

    private func transcribe(url: URL, source: String, onProgress: @escaping (Double) -> Void) async throws -> [TranscribedLine] {
        let samples = try AudioResampler.loadWhisperSamples(from: url)
        guard !samples.isEmpty else { return [] }

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
            TranscribedLine(source: source, startTime: TimeInterval(segment.startTime) / 1000.0, text: segment.text)
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
