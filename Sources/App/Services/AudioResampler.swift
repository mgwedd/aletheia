import AVFoundation

enum AudioResamplerError: LocalizedError {
    case conversionFailed

    var errorDescription: String? {
        "Couldn't prepare that recording for transcription."
    }
}

enum AudioResampler {
    /// Reads an audio file and returns 16kHz mono Float32 samples — the
    /// format whisper.cpp (and SwiftWhisper) expects.
    static func loadWhisperSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            throw AudioResamplerError.conversionFailed
        }
        guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
            throw AudioResamplerError.conversionFailed
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0, let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            return []
        }
        try file.read(into: inputBuffer)

        let outputCapacity = AVAudioFrameCount(Double(frameCount) * (16000.0 / inputFormat.sampleRate)) + 1024
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: outputCapacity) else {
            throw AudioResamplerError.conversionFailed
        }

        var conversionError: NSError?
        var suppliedInput = false
        let status = converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if suppliedInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            suppliedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if status == .error {
            throw conversionError ?? AudioResamplerError.conversionFailed
        }

        guard let channelData = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }
}
