import CryptoKit
import XCTest
@testable import Aletheia

final class LicenseKeyringTests: XCTestCase {
    private func devKeyring() -> LicenseKeyring {
        LicenseKeyring(encoded: ["aletheia-dev-2": "8KFp2hW7OwEzohfjyeq+7R4eZywqyDxNYBGU7YUzkSU="])
    }

    /// The dev key must never be trusted by a shipped build.
    func testProductionKeyringNeverContainsTheDevKey() throws {
        XCTAssertNil(LicenseKeyring.production.keys["aletheia-dev-2"])
        XCTAssertFalse(LicenseKeyring.productionPublicKeys.keys.contains { $0.contains("dev") })
        // And not by public key value, whatever its id.
        let devRaw = try XCTUnwrap(devKeyring().keys["aletheia-dev-2"]).rawRepresentation
        for key in LicenseKeyring.production.keys.values {
            XCTAssertNotEqual(key.rawRepresentation, devRaw)
        }
        for encoded in LicenseKeyring.productionPublicKeys.values {
            XCTAssertNotEqual(Data(base64Encoded: encoded), devRaw)
        }
    }

    func testActiveKeyringByTier() throws {
        // Signed with a throwaway key under the dev key's id: no build may accept it.
        let impostor = Curve25519.Signing.PrivateKey()
        let text = try LicenseTestMint.token(LicenseTestMint.payload(kid: "aletheia-dev-2"), key: impostor)
        #if ALETHEIA_DEV
        XCTAssertEqual(LicenseKeyring.active.keys["aletheia-dev-2"]?.rawRepresentation,
                       try XCTUnwrap(devKeyring().keys["aletheia-dev-2"]).rawRepresentation,
                       "the dev tier trusts the dev key")
        XCTAssertThrowsError(try LicenseVerifier.verify(text, keyring: .active, now: LicenseTestMint.now)) {
            XCTAssertEqual($0 as? LicenseError, .badSignature)
        }
        #else
        XCTAssertNil(LicenseKeyring.active.keys["aletheia-dev-2"], "a shipped tier never trusts the dev key")
        XCTAssertEqual(Set(LicenseKeyring.active.keys.keys), Set(LicenseKeyring.production.keys.keys))
        XCTAssertThrowsError(try LicenseVerifier.verify(text, keyring: .active, now: LicenseTestMint.now)) {
            XCTAssertEqual($0 as? LicenseError, .unknownKey)
        }
        #endif
    }

    /// The first dev key's private half was once committed, so no build trusts it any more.
    func testTheRetiredDevKeyIsNotTrusted() {
        let retired = "l5KEG0cBMvhtV+s4ZO14Q7eFg172/V29cw1MehAF2lI="
        XCTAssertNil(LicenseKeyring.active.keys["aletheia-dev-1"])
        XCTAssertFalse(LicenseKeyring.active.keys.values.contains { $0.rawRepresentation.base64EncodedString() == retired })
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
