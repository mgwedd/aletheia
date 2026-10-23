import XCTest
@testable import Aletheia

final class WhisperModelDownloaderTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("whisper-dl-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
    }

    func testReplaceIsAtomic() throws {
        let model = dir.appendingPathComponent("model.bin")
        try Data("old".utf8).write(to: model)

        // A failed replace leaves the existing model in place.
        let missing = dir.appendingPathComponent("missing.bin")
        XCTAssertThrowsError(try WhisperModelFile.replace(model, with: missing))
        XCTAssertEqual(try Data(contentsOf: model), Data("old".utf8))

        // A good replace swaps the contents and consumes the new file.
        let fresh = dir.appendingPathComponent("fresh.bin")
        try Data("new".utf8).write(to: fresh)
        try WhisperModelFile.replace(model, with: fresh)
        XCTAssertEqual(try Data(contentsOf: model), Data("new".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.path))
    }

    func testReplaceCreatesMissingDestination() throws {
        let model = dir.appendingPathComponent("model.bin")
        let fresh = dir.appendingPathComponent("fresh.bin")
        try Data("new".utf8).write(to: fresh)
        try WhisperModelFile.replace(model, with: fresh)
        XCTAssertEqual(try Data(contentsOf: model), Data("new".utf8))
    }

    func testLoadRefusesWrongSizeModel() async throws {
        let model = dir.appendingPathComponent("model.bin")
        try Data(repeating: 1, count: 10).write(to: model)
        XCTAssertThrowsError(try WhisperModelFile.verifySize(at: model, expectedBytes: 11)) {
            XCTAssertEqual($0 as? WhisperTranscriberError, .modelSizeMismatch)
        }
        XCTAssertNoThrow(try WhisperModelFile.verifySize(at: model, expectedBytes: 10))

        let transcriber = WhisperTranscriber(modelPath: model, expectedBytes: 11)
        do {
            _ = try await transcriber.transcribeSession(micURL: nil, callURL: nil) { _ in }
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error as? WhisperTranscriberError, .modelSizeMismatch)
        }
    }

    func testPinnedSizesAreSet() {
        for model in WhisperModel.allCases { XCTAssertGreaterThan(model.expectedBytes, 100_000_000) }
    }
}
