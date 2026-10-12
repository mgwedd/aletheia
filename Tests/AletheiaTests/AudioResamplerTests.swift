import AVFoundation
import XCTest
@testable import Aletheia

final class AudioResamplerTests: XCTestCase {
    func testAudioResamplerErrorDescription() {
        XCTAssertNotNil(AudioResamplerError.conversionFailed.errorDescription)
        XCTAssertTrue(AudioResamplerError.conversionFailed.errorDescription?.contains("transcription") == true)
    }

    func testLoadWhisperSamplesWithValidAudioFile() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-\(UUID().uuidString).wav")

        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600) else {
            XCTFail("Failed to create AVAudioPCMBuffer")
            return
        }

        buffer.frameLength = 1600
        if let floatData = buffer.floatChannelData {
            for i in 0..<1600 {
                floatData[0][i] = Float(Float(i) / 1600.0)
            }
        }

        do {
            let audioFile = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            try audioFile.write(from: buffer)
        }

        let samples = try AudioResampler.loadWhisperSamples(from: tempURL)
        XCTAssertGreaterThan(samples.count, 0)
    }

    func testLoadWhisperSamplesWithNonexistentFileThrows() {
        let fakeURL = FileManager.default.temporaryDirectory.appendingPathComponent("nonexistent-\(UUID().uuidString).wav")
        XCTAssertThrowsError(try AudioResampler.loadWhisperSamples(from: fakeURL))
    }

    // MARK: - Windowed silence

    private func sine(seconds: Double, amplitude: Float, rate: Double = 16000) -> [Float] {
        (0..<Int(seconds * rate)).map { amplitude * sin(2 * .pi * 440 * Float($0) / Float(rate)) }
    }

    func testBriefSpeechInALongQuietRecordingIsNotSilent() {
        // Five minutes of nothing with two seconds of quiet speech: the
        // whole-file RMS is below the threshold, but the speech is there.
        var samples = [Float](repeating: 0, count: 5 * 60 * 16000)
        let speech = sine(seconds: 2, amplitude: 0.02)
        samples.replaceSubrange(100_000..<(100_000 + speech.count), with: speech)

        let wholeFile = sqrt(samples.reduce(0.0) { $0 + Double($1) * Double($1) } / Double(samples.count))
        XCTAssertLessThan(Float(wholeFile), 0.002, "precondition: averaged over the file it looks silent")
        XCTAssertFalse(AudioResampler.isEssentiallySilent(samples))
    }

    func testAllQuietLongRecordingIsStillSilent() {
        let samples = sine(seconds: 120, amplitude: 0.001)
        XCTAssertTrue(AudioResampler.isEssentiallySilent(samples))
    }

    func testLoneClickAtTheEndIsNotSound() {
        var samples = [Float](repeating: 0, count: 3 * 16000 + 5)
        samples[samples.count - 1] = 0.05
        XCTAssertTrue(AudioResampler.isEssentiallySilent(samples))
    }

    func testShortFileIsJudgedWhole() {
        XCTAssertFalse(AudioResampler.isEssentiallySilent(sine(seconds: 0.25, amplitude: 0.02)))
        XCTAssertTrue(AudioResampler.isEssentiallySilent([Float](repeating: 0, count: 4000)))
    }

    // MARK: - Channel selection

    func testLoudestChannelIndexPicksTheHighestAndPrefersTheFirstOnTies() {
        XCTAssertEqual(AudioResampler.loudestChannelIndex(levels: [0, 0.5, 0.2]), 1)
        XCTAssertEqual(AudioResampler.loudestChannelIndex(levels: [0.3, 0.3]), 0)
        XCTAssertEqual(AudioResampler.loudestChannelIndex(levels: [0, 0]), 0)
        XCTAssertEqual(AudioResampler.loudestChannelIndex(levels: []), 0)
    }

    private func writeStereo(left: [Float], right: [Float], rate: Double) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("stereo-\(UUID().uuidString).caf")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(left.count)))
        buffer.frameLength = AVAudioFrameCount(left.count)
        let data = try XCTUnwrap(buffer.floatChannelData)
        for index in 0..<left.count {
            data[0][index] = left[index]
            data[1][index] = right[index]
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
        return url
    }

    func testSpeechOnlyOnTheSecondChannelSurvivesLoading() throws {
        let rate = 48_000.0
        let silent = [Float](repeating: 0, count: Int(rate * 2))
        let speech = sine(seconds: 2, amplitude: 0.3, rate: rate)
        let url = try writeStereo(left: silent, right: speech, rate: rate)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try AudioResampler.loadWhisperSamples(from: url)
        XCTAssertEqual(Double(samples.count), 2 * 16000, accuracy: 2000)
        XCTAssertFalse(AudioResampler.isEssentiallySilent(samples))
    }

    func testSpeechOnlyOnTheFirstChannelSurvivesLoading() throws {
        let rate = 44_100.0
        let silent = [Float](repeating: 0, count: Int(rate * 2))
        let speech = sine(seconds: 2, amplitude: 0.3, rate: rate)
        let url = try writeStereo(left: speech, right: silent, rate: rate)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertFalse(AudioResampler.isEssentiallySilent(try AudioResampler.loadWhisperSamples(from: url)))
    }

    func testMonoBuffersAreLeftAlone() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 10))
        buffer.frameLength = 10
        XCTAssertNil(AudioResampler.loudestChannelBuffer(from: buffer))
    }
}
