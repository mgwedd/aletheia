import AVFoundation

enum MicFileWriterError: LocalizedError {
    case closed
    case conversionFailed

    var errorDescription: String? {
        switch self {
        case .closed: return "The microphone file is already closed."
        case .conversionFailed: return "Couldn't convert the microphone audio to the recording's format."
        }
    }
}

/// Writes microphone buffers to the recording file, converting any buffer
/// whose format differs from the file's.
///
/// The file is opened once with the input device's format at record start. If
/// the device then changes (Bluetooth headset connects, a call app switches
/// the input to a different sample rate), buffers arrive in the new format;
/// handing those straight to `AVAudioFile.write` fails or garbles the file,
/// silently losing the rest of the session. Converting keeps one continuous
/// track in the original format.
///
/// Not thread-safe: use from the audio tap only, between creation and `close()`.
final class MicFileWriter {
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var converterSource: AVAudioFormat?

    init(url: URL, format: AVAudioFormat) throws {
        file = try AVAudioFile(forWriting: url, settings: format.settings)
    }

    /// The format the file stores; buffers in other formats are converted to it.
    var fileFormat: AVAudioFormat? { file?.processingFormat }

    func write(_ buffer: AVAudioPCMBuffer) throws {
        guard let file else { throw MicFileWriterError.closed }
        guard buffer.frameLength > 0 else { return }
        let target = file.processingFormat
        if buffer.format == target {
            try file.write(from: buffer)
            return
        }

        if converterSource != buffer.format || converter == nil {
            guard let made = AVAudioConverter(from: buffer.format, to: target) else {
                throw MicFileWriterError.conversionFailed
            }
            // Fold extra channels into the file's rather than dropping all but one.
            made.downmix = target.channelCount < buffer.format.channelCount
            converter = made
            converterSource = buffer.format
        }
        guard let converter else { throw MicFileWriterError.conversionFailed }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let converted = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw MicFileWriterError.conversionFailed
        }

        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: converted, error: &conversionError) { _, outStatus in
            if supplied {
                outStatus.pointee = .noDataNow
                return nil
            }
            supplied = true
            outStatus.pointee = .haveData
            return buffer
        }
        if status == .error { throw conversionError ?? MicFileWriterError.conversionFailed }
        if converted.frameLength > 0 { try file.write(from: converted) }
    }

    /// Closes the file (AVAudioFile finalises on release).
    func close() {
        file = nil
        converter = nil
        converterSource = nil
    }
}
