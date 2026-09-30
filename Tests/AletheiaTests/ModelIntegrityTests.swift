import XCTest
@testable import Aletheia

/// `ModelDigest.verify` is the pure gate the Whisper downloader runs on the
/// temp file before moving it into place. These pin its contract: match passes,
/// mismatch throws `integrityCheckFailed`, a missing file throws an I/O error
/// (not an integrity error), and pin case doesn't matter. There is no unpinned
/// path: every `WhisperModel` has a pin, checked below.
final class ModelIntegrityTests: XCTestCase {
    private var dir: URL!

    // SHA-256("abc")
    private let abcDigest = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ text: String, _ name: String = "model.bin") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url
    }

    func testMatchingDigestPasses() throws {
        let url = try write("abc")
        XCTAssertNoThrow(try ModelDigest.verify(fileAt: url, expectedSHA256: abcDigest))
    }

    func testMismatchThrowsIntegrityCheckFailedWithExpectedAndActual() throws {
        let url = try write("abc")
        let wrong = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try ModelDigest.verify(fileAt: url, expectedSHA256: wrong)) { error in
            guard case ModelDownloadError.integrityCheckFailed(let expected, let actual) = error else {
                return XCTFail("expected integrityCheckFailed, got \(error)")
            }
            XCTAssertEqual(expected, wrong)
            XCTAssertEqual(actual, abcDigest)
        }
    }

    func testTamperedContentIsRejected() throws {
        let url = try write("abd")
        XCTAssertThrowsError(try ModelDigest.verify(fileAt: url, expectedSHA256: abcDigest)) { error in
            guard case ModelDownloadError.integrityCheckFailed = error else {
                return XCTFail("expected integrityCheckFailed, got \(error)")
            }
        }
    }

    func testMissingFileThrowsIOErrorNotIntegrityError() {
        let missing = dir.appendingPathComponent("nope.bin")
        XCTAssertThrowsError(try ModelDigest.verify(fileAt: missing, expectedSHA256: abcDigest)) { error in
            if case ModelDownloadError.integrityCheckFailed = error {
                XCTFail("a missing file must not be reported as a hash mismatch")
            }
        }
    }

    func testUppercaseAndLowercasePinsBothMatch() throws {
        let url = try write("abc")
        XCTAssertNoThrow(try ModelDigest.verify(fileAt: url, expectedSHA256: abcDigest.lowercased()))
        XCTAssertNoThrow(try ModelDigest.verify(fileAt: url, expectedSHA256: abcDigest.uppercased()))
    }

    /// Every model must carry a pin: `expectedSHA256` is a non-optional
    /// `String` (exhaustive switch, no default), so this also fails if a pin is
    /// blank, the wrong length (e.g. a SHA-1) or not lowercase hex.
    func testEveryWhisperModelHasA64CharLowercaseHexPin() {
        for model in WhisperModel.allCases {
            let pin = model.expectedSHA256
            XCTAssertEqual(pin.count, 64, "\(model.rawValue) pin must be SHA-256 (64 hex chars)")
            XCTAssertNotNil(pin.range(of: "^[0-9a-f]{64}$", options: .regularExpression),
                            "\(model.rawValue) pin must be lowercase hex")
        }
    }

    func testWhisperPinsAreDistinct() {
        let pins = WhisperModel.allCases.map(\.expectedSHA256)
        XCTAssertEqual(Set(pins).count, pins.count, "two models share a pin")
    }

    /// The bytes must not be able to change under the pin: downloads come from
    /// an immutable Hugging Face commit, never a moving branch like `main`.
    func testWhisperDownloadURLsArePinnedToACommit() {
        XCTAssertNotNil(WhisperModel.revision.range(of: "^[0-9a-f]{40}$", options: .regularExpression),
                        "revision must be a 40-char commit sha")
        for model in WhisperModel.allCases {
            let url = model.downloadURL.absoluteString
            XCTAssertTrue(url.contains("/resolve/\(WhisperModel.revision)/"), "\(url) is not revision-pinned")
            XCTAssertFalse(url.contains("/resolve/main/"))
            XCTAssertTrue(url.hasSuffix("/\(model.fileName)"))
        }
    }
}
