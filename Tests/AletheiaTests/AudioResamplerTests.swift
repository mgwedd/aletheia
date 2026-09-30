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
}
