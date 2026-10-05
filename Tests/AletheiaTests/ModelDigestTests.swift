import XCTest
import CryptoKit
@testable import Aletheia

/// `ModelDigest` streams a file through SHA-256; these pin it against known
/// vectors and confirm the chunked read matches a one-shot hash across chunk
/// boundaries (the case that would break if the streaming loop dropped or
/// double-counted a block).
final class ModelDigestTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ data: Data, _ name: String = "f.bin") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    func testKnownVectorABC() throws {
        let url = try write(Data("abc".utf8))
        XCTAssertEqual(
            try ModelDigest.sha256(ofFileAt: url),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    func testEmptyFileVector() throws {
        let url = try write(Data())
        XCTAssertEqual(
            try ModelDigest.sha256(ofFileAt: url),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    func testChunkedReadMatchesOneShotAcrossBoundaries() throws {
        // ~3.5 MiB of non-uniform bytes so the content spans several 1 MiB chunks
        // and a partial final chunk.
        var bytes = Data(count: 0)
        bytes.reserveCapacity(3_500_000)
        for i in 0..<3_500_000 { bytes.append(UInt8(i % 251)) }
        let url = try write(bytes, "big.bin")

        let oneShot = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try ModelDigest.sha256(ofFileAt: url), oneShot)
        // Also exercise a small chunk size to force many boundary crossings.
        XCTAssertEqual(try ModelDigest.sha256(ofFileAt: url, chunkSize: 64 * 1024), oneShot)
    }

    func testMatchesIsCaseInsensitive() throws {
        let url = try write(Data("abc".utf8))
        let upper = "BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD"
        XCTAssertTrue(try ModelDigest.matches(fileAt: url, expected: upper))
        XCTAssertFalse(try ModelDigest.matches(fileAt: url, expected: String(repeating: "0", count: 64)))
    }

    func testMissingFileThrows() {
        let missing = dir.appendingPathComponent("nope.bin")
        XCTAssertThrowsError(try ModelDigest.sha256(ofFileAt: missing))
    }
}
