import XCTest
import WhisperEngine
@testable import Aletheia

/// The whisper.cpp wrapper.
final class WhisperEngineTests: XCTestCase {
    func testLinksTheCurrentWhisperCpp() {
        XCTAssertTrue(WhisperEngine.version.hasPrefix("1.9"), WhisperEngine.version)
    }

    func testSegmentTimesAreHundredthsOfASecond() {
        XCTAssertEqual(WhisperEngine.seconds(fromCentiseconds: 0), 0)
        XCTAssertEqual(WhisperEngine.seconds(fromCentiseconds: 150), 1.5)
        XCTAssertEqual(WhisperEngine.seconds(fromCentiseconds: 360_000), 3600)
    }

    func testThreadsLeaveRoomAndAreCapped() {
        XCTAssertEqual(WhisperEngine.recommendedThreads(activeCores: 1), 1)
        XCTAssertEqual(WhisperEngine.recommendedThreads(activeCores: 4), 2)
        XCTAssertEqual(WhisperEngine.recommendedThreads(activeCores: 8), 6)
        XCTAssertEqual(WhisperEngine.recommendedThreads(activeCores: 14), 8)
    }

    func testMissingModelIsAnErrorNotACrash() {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-model-\(UUID()).bin")
        XCTAssertThrowsError(try WhisperEngine(modelPath: missing)) {
            XCTAssertEqual($0 as? WhisperEngineError, .modelLoadFailed)
        }
    }

    func testAFileThatIsNotAModelIsAnErrorNotACrash() throws {
        let junk = FileManager.default.temporaryDirectory.appendingPathComponent("junk-\(UUID()).bin")
        try Data(repeating: 7, count: 4096).write(to: junk)
        defer { try? FileManager.default.removeItem(at: junk) }
        // CPU only: this must fail at model load, so there is no reason to pay for
        // a Metal shader compile (unmeasured on CI; see issue #350).
        XCTAssertThrowsError(try WhisperEngine(modelPath: junk, useGPU: false)) {
            XCTAssertEqual($0 as? WhisperEngineError, .modelLoadFailed)
        }
    }

    // MARK: With a real model (skipped where none is downloaded, e.g. CI)

    private func downloadedModel() throws -> URL {
        let model = AppSettings.shared.whisperModelPath
        try XCTSkipUnless(FileManager.default.fileExists(atPath: model.path), "No speech model downloaded on this Mac")
        return model
    }

    /// Five seconds of a 440 Hz tone at 16 kHz: real work for the model, no speech.
    private var tone: [Float] {
        (0..<(16_000 * 5)).map { 0.2 * sin(2 * .pi * 440 * Float($0) / 16_000) }
    }

    func testTranscribesWithTheDownloadedModel() throws {
        let engine = try WhisperEngine(modelPath: try downloadedModel())
        var lastProgress = 0.0
        let segments = try engine.transcribe(samples: tone, onProgress: { lastProgress = max(lastProgress, $0) })
        XCTAssertLessThanOrEqual(lastProgress, 1)
        // A pure tone isn't speech: VAD drops it, so nothing is decoded and
        // nothing can be hallucinated.
        XCTAssertEqual(segments, [])
    }

    func testAbortStopsAndReturnsNothing() throws {
        let engine = try WhisperEngine(modelPath: try downloadedModel())
        XCTAssertThrowsError(try engine.transcribe(samples: tone, shouldAbort: { true })) {
            XCTAssertEqual($0 as? WhisperEngineError, .aborted)
        }
    }

    func testCancellingTheTaskThrowsCancellation() async throws {
        let model = try downloadedModel()
        let samples = tone
        let task = Task { try await WhisperTranscriber.segments(for: samples, modelPath: model, onProgress: { _ in }) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled transcription returned text")
        } catch is CancellationError {
        }
    }
}
