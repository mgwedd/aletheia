import CryptoKit
import XCTest
@testable import Aletheia

final class FileProtectorTests: XCTestCase {
    private var tempRoot: URL!
    private let key = SymmetricKey(size: .bits256)

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileProtectorTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
    }

    private func url(_ name: String) -> URL { tempRoot.appendingPathComponent(name) }

    func testPassthroughWritesPlaintextAndReadsBack() throws {
        let p = FileProtector.passthrough
        XCTAssertFalse(p.isEncrypting)
        let file = url("plain.txt")
        try p.write("hello", to: file)

        let onDisk = try Data(contentsOf: file)
        XCTAssertFalse(DataCipher.isEnvelope(onDisk), "passthrough must write real plaintext")
        XCTAssertEqual(onDisk, Data("hello".utf8))
        XCTAssertEqual(try p.string(contentsOf: file), "hello")
    }

    func testEncryptingWritesEnvelopeAndDecryptsBack() throws {
        let p = FileProtector(key: key)
        XCTAssertTrue(p.isEncrypting)
        let file = url("sealed.txt")
        try p.write("session notes", to: file)

        let onDisk = try Data(contentsOf: file)
        XCTAssertTrue(DataCipher.isEnvelope(onDisk), "a key means files land as envelopes")
        XCTAssertNotEqual(onDisk, Data("session notes".utf8))
        XCTAssertEqual(try p.string(contentsOf: file), "session notes")
    }

    func testKeyedReadOfLegacyPlaintextReturnsAsIs() throws {
        // A file written before encryption was turned on: still readable, so a
        // folder can migrate lazily rather than all at once.
        let file = url("legacy.txt")
        try Data("old plaintext".utf8).write(to: file)
        let p = FileProtector(key: key)
        XCTAssertEqual(try p.string(contentsOf: file), "old plaintext")
    }

    func testEnvelopeReadWithoutKeyThrowsLocked() throws {
        let file = url("sealed.txt")
        try FileProtector(key: key).write("secret", to: file)
        XCTAssertThrowsError(try FileProtector.passthrough.string(contentsOf: file)) { error in
            XCTAssertEqual(error as? FileProtector.ProtectorError, .locked)
        }
    }

    func testWrongKeyFailsToDecrypt() throws {
        let file = url("sealed.txt")
        try FileProtector(key: key).write("secret", to: file)
        XCTAssertThrowsError(try FileProtector(key: SymmetricKey(size: .bits256)).string(contentsOf: file))
    }

    func testDataIfPresentIsNilWhenMissingButThrowsWhenLocked() throws {
        let missing = url("nope.txt")
        XCTAssertNil(try FileProtector(key: key).dataIfPresent(at: missing))

        let sealed = url("sealed.bin")
        try FileProtector(key: key).write(Data([1, 2, 3]), to: sealed)
        XCTAssertThrowsError(try FileProtector.passthrough.dataIfPresent(at: sealed))
    }

    func testInMemorySealAndOpenRoundTrip() throws {
        let p = FileProtector(key: key)
        let sealed = try p.seal(Data("column value".utf8))
        XCTAssertTrue(DataCipher.isEnvelope(sealed))
        XCTAssertEqual(try p.open(sealed), Data("column value".utf8))
    }

    /// Names of decrypted-audio temp copies currently in the temp folder.
    private static func tempAudioCopies() -> Set<String> {
        let names = (try? FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path)) ?? []
        return Set(names.filter { $0.hasPrefix("aletheia-") && $0.hasSuffix(".caf") })
    }

    /// `ChunkedCipher.open` writes plaintext chunks into its destination as it
    /// goes, so a failure part-way (here: the last chunk is tampered with) used
    /// to leave a partial plaintext recording behind in the temp folder.
    func testFailedDecryptedCopyLeavesNoPlaintextTempFile() throws {
        let plain = url("plain.caf")
        try Data((0..<3000).map { _ in UInt8.random(in: 0...255) }).write(to: plain)
        let sealed = url("mic.caf")
        try ChunkedCipher.seal(fileAt: plain, to: sealed, using: key, chunkSize: 1000)
        var bytes = try Data(contentsOf: sealed)
        bytes[bytes.count - 1] ^= 0xFF // corrupt the final chunk's GCM tag
        try bytes.write(to: sealed)

        let before = Self.tempAudioCopies()
        XCTAssertThrowsError(try FileProtector(key: key).decryptedCopyOfLargeFile(at: sealed))
        let leaked = Self.tempAudioCopies().subtracting(before)
        XCTAssertTrue(leaked.isEmpty, "partial plaintext copy left behind: \(leaked)")
    }

    func testSuccessfulDecryptedCopyIsStillReturnedAsTemporary() throws {
        let original = Data((0..<3000).map { _ in UInt8.random(in: 0...255) })
        let plain = url("plain.caf")
        try original.write(to: plain)
        let sealed = url("call.caf")
        try ChunkedCipher.seal(fileAt: plain, to: sealed, using: key, chunkSize: 1000)

        let (copy, isTemp) = try FileProtector(key: key).decryptedCopyOfLargeFile(at: sealed)
        defer { try? FileManager.default.removeItem(at: copy) }
        XCTAssertTrue(isTemp)
        XCTAssertEqual(try Data(contentsOf: copy), original)
    }

    func testPassthroughSealIsIdentityAndOpenReadsPlaintext() throws {
        let p = FileProtector.passthrough
        let blob = Data("value".utf8)
        XCTAssertEqual(try p.seal(blob), blob, "no key → seal is identity")
        XCTAssertEqual(try p.open(blob), blob, "no key + plaintext → returned as-is")
    }
}
