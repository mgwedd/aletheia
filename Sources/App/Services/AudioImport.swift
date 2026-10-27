import AVFoundation

enum AudioImportError: LocalizedError, Equatable {
    /// The file isn't audio Aletheia can read, or it holds no sound.
    case unreadable
    /// The session already has a recording; importing would replace it.
    case sessionHasRecording

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "Aletheia couldn't read that file as audio. Try an M4A, MP3, WAV, AIFF or CAF file."
        case .sessionHasRecording:
            return "This session already has a recording. Import into a new session instead."
        }
    }
}

/// Brings an audio file the user picked into a session as its microphone
/// recording, so it can be transcribed like one recorded in the app.
///
/// The file is converted to the recording format in the private scratch folder
/// (never next to the original), then sealed into the session folder the same
/// way a finished recording is. The original file is only read.
enum AudioImport {
    /// Frames converted per pass, so a long session never sits in memory whole.
    private static let chunkFrames: AVAudioFrameCount = 1 << 16

    /// Converts `source` and seals it to `destination` with `protector`.
    /// Throws `AudioImportError.unreadable` for a file that isn't usable audio.
    static func importRecording(from source: URL, to destination: URL, protector: FileProtector) throws {
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let scratch = try PrivateStaging.scratchFile(prefix: "import", ext: "caf")
        defer { PrivateStaging.remove(scratch) }
        try convert(source, to: scratch)
        try protector.sealLargeFile(from: scratch, to: destination)
    }

    /// Writes `source` to `destination` as a CAF file: AAC when the source fits
    /// it (up to 48 kHz, stereo), 16-bit PCM otherwise.
    static func convert(_ source: URL, to destination: URL) throws {
        let input: AVAudioFile
        do { input = try AVAudioFile(forReading: source) } catch { throw AudioImportError.unreadable }
        guard input.length > 0 else { throw AudioImportError.unreadable }

        let format = input.processingFormat
        let output = try AVAudioFile(
            forWriting: destination,
            settings: outputSettings(sampleRate: format.sampleRate, channels: format.channelCount),
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else {
            throw AudioImportError.unreadable
        }
        while input.framePosition < input.length {
            do { try input.read(into: buffer, frameCount: chunkFrames) } catch { throw AudioImportError.unreadable }
            if buffer.frameLength == 0 { break }
            try output.write(from: buffer)
        }
    }

    static func outputSettings(sampleRate: Double, channels: AVAudioChannelCount) -> [String: Any] {
        if sampleRate <= 48_000, channels <= 2 {
            return [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: channels,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ]
        }
        return [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
    }
}
