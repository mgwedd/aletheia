import AVFoundation

enum AudioImportError: LocalizedError, Equatable {
    /// The file isn't audio Aletheia can read, or it holds no sound.
    case unreadable
    /// The session already has a recording; importing would replace it.
    case sessionHasRecording
    /// More than two files were picked; a session has a microphone and a call track.
    case tooManyFiles

    var errorDescription: String? {
        switch self {
        case .unreadable:
            return "Aletheia couldn't read that file as audio. Try an M4A, MP3, WAV, AIFF or CAF file."
        case .sessionHasRecording:
            return "This session already has a recording. Import into a new session instead."
        case .tooManyFiles:
            return "Pick one audio file, or two: the microphone track and the call track."
        }
    }
}

/// Brings the audio the user picked into a session, so it can be transcribed
/// like one recorded in the app. One file becomes the microphone recording;
/// two become the microphone and call tracks, as Aletheia records and exports
/// them.
///
/// Each file is converted to the recording format in the private scratch folder
/// (never next to the original), then sealed into the session folder the same
/// way a finished recording is. The original file is only read.
enum AudioImport {
    /// Frames converted per pass, so a long session never sits in memory whole.
    private static let chunkFrames: AVAudioFrameCount = 1 << 16

    /// Which picked file is which track. A file whose name mentions "call"
    /// is the call track and the other the microphone; when the names don't
    /// tell them apart, the first by name is the microphone.
    static func tracks(for sources: [URL]) throws -> (mic: URL, call: URL?) {
        switch sources.count {
        case 1: return (sources[0], nil)
        case 2:
            let named = sources.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let isCall = named.map { $0.deletingPathExtension().lastPathComponent.localizedCaseInsensitiveContains("call") }
            if isCall[0] && !isCall[1] { return (named[1], named[0]) }
            return (named[0], named[1])
        case 0: throw AudioImportError.unreadable
        default: throw AudioImportError.tooManyFiles
        }
    }

    /// Converts each `(source, destination)` pair and seals it with `protector`.
    /// Every file is converted before any is sealed, so a file that isn't
    /// usable audio leaves nothing behind. Throws `AudioImportError.unreadable`
    /// for a file that isn't usable audio.
    static func importRecordings(_ pairs: [(source: URL, destination: URL)], protector: FileProtector) throws {
        var scratches: [URL] = []
        defer { scratches.forEach(PrivateStaging.remove) }
        for pair in pairs {
            let scoped = pair.source.startAccessingSecurityScopedResource()
            defer { if scoped { pair.source.stopAccessingSecurityScopedResource() } }
            let scratch = try PrivateStaging.scratchFile(prefix: "import", ext: "caf")
            scratches.append(scratch)
            try convert(pair.source, to: scratch)
        }
        var sealed: [URL] = []
        do {
            for (scratch, pair) in zip(scratches, pairs) {
                try protector.sealLargeFile(from: scratch, to: pair.destination)
                sealed.append(pair.destination)
            }
        } catch {
            for url in sealed { try? FileManager.default.removeItem(at: url) }
            throw error
        }
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
