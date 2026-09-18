import CryptoKit
import XCTest
@testable import SessionNotes

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

    func testPassthroughSealIsIdentityAndOpenReadsPlaintext() throws {
        let p = FileProtector.passthrough
        let blob = Data("value".utf8)
        XCTAssertEqual(try p.seal(blob), blob, "no key → seal is identity")
        XCTAssertEqual(try p.open(blob), blob, "no key + plaintext → returned as-is")
    }
}
