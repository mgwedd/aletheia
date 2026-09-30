import XCTest
@testable import Aletheia

/// `ModelDigest.verify` is the pure gate the Whisper downloader runs on the
/// temp file before moving it into place. These pin its contract: match passes,
/// mismatch throws `integrityCheckFailed`, a missing file throws an I/O error
/// (not an integrity error), pin case doesn't matter, and a `nil` pin is
/// "unverified — proceed" (deliberately not fail-closed).
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

    func testNilPinAcceptsFileUnverified() throws {
        let url = try write("anything at all")
        XCTAssertNoThrow(try ModelDigest.verify(fileAt: url, expectedSHA256: nil))
    }

    func testNilPinDoesNotReadTheFile() {
        // Unpinned models proceed even when there's nothing to hash: the gate
        // is skipped entirely, not failed closed.
        let missing = dir.appendingPathComponent("nope.bin")
        XCTAssertNoThrow(try ModelDigest.verify(fileAt: missing, expectedSHA256: nil))
    }

    /// Guards future pin edits: any pin that gets filled in must be a 64-char
    /// lowercase hex SHA-256 (not SHA-1, not padded/uppercase). Unpinned (nil)
    /// entries are allowed and mean "unverified".
    func testWhisperPinsAreWellFormedWhenPresent() {
        for model in WhisperModel.allCases {
            guard let pin = model.expectedSHA256 else { continue }
            XCTAssertEqual(pin.count, 64, "\(model.rawValue) pin must be SHA-256 (64 hex chars)")
            XCTAssertNotNil(pin.range(of: "^[0-9a-f]{64}$", options: .regularExpression),
                            "\(model.rawValue) pin must be lowercase hex")
        }
    }
}
