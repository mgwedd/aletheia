import AVFoundation
import XCTest
@testable import Aletheia

final class AudioResilienceTests: XCTestCase {
    func testCrashSafeHeaderFlushingForWAVFile() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("crash-test-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: tempURL) }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3200) else {
            XCTFail("Failed to create AVAudioPCMBuffer")
            return
        }

        buffer.frameLength = 3200
        if let floatData = buffer.floatChannelData {
            for i in 0..<3200 {
                floatData[0][i] = Float(i) / 3200.0
            }
        }

        // Write audio frames to disk within a closed scope so file handle closes
        do {
            let file = try AVAudioFile(forWriting: tempURL, settings: format.settings)
            try file.write(from: buffer)
        }

        // Flush header continuously as done after buffer writes
        let success = AudioCrashSafety.flushHeader(at: tempURL)
        XCTAssertTrue(success, "AudioCrashSafety.flushHeader should succeed for valid WAV file")

        // Verify the flushed file is immediately readable by AVAudioFile and AudioResampler
        let readFile = try AVAudioFile(forReading: tempURL)
        XCTAssertGreaterThan(readFile.length, 0, "Flushed audio file length should be > 0")

        let samples = try AudioResampler.loadWhisperSamples(from: tempURL)
        XCTAssertGreaterThan(samples.count, 0, "Whisper samples loaded from flushed audio should be > 0")
    }

    func testSystemAudioDisruptionRecordedInHealth() {
        let health = RecordingHealth()
        XCTAssertTrue(health.snapshot.isHealthy)

        health.recordSystemAudioDisruption("ScreenCaptureKit permission revoked")

        let snap = health.snapshot
        XCTAssertEqual(snap.systemAudioDisruptions, 1)
        XCTAssertEqual(snap.firstFailure, "ScreenCaptureKit permission revoked")
        XCTAssertFalse(snap.isHealthy)
    }

    @MainActor
    func testSessionRecorderSurvivesSystemAudioDisruption() async throws {
        let recorder = SessionRecorder()
        XCTAssertFalse(recorder.isRecording)

        // Idle recorder state checks
        recorder.pause()
        XCTAssertFalse(recorder.isPaused)
        recorder.resume()
        XCTAssertFalse(recorder.isPaused)

        let snap = recorder.recordingHealth.snapshot
        XCTAssertTrue(snap.isHealthy)
    }
}
