import CryptoKit
import Foundation

/// The public keys a license token (or revocation list) may be signed with, by `kid`.
struct LicenseKeyring {
    let keys: [String: Curve25519.Signing.PublicKey]

    /// Builds a keyring from `kid` -> base64 raw 32-byte Ed25519 public key.
    /// An entry that is not a valid key is skipped, so it can never verify anything.
    init(encoded: [String: String]) {
        var keys: [String: Curve25519.Signing.PublicKey] = [:]
        for (kid, base64) in encoded {
            guard let raw = Data(base64Encoded: base64),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw) else { continue }
            keys[kid] = key
        }
        self.keys = keys
    }

    // BEGIN PRODUCTION KEYS (scripts/check-license-keys.sh reads this block)
    // The current signing key and the next one, so the site can rotate to `prod-2` without
    // locking anyone out. Their private seeds are held by the owner, never in this repo.
    static let productionPublicKeys: [String: String] = [
        "prod-1": "OJ3lF6ssIkFSvc2sLNx6HYfo0l/bvWOg6iK42xV9K+w=",
        "prod-2": "VlzGFej0dahg8Z4BGGRMHgU+RN2Gd+qgYHLlS34yS5E=",
    ]
    // END PRODUCTION KEYS

    static let production = LicenseKeyring(encoded: productionPublicKeys)

    /// The keyring this build trusts. Every build, Debug included, trusts the production
    /// keys only: to try a build, issue a short-lived test license from the site's admin.
    static let active = production
}
