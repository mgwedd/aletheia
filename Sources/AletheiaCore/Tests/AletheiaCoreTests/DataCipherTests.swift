import CryptoKit
import XCTest
@testable import AletheiaCore

final class DataCipherTests: XCTestCase {
    private let key = SymmetricKey(size: .bits256)

    func testRoundTripReturnsOriginalPlaintext() throws {
        let plaintext = Data("The client reported improved sleep this week.".utf8)
        let sealed = try DataCipher.seal(plaintext, using: key)
        XCTAssertNotEqual(sealed, plaintext, "sealed bytes must not be the plaintext")
        let opened = try DataCipher.open(sealed, using: key)
        XCTAssertEqual(opened, plaintext)
    }

    func testEmptyPlaintextRoundTrips() throws {
        let sealed = try DataCipher.seal(Data(), using: key)
        XCTAssertEqual(try DataCipher.open(sealed, using: key), Data())
    }

    func testSealedFileStartsWithMagicAndVersion() throws {
        let sealed = try DataCipher.seal(Data("x".utf8), using: key)
        XCTAssertTrue(DataCipher.isEnvelope(sealed))
        XCTAssertEqual(sealed.prefix(DataCipher.magic.count), DataCipher.magic)
        XCTAssertEqual(sealed[sealed.startIndex + DataCipher.magic.count], DataCipher.version)
    }

    func testSealIsRandomizedPerCall() throws {
        let plaintext = Data("same bytes".utf8)
        let a = try DataCipher.seal(plaintext, using: key)
        let b = try DataCipher.seal(plaintext, using: key)
        XCTAssertNotEqual(a, b, "a fresh nonce per call means identical plaintext seals differently")
        XCTAssertEqual(try DataCipher.open(a, using: key), try DataCipher.open(b, using: key))
    }

    func testWrongKeyFailsToOpen() throws {
        let sealed = try DataCipher.seal(Data("secret".utf8), using: key)
        XCTAssertThrowsError(try DataCipher.open(sealed, using: SymmetricKey(size: .bits256)))
    }

    func testTamperedCiphertextFailsAuthentication() throws {
        var sealed = try DataCipher.seal(Data("secret".utf8), using: key)
        sealed[sealed.count - 1] ^= 0xFF // flip a tag bit
        XCTAssertThrowsError(try DataCipher.open(sealed, using: key))
    }

    func testNonEnvelopeIsRejected() {
        let plaintext = Data("just a plain text file".utf8)
        XCTAssertFalse(DataCipher.isEnvelope(plaintext))
        XCTAssertThrowsError(try DataCipher.open(plaintext, using: key)) { error in
            XCTAssertEqual(error as? DataCipher.CipherError, .notAnEnvelope)
        }
    }

    func testUnsupportedVersionIsRejected() throws {
        var sealed = try DataCipher.seal(Data("x".utf8), using: key)
        sealed[sealed.startIndex + DataCipher.magic.count] = 0x02 // bump version byte
        XCTAssertThrowsError(try DataCipher.open(sealed, using: key)) { error in
            XCTAssertEqual(error as? DataCipher.CipherError, .unsupportedVersion(2))
        }
    }

    func testHeaderOnlyBlobIsTruncated() {
        var blob = DataCipher.magic
        blob.append(DataCipher.version)
        XCTAssertThrowsError(try DataCipher.open(blob, using: key)) { error in
            XCTAssertEqual(error as? DataCipher.CipherError, .truncated)
        }
    }
}
