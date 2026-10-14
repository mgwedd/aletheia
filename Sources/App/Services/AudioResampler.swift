import AVFoundation

enum AudioResamplerError: LocalizedError {
    case conversionFailed

    var errorDescription: String? {
        "Couldn't prepare that recording for transcription."
    }
}

enum AudioResampler {
    /// Reads an audio file and returns 16kHz mono Float32 samples — the
    /// format whisper.cpp expects. Multi-channel files are
    /// reduced to their loudest channel first: the converter's default
    /// "downmix" remaps channels rather than mixing, so a file whose speech
    /// sits on a later channel would otherwise come out silent.
    static func loadWhisperSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let inputFormat = file.processingFormat
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false) else {
            throw AudioResamplerError.conversionFailed
        }

        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0, let inputBuffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: frameCount) else {
            return []
        }
        try file.read(into: inputBuffer)
        let sourceBuffer = loudestChannelBuffer(from: inputBuffer) ?? inputBuffer
        let sourceFormat = sourceBuffer.format
        guard let converter = AVAudioConverter(from: sourceFormat, to: outputFormat) else {
            throw AudioResamplerError.conversionFailed
        }

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
            return sourceBuffer
        }
        if status == .error {
            throw conversionError ?? AudioResamplerError.conversionFailed
        }

        guard let channelData = outputBuffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(outputBuffer.frameLength)))
    }

    /// Index of the channel with the highest level; ties go to the earliest.
    static func loudestChannelIndex(levels: [Double]) -> Int {
        var best = 0
        for (index, value) in levels.enumerated() where value > levels[best] {
            best = index
        }
        return best
    }

    /// A mono copy of `buffer`'s loudest channel, or nil when the buffer is
    /// already mono (or isn't float data).
    static func loudestChannelBuffer(from buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        let channelCount = Int(buffer.format.channelCount)
        guard channelCount > 1, let channels = buffer.floatChannelData else { return nil }
        let frames = Int(buffer.frameLength)
        var energy = [Double](repeating: 0, count: channelCount)
        for channel in 0..<channelCount {
            var sum = 0.0
            for frame in 0..<frames {
                let sample = Double(channels[channel][frame])
                sum += sample * sample
            }
            energy[channel] = sum
        }
        let pick = loudestChannelIndex(levels: energy)
        guard let monoFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: buffer.format.sampleRate,
            channels: 1,
            interleaved: false
        ), let mono = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: buffer.frameLength),
              let destination = mono.floatChannelData else { return nil }
        destination[0].update(from: channels[pick], count: frames)
        mono.frameLength = buffer.frameLength
        return mono
    }

    /// Length of the window `isEssentiallySilent` judges, in 16 kHz samples (1 s).
    static let silenceWindow = 16_000

    /// True if no one-second window of `samples` has RMS above `rmsThreshold`
    /// (or there are none). Judging windows rather than the whole file keeps a
    /// short stretch of speech in a long, mostly quiet recording (a call where
    /// the patient barely talks) from being averaged down to "silence". The
    /// default is about -54 dBFS, well under quiet speech. A trailing partial
    /// window is diluted to a full window, so a lone click at the end doesn't
    /// count as sound; a file shorter than one window is judged whole.
    static func isEssentiallySilent(_ samples: [Float], rmsThreshold: Float = 0.002) -> Bool {
        guard !samples.isEmpty else { return true }
        let window = min(silenceWindow, samples.count)
        var start = 0
        while start < samples.count {
            let end = min(start + window, samples.count)
            var sumOfSquares = 0.0
            for index in start..<end {
                sumOfSquares += Double(samples[index]) * Double(samples[index])
            }
            let rms = (sumOfSquares / Double(window)).squareRoot()
            if Float(rms) > rmsThreshold { return false }
            start = end
        }
        return true
    }
}
