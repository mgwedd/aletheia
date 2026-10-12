import AVFoundation
import XCTest
@testable import Aletheia

final class MicFileWriterTests: XCTestCase {
    private var urls: [URL] = []

    override func tearDown() {
        for url in urls { try? FileManager.default.removeItem(at: url) }
        urls = []
        super.tearDown()
    }

    private func tempURL() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mic-\(UUID().uuidString).caf")
        urls.append(url)
        return url
    }

    private func format(rate: Double, channels: AVAudioChannelCount = 1) throws -> AVAudioFormat {
        try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false))
    }

    private func tone(_ format: AVAudioFormat, seconds: Double, amplitude: Float = 0.3) throws -> AVAudioPCMBuffer {
        let frames = AVAudioFrameCount(seconds * format.sampleRate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        let data = try XCTUnwrap(buffer.floatChannelData)
        for channel in 0..<Int(format.channelCount) {
            for frame in 0..<Int(frames) {
                data[channel][frame] = amplitude * sin(2 * .pi * 440 * Float(frame) / Float(format.sampleRate))
            }
        }
        return buffer
    }

    private func recordedSeconds(_ url: URL) throws -> Double {
        let file = try AVAudioFile(forReading: url)
        return Double(file.length) / file.processingFormat.sampleRate
    }

    func testMatchingFormatIsWrittenUntouched() throws {
        let url = tempURL()
        let f = try format(rate: 48_000)
        let writer = try MicFileWriter(url: url, format: f)
        try writer.write(tone(f, seconds: 1))
        try writer.write(tone(f, seconds: 1))
        writer.close()

        XCTAssertEqual(try AVAudioFile(forReading: url).length, 96_000)
    }

    func testBuffersAtAnotherSampleRateKeepTheWholeSession() throws {
        let url = tempURL()
        let original = try format(rate: 48_000)
        let switched = try format(rate: 24_000)
        let writer = try MicFileWriter(url: url, format: original)
        try writer.write(tone(original, seconds: 1))
        // Input device changes (e.g. headset connects): same call, new rate.
        for _ in 0..<3 { try writer.write(tone(switched, seconds: 1)) }
        writer.close()

        XCTAssertEqual(try recordedSeconds(url), 4, accuracy: 0.15)
    }

    func testConvertedAudioIsStillAudible() throws {
        let url = tempURL()
        let original = try format(rate: 48_000)
        let switched = try format(rate: 16_000)
        let writer = try MicFileWriter(url: url, format: original)
        try writer.write(tone(switched, seconds: 2))
        writer.close()

        let samples = try AudioResampler.loadWhisperSamples(from: url)
        XCTAssertFalse(AudioResampler.isEssentiallySilent(samples))
    }

    func testStereoBufferIntoMonoFileKeepsDuration() throws {
        let url = tempURL()
        let mono = try format(rate: 44_100)
        let stereo = try format(rate: 44_100, channels: 2)
        let writer = try MicFileWriter(url: url, format: mono)
        try writer.write(tone(stereo, seconds: 2))
        writer.close()

        XCTAssertEqual(try recordedSeconds(url), 2, accuracy: 0.1)
        XCTAssertFalse(AudioResampler.isEssentiallySilent(try AudioResampler.loadWhisperSamples(from: url)))
    }

    func testEmptyBufferIsIgnored() throws {
        let url = tempURL()
        let f = try format(rate: 16_000)
        let writer = try MicFileWriter(url: url, format: f)
        let empty = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: f, frameCapacity: 16))
        empty.frameLength = 0
        XCTAssertNoThrow(try writer.write(empty))
        writer.close()
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 0)
    }

    func testWritingAfterCloseThrows() throws {
        let f = try format(rate: 16_000)
        let writer = try MicFileWriter(url: tempURL(), format: f)
        writer.close()
        XCTAssertThrowsError(try writer.write(tone(f, seconds: 0.1)))
        XCTAssertNil(writer.fileFormat)
    }
}
