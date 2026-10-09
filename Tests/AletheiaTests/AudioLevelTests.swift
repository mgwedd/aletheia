import AVFoundation
import XCTest
@testable import Aletheia

final class AudioLevelTests: XCTestCase {
    private func rms(_ samples: [Float]) -> Float {
        samples.withUnsafeBufferPointer { AudioLevel.rms($0) }
    }

    // MARK: RMS

    func testEmptyBufferIsZero() {
        XCTAssertEqual(rms([]), 0)
    }

    func testSilenceIsZero() {
        XCTAssertEqual(rms([Float](repeating: 0, count: 1024)), 0)
    }

    func testFullScaleSquareWaveIsOne() {
        let square: [Float] = (0..<1024).map { $0 % 2 == 0 ? 1 : -1 }
        XCTAssertEqual(rms(square), 1, accuracy: 1e-6)
    }

    func testFullScaleSineIsAboutMinusThreeDB() {
        let sine: [Float] = (0..<4800).map { sin(2 * .pi * Float($0) / 48) }
        XCTAssertEqual(rms(sine), 0.70710678, accuracy: 1e-3)
    }

    // MARK: dBFS mapping

    func testSilenceMapsToZero() {
        XCTAssertEqual(AudioLevel.normalized(rms: 0), 0)
    }

    func testFullScaleMapsToOne() {
        XCTAssertEqual(AudioLevel.normalized(rms: 1), 1, accuracy: 1e-6)
    }

    func testFloorMapsToZeroAndBelowIsClamped() {
        XCTAssertEqual(AudioLevel.normalized(rms: 0.001), 0, accuracy: 1e-5) // -60 dBFS
        XCTAssertEqual(AudioLevel.normalized(rms: 0.0001), 0)
    }

    func testAboveFullScaleIsClamped() {
        XCTAssertEqual(AudioLevel.normalized(rms: 4), 1)
    }

    func testMinusThirtyDBIsHalfway() {
        XCTAssertEqual(AudioLevel.normalized(rms: 0.0316227766), 0.5, accuracy: 1e-3)
    }

    func testNonsenseInputIsZero() {
        XCTAssertEqual(AudioLevel.normalized(rms: -1), 0)
        XCTAssertEqual(AudioLevel.normalized(rms: .nan), 0)
    }

    // MARK: Buffers

    private func floatBuffer(channels: [[Float]], interleaved: Bool) throws -> AVAudioPCMBuffer {
        let frames = channels[0].count
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: AVAudioChannelCount(channels.count),
            interleaved: interleaved
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        buffer.frameLength = AVAudioFrameCount(frames)
        let data = try XCTUnwrap(buffer.floatChannelData)
        if interleaved {
            for frame in 0..<frames {
                for (index, channel) in channels.enumerated() {
                    data[0][frame * channels.count + index] = channel[frame]
                }
            }
        } else {
            for (index, channel) in channels.enumerated() {
                for frame in 0..<frames { data[index][frame] = channel[frame] }
            }
        }
        return buffer
    }

    func testStereoNonInterleavedBufferCombinesChannels() throws {
        let loud = [Float](repeating: 1, count: 256)
        let quiet = [Float](repeating: 0, count: 256)
        let buffer = try floatBuffer(channels: [loud, quiet], interleaved: false)
        // Mean power of (1, 0) is 0.5 -> rms ~0.707 -> about -3 dBFS.
        let expected = AudioLevel.normalized(rms: 0.70710678)
        XCTAssertEqual(try XCTUnwrap(AudioLevel.level(of: buffer)), expected, accuracy: 1e-4)
    }

    func testInterleavedBufferMatchesNonInterleaved() throws {
        let left: [Float] = (0..<256).map { $0 % 2 == 0 ? 0.5 : -0.5 }
        let right: [Float] = (0..<256).map { $0 % 2 == 0 ? 0.25 : -0.25 }
        let planar = try floatBuffer(channels: [left, right], interleaved: false)
        let interleaved = try floatBuffer(channels: [left, right], interleaved: true)
        XCTAssertEqual(
            try XCTUnwrap(AudioLevel.level(of: planar)),
            try XCTUnwrap(AudioLevel.level(of: interleaved)),
            accuracy: 1e-5
        )
    }

    func testSilentBufferIsZeroAndEmptyBufferIsZero() throws {
        let silent = try floatBuffer(channels: [[Float](repeating: 0, count: 128)], interleaved: false)
        XCTAssertEqual(AudioLevel.level(of: silent), 0)
        silent.frameLength = 0
        XCTAssertEqual(AudioLevel.level(of: silent), 0)
    }

    func testNonFloatBufferIsSkipped() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 48_000, channels: 1, interleaved: true))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128))
        buffer.frameLength = 128
        XCTAssertNil(AudioLevel.level(of: buffer))
    }

    // MARK: Smoother

    func testSmootherRisesFasterThanItFalls() {
        let dt: Float = 1.0 / 15.0
        var rising = AudioLevelSmoother()
        let up = rising.update(target: 1, dt: dt)

        var falling = AudioLevelSmoother()
        falling.update(target: 1, dt: 5) // settle at the top
        let top = falling.value
        let down = top - falling.update(target: 0, dt: dt)

        XCTAssertGreaterThan(up, 0.5)
        XCTAssertLessThan(down, 0.3)
        XCTAssertGreaterThan(up, down)
    }

    func testSmootherConvergesAndStaysInRange() {
        var smoother = AudioLevelSmoother()
        for _ in 0..<200 { smoother.update(target: 1.7, dt: 0.1) }
        XCTAssertEqual(smoother.value, 1, accuracy: 1e-3)
        for _ in 0..<200 { smoother.update(target: -3, dt: 0.1) }
        XCTAssertEqual(smoother.value, 0, accuracy: 1e-3)
    }

    func testSmootherIgnoresNonPositiveDelta() {
        var smoother = AudioLevelSmoother()
        smoother.update(target: 1, dt: 0.1)
        let before = smoother.value
        XCTAssertEqual(smoother.update(target: 0, dt: 0), before)
        XCTAssertEqual(smoother.update(target: 0, dt: -1), before)
    }

    func testSmootherReset() {
        var smoother = AudioLevelSmoother()
        smoother.update(target: 1, dt: 1)
        smoother.reset()
        XCTAssertEqual(smoother.value, 0)
    }

    // MARK: Meter source

    func testSourceReportsLatestThenResets() {
        let source = LevelMeterSource()
        XCTAssertEqual(source.latest(), 0)
        source.publish(0.6)
        XCTAssertEqual(source.latest(), 0.6, accuracy: 1e-6)
        source.reset()
        XCTAssertEqual(source.latest(), 0)
    }

    func testSourceTreatsStaleReadingAsSilence() {
        let source = LevelMeterSource()
        source.publish(0.9)
        XCTAssertEqual(source.latest(maxAge: -1), 0)
    }
}
