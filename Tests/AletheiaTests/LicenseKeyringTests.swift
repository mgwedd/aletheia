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

    /// The production keyring holds the current and next site keys, and both are valid keys.
    func testProductionKeyringHoldsTheCurrentAndNextKeys() {
        XCTAssertEqual(Set(LicenseKeyring.productionPublicKeys.keys), ["prod-1", "prod-2"])
        XCTAssertEqual(Set(LicenseKeyring.production.keys.keys), ["prod-1", "prod-2"], "every entry decodes to a key")
        XCTAssertNotEqual(LicenseKeyring.production.keys["prod-1"]?.rawRepresentation,
                          LicenseKeyring.production.keys["prod-2"]?.rawRepresentation)
    }

    /// A revocation list captured from astrealabs.com verifies with the shipped keyring,
    /// so the keys here match what the site signs with.
    func testALiveSiteRevocationListVerifiesWithTheProductionKeyring() throws {
        let captured = "ALETR1.eyJ2IjoxLCJraWQiOiJwcm9kLTEiLCJpYXQiOjE3OTI4NjQ4MDAsIm5leHQiOjE3OTI4Njg0MDAsInJldm9rZWQiOltdfQ"
            + "._mcwi7CNGJboYOkGb3hyQcTwGbaN3zusfVEtRKDqZZO4QsgUOVXRfHUOpU-aIJNOIUMUoghXcGkw5jAORFAKCQ"
        let list = try RevocationVerifier.verify(captured, keyring: .production)
        XCTAssertEqual(list.kid, "prod-1")
        XCTAssertTrue(list.revoked.isEmpty)
    }
}
