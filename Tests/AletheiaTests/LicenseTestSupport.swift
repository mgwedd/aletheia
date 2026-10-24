import CryptoKit
import Foundation
import XCTest
@testable import Aletheia

/// Mints license tokens and revocation lists for tests. The dev signing key's
/// private half lives only here, under `Tests/` (see `Fixtures/dev-license-signing-seed.txt`).
enum LicenseTestMint {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static let day: TimeInterval = 86_400

    /// The dev tier's signing key, from the fixture file.
    static func devKey(file: StaticString = #filePath) throws -> Curve25519.Signing.PrivateKey {
        let url = URL(fileURLWithPath: "\(file)")
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/dev-license-signing-seed.txt")
        let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let seed = try XCTUnwrap(Data(base64Encoded: text))
        return try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
    }

    /// A throwaway key with its own keyring, so most tests don't depend on the dev key.
    static func freshKeyring(kid: String = "test-1") -> (key: Curve25519.Signing.PrivateKey, ring: LicenseKeyring) {
        let key = Curve25519.Signing.PrivateKey()
        let ring = LicenseKeyring(encoded: [kid: key.publicKey.rawRepresentation.base64EncodedString()])
        return (key, ring)
    }

    /// A fixed, made-up license id (a UUID shape built from a repeated digit).
    static let sampleLID = "11111111-1111-4111-8111-111111111111"

    static func payload(
        kid: String = "test-1", lid: String = LicenseTestMint.sampleLID,
        sub: String = "clinician@example.com", tier: String = "beta",
        iat: Date = now.addingTimeInterval(-10 * day), exp: Date = now.addingTimeInterval(80 * day), v: Int = 1
    ) -> [String: Any] {
        ["v": v, "kid": kid, "lid": lid, "sub": sub, "tier": tier,
         "iat": Int(iat.timeIntervalSince1970), "exp": Int(exp.timeIntervalSince1970)]
    }

    static func token(_ payload: [String: Any], key: Curve25519.Signing.PrivateKey, prefix: String = "ALET1") throws -> String {
        let json = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return sign(json: json, key: key, prefix: prefix)
    }

    static func sign(json: Data, key: Curve25519.Signing.PrivateKey, prefix: String) -> String {
        let head = "\(prefix).\(Base64URL.encode(json))"
        let signature = try! key.signature(for: Data(head.utf8))
        return "\(head).\(Base64URL.encode(signature))"
    }

    static func revocationList(
        kid: String = "test-1", iat: Date = now, next: Date = now.addingTimeInterval(day),
        revoked: [String], key: Curve25519.Signing.PrivateKey
    ) throws -> String {
        let payload: [String: Any] = ["v": 1, "kid": kid, "iat": Int(iat.timeIntervalSince1970),
                                      "next": Int(next.timeIntervalSince1970), "revoked": revoked]
        return sign(json: try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), key: key, prefix: "ALETR1")
    }
}
