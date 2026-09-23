import AletheiaCore
import CryptoKit
import XCTest
@testable import Aletheia

final class FileProtectorLargeFileTests: XCTestCase {
    private var dir: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileProtectorLargeFileTests-\(UUID().uuidString)", isDirectory: true)
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
