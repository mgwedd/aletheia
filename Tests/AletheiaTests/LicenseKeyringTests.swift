import CryptoKit
import XCTest
@testable import Aletheia

final class LicenseKeyringTests: XCTestCase {
    private func devKeyring() -> LicenseKeyring {
        LicenseKeyring(encoded: ["aletheia-dev-1": "l5KEG0cBMvhtV+s4ZO14Q7eFg172/V29cw1MehAF2lI="])
    }

    /// The dev key must never be trusted by a shipped build.
    func testProductionKeyringNeverContainsTheDevKey() throws {
        XCTAssertNil(LicenseKeyring.production.keys["aletheia-dev-1"])
        XCTAssertFalse(LicenseKeyring.productionPublicKeys.keys.contains { $0.contains("dev") })
        // And not by public key value, whatever its id.
        let devRaw = try XCTUnwrap(devKeyring().keys["aletheia-dev-1"]).rawRepresentation
        for key in LicenseKeyring.production.keys.values {
            XCTAssertNotEqual(key.rawRepresentation, devRaw)
        }
        for encoded in LicenseKeyring.productionPublicKeys.values {
            XCTAssertNotEqual(Data(base64Encoded: encoded), devRaw)
        }
    }

    func testDevKeyFixtureMatchesTheDevTierPublicKey() throws {
        let devKey = try LicenseTestMint.devKey()
        XCTAssertEqual(devKey.publicKey.rawRepresentation, try XCTUnwrap(devKeyring().keys["aletheia-dev-1"]).rawRepresentation)
    }

    func testActiveKeyringByTier() throws {
        #if ALETHEIA_DEV
        XCTAssertNotNil(LicenseKeyring.active.keys["aletheia-dev-1"], "the dev tier trusts the dev key")
        let text = try LicenseTestMint.token(
            LicenseTestMint.payload(kid: "aletheia-dev-1"), key: try LicenseTestMint.devKey())
        XCTAssertNoThrow(try LicenseVerifier.verify(text, keyring: .active, now: LicenseTestMint.now))
        #else
        XCTAssertNil(LicenseKeyring.active.keys["aletheia-dev-1"], "a shipped tier never trusts the dev key")
        XCTAssertEqual(Set(LicenseKeyring.active.keys.keys), Set(LicenseKeyring.production.keys.keys))
        let text = try LicenseTestMint.token(
            LicenseTestMint.payload(kid: "aletheia-dev-1"), key: try LicenseTestMint.devKey())
        XCTAssertThrowsError(try LicenseVerifier.verify(text, keyring: .active, now: LicenseTestMint.now)) {
            XCTAssertEqual($0 as? LicenseError, .unknownKey)
        }
        #endif
    }

    func testInvalidEncodedKeysAreDroppedNotTrusted() {
        let ring = LicenseKeyring(encoded: ["a": "not base64!", "b": "AAAA", "c": ""])
        XCTAssertTrue(ring.keys.isEmpty)
    }
}
