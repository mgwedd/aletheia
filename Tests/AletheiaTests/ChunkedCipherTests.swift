import CryptoKit
import XCTest
@testable import Aletheia

final class ChunkedCipherTests: XCTestCase {
    private var dir: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ChunkedCipherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ bytes: Data, _ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try bytes.write(to: url)
        return url
    }

    private func randomData(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    func testRoundTripSpansManyChunks() throws {
        let plaintext = randomData(10_000)
        let src = try write(plaintext, "src.bin")
        let sealed = dir.appendingPathComponent("sealed.bin")
        let opened = dir.appendingPathComponent("opened.bin")

        // Tiny chunk size to force ~20 chunks.
        try ChunkedCipher.seal(fileAt: src, to: sealed, using: key, chunkSize: 512)
        XCTAssertTrue(ChunkedCipher.isEnvelope(fileAt: sealed))
        let sealedBytes = try Data(contentsOf: sealed)
        XCTAssertNil(sealedBytes.range(of: plaintext.prefix(512)), "plaintext must not survive in the sealed file")

        try ChunkedCipher.open(fileAt: sealed, to: opened, using: key)
        XCTAssertEqual(try Data(contentsOf: opened), plaintext)
    }

    func testExactMultipleOfChunkSizeRoundTrips() throws {
        let plaintext = randomData(1024) // exactly 2 × 512
        let src = try write(plaintext, "src.bin")
        let sealed = dir.appendingPathComponent("sealed.bin")
        let opened = dir.appendingPathComponent("opened.bin")
        try ChunkedCipher.seal(fileAt: src, to: sealed, using: key, chunkSize: 512)
        try ChunkedCipher.open(fileAt: sealed, to: opened, using: key)
        XCTAssertEqual(try Data(contentsOf: opened), plaintext)
    }

    func testEmptyFileRoundTrips() throws {
        let src = try write(Data(), "empty.bin")
        let sealed = dir.appendingPathComponent("sealed.bin")
        let opened = dir.appendingPathComponent("opened.bin")
        try ChunkedCipher.seal(fileAt: src, to: sealed, using: key, chunkSize: 512)
        try ChunkedCipher.open(fileAt: sealed, to: opened, using: key)
        XCTAssertEqual(try Data(contentsOf: opened), Data())
    }

    func testWrongKeyFails() throws {
        let src = try write(randomData(2000), "src.bin")
        let sealed = dir.appendingPathComponent("sealed.bin")
        try ChunkedCipher.seal(fileAt: src, to: sealed, using: key, chunkSize: 512)
        XCTAssertThrowsError(try ChunkedCipher.open(fileAt: sealed, to: dir.appendingPathComponent("o.bin"), using: SymmetricKey(size: .bits256)))
    }

    func testTruncatedFileFails() throws {
        let src = try write(randomData(3000), "src.bin")
        let sealed = dir.appendingPathComponent("sealed.bin")
        try ChunkedCipher.seal(fileAt: src, to: sealed, using: key, chunkSize: 512)

        // Drop the final 100 bytes: a declared chunk goes missing → open fails.
        let full = try Data(contentsOf: sealed)
        let chopped = full.prefix(full.count - 100)
        let truncated = dir.appendingPathComponent("truncated.bin")
        try Data(chopped).write(to: truncated)
        XCTAssertThrowsError(try ChunkedCipher.open(fileAt: truncated, to: dir.appendingPathComponent("o.bin"), using: key))
    }

    func testTamperedChunkFails() throws {
        let src = try write(randomData(2000), "src.bin")
        let sealed = dir.appendingPathComponent("sealed.bin")
        try ChunkedCipher.seal(fileAt: src, to: sealed, using: key, chunkSize: 512)

        var bytes = try Data(contentsOf: sealed)
        bytes[bytes.count - 1] ^= 0xFF
        let tampered = dir.appendingPathComponent("tampered.bin")
        try bytes.write(to: tampered)
        XCTAssertThrowsError(try ChunkedCipher.open(fileAt: tampered, to: dir.appendingPathComponent("o.bin"), using: key))
    }

    func testNonEnvelopeIsRejected() throws {
        let plain = try write(Data("not encrypted".utf8), "plain.bin")
        XCTAssertFalse(ChunkedCipher.isEnvelope(fileAt: plain))
        XCTAssertThrowsError(try ChunkedCipher.open(fileAt: plain, to: dir.appendingPathComponent("o.bin"), using: key))
    }

    // MARK: - FileProtector large-file helpers

    func testSealInPlaceThenDecryptedCopyRoundTrips() throws {
        let plaintext = randomData(5000)
        let audio = try write(plaintext, "mic.caf")
        let protector = FileProtector(key: key)

        try protector.sealLargeFileInPlace(at: audio)
        XCTAssertTrue(ChunkedCipher.isEnvelope(fileAt: audio), "the file on disk is now sealed")

        let (readURL, isTemp) = try protector.decryptedCopyOfLargeFile(at: audio)
        XCTAssertTrue(isTemp)
        XCTAssertEqual(try Data(contentsOf: readURL), plaintext)
        try? FileManager.default.removeItem(at: readURL)
    }

    func testSealInPlaceIsNoOpTwice() throws {
        let audio = try write(randomData(1000), "mic.caf")
        let protector = FileProtector(key: key)
        try protector.sealLargeFileInPlace(at: audio)
        let firstSealed = try Data(contentsOf: audio)
        try protector.sealLargeFileInPlace(at: audio) // already an envelope → skipped
        XCTAssertEqual(try Data(contentsOf: audio), firstSealed, "a sealed file is not double-sealed")
    }

    func testPassthroughLeavesAudioPlaintext() throws {
        let plaintext = randomData(1000)
        let audio = try write(plaintext, "mic.caf")
        let protector = FileProtector.passthrough

        try protector.sealLargeFileInPlace(at: audio)
        XCTAssertFalse(ChunkedCipher.isEnvelope(fileAt: audio))
        XCTAssertEqual(try Data(contentsOf: audio), plaintext)

        let (readURL, isTemp) = try protector.decryptedCopyOfLargeFile(at: audio)
        XCTAssertFalse(isTemp, "no key → original returned untouched")
        XCTAssertEqual(readURL, audio)
    }
}
