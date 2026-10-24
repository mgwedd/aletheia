import CryptoKit
import XCTest
@testable import Aletheia

final class RevocationListTests: XCTestCase {
    private var key: Curve25519.Signing.PrivateKey!
    private var ring: LicenseKeyring!
    private let now = LicenseTestMint.now

    override func setUp() {
        (key, ring) = LicenseTestMint.freshKeyring()
    }

    func testAcceptsASignedList() throws {
        let text = try LicenseTestMint.revocationList(revoked: ["a", "b"], key: key)
        let list = try RevocationVerifier.verify(text, keyring: ring)
        XCTAssertEqual(list.revoked, ["a", "b"])
        XCTAssertEqual(list.issuedAt, now)
        XCTAssertEqual(list.next, now.addingTimeInterval(LicenseTestMint.day))
        XCTAssertEqual(list.kid, "test-1")
    }

    func testAcceptsAnEmptyList() throws {
        let list = try RevocationVerifier.verify(try LicenseTestMint.revocationList(revoked: [], key: key), keyring: ring)
        XCTAssertTrue(list.revoked.isEmpty)
    }

    func testRejectsBadSignatureUnknownKeyAndVersion() throws {
        let forged = try LicenseTestMint.revocationList(revoked: ["a"], key: Curve25519.Signing.PrivateKey())
        XCTAssertThrowsError(try RevocationVerifier.verify(forged, keyring: ring)) { XCTAssertEqual($0 as? RevocationError, .badSignature) }

        let unknown = try LicenseTestMint.revocationList(kid: "other", revoked: ["a"], key: key)
        XCTAssertThrowsError(try RevocationVerifier.verify(unknown, keyring: ring)) { XCTAssertEqual($0 as? RevocationError, .unknownKey) }

        let payload: [String: Any] = ["v": 2, "kid": "test-1", "iat": 1, "next": 2, "revoked": []]
        let v2 = LicenseTestMint.sign(json: try JSONSerialization.data(withJSONObject: payload), key: key, prefix: "ALETR1")
        XCTAssertThrowsError(try RevocationVerifier.verify(v2, keyring: ring)) { XCTAssertEqual($0 as? RevocationError, .unsupportedVersion) }
    }

    func testRejectsMalformed() throws {
        for text in ["", "ALETR1", "ALETR1.a.b", "ALET1.x.y", "garbage", "ALETR1.!!.!!"] {
            XCTAssertThrowsError(try RevocationVerifier.verify(text, keyring: ring), text) {
                XCTAssertEqual($0 as? RevocationError, .malformed)
            }
        }
        // A license token is not a revocation list, even if correctly signed.
        let token = try LicenseTestMint.token(LicenseTestMint.payload(), key: key)
        XCTAssertThrowsError(try RevocationVerifier.verify(token, keyring: ring))
        // Missing field.
        let payload: [String: Any] = ["v": 1, "kid": "test-1", "iat": 1, "revoked": []]
        let noNext = LicenseTestMint.sign(json: try JSONSerialization.data(withJSONObject: payload), key: key, prefix: "ALETR1")
        XCTAssertThrowsError(try RevocationVerifier.verify(noNext, keyring: ring)) { XCTAssertEqual($0 as? RevocationError, .malformed) }
    }

    func testRejectsOversize() throws {
        let ids = (0..<8000).map { _ in UUID().uuidString }
        let big = try LicenseTestMint.revocationList(revoked: ids, key: key)
        XCTAssertGreaterThan(big.utf8.count, RevocationVerifier.maxLength)
        XCTAssertThrowsError(try RevocationVerifier.verify(big, keyring: ring)) { XCTAssertEqual($0 as? RevocationError, .tooLong) }
    }

    func testRejectsAListOlderThanTheLastAccepted() throws {
        let older = try LicenseTestMint.revocationList(iat: now.addingTimeInterval(-60), revoked: [], key: key)
        let last = Int(now.timeIntervalSince1970)
        XCTAssertThrowsError(try RevocationVerifier.verify(older, keyring: ring, lastAcceptedIssuedAt: last)) {
            XCTAssertEqual($0 as? RevocationError, .stale)
        }
        // The same list again, and a newer one, are fine.
        let same = try LicenseTestMint.revocationList(iat: now, revoked: [], key: key)
        XCTAssertNoThrow(try RevocationVerifier.verify(same, keyring: ring, lastAcceptedIssuedAt: last))
        let newer = try LicenseTestMint.revocationList(iat: now.addingTimeInterval(60), revoked: [], key: key)
        XCTAssertNoThrow(try RevocationVerifier.verify(newer, keyring: ring, lastAcceptedIssuedAt: last))
    }
}
