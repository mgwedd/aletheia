import Foundation

/// The speech-to-text integration.
///
/// Another adapter seam: the only implementation is `WhisperTranscriber`
/// (whisper.cpp compiled into the app via SwiftWhisper — no external CLI,
/// no MacWhisper, no Homebrew), but any engine that turns the session's
/// audio files into a transcript can conform. The recording/transcription
/// UI depends on this protocol, not on Whisper specifically.
protocol Transcribing {
    /// Whether the engine is ready to run (e.g. the model has been downloaded).
    var isReady: Bool { get }

    /// Transcribe a session's mic and/or call recordings into one merged,
    /// timestamped, speaker-labeled transcript. Progress is reported 0...1.
    func transcribeSession(
        micURL: URL?,
        callURL: URL?,
        onProgress: @escaping (Double) -> Void
    ) async throws -> String
}
