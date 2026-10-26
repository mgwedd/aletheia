import CryptoKit
import XCTest
@testable import Aletheia

final class LicenseKeyringTests: XCTestCase {
    /// Every build, Debug included, trusts exactly the production keys.
    func testEveryBuildTrustsOnlyTheProductionKeys() throws {
        XCTAssertEqual(Set(LicenseKeyring.active.keys.keys), Set(LicenseKeyring.production.keys.keys))
        let impostor = Curve25519.Signing.PrivateKey()
        let text = try LicenseTestMint.token(LicenseTestMint.payload(kid: "aletheia-dev-2"), key: impostor)
        XCTAssertThrowsError(try LicenseVerifier.verify(text, keyring: .active, now: LicenseTestMint.now)) {
            XCTAssertEqual($0 as? LicenseError, .unknownKey)
        }
    }

    /// The old dev keys are retired: their ids and public keys are trusted nowhere.
    func testTheRetiredDevKeysAreNotTrusted() {
        let retired = ["aletheia-dev-1": "l5KEG0cBMvhtV+s4ZO14Q7eFg172/V29cw1MehAF2lI=",
                       "aletheia-dev-2": "8KFp2hW7OwEzohfjyeq+7R4eZywqyDxNYBGU7YUzkSU="]
        for (kid, key) in retired {
            XCTAssertNil(LicenseKeyring.active.keys[kid])
            XCTAssertFalse(LicenseKeyring.active.keys.values.contains { $0.rawRepresentation.base64EncodedString() == key })
        }
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
